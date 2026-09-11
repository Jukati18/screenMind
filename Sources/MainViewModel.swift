import Foundation
import SwiftUI
import CoreVideo
import UIKit

@MainActor
final class MainViewModel: ObservableObject, CameraManagerDelegate {

    // MARK: - Published UI state

    @Published var currentOCRText: String = ""
    @Published var geminiAnswer: String = ""
    @Published var state: AppProcessingState = .idle
    @Published var isRunning: Bool = false
    @Published var showOCROverlay: Bool = true
    @Published var history: [HistoryItem] = []

    /// Normalized ROI in UIKit space (origin top-left, 0...1). Converted to
    /// Vision's bottom-left-origin space right before each OCR pass.
    @Published var regionOfInterest: CGRect = CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.36)

    // MARK: - Dependencies (injected as concrete types per the required structure)

    let cameraManager = CameraManager()
    private let ocrProcessor = OCRProcessor()
    // Key comes from Secrets.swift, which is gitignored locally and
    // generated on the fly by CI from a GitHub Actions secret — never
    // hardcoded here, never committed.
    private let geminiService = GeminiService(apiKey: Secrets.geminiAPIKey)
    private var changeDetector = TextChangeDetector()

    // MARK: - Throttling state

    /// Runs OCR at most once every `ocrInterval` seconds, per the 0.8–1.2s spec.
    private let ocrInterval: TimeInterval = 1.0
    private var lastOCRRunTime: Date = .distantPast
    private var isProcessingFrame = false
    private var currentGeminiTask: Task<Void, Never>?

    // CHANGE: separate, longer cooldown specifically for Gemini network calls.
    // The free Gemini tier allows only 5 requests/minute, so the ~1s OCR loop
    // combined with the text-change heuristic was firing far more often than
    // that and tripping 429s. This cooldown is a hard floor on top of the
    // change detector, not a replacement for it.
    private let geminiCooldown: TimeInterval = 13 // ~4.6 req/min, safely under the 5/min free-tier cap
    private var lastGeminiCallTime: Date = .distantPast

    // CHANGE: tracks a scheduled auto-retry after a 429 so we can cancel it
    // if the user pauses or new text arrives before it fires.
    private var pendingRetryTask: Task<Void, Never>?

    init() {
        cameraManager.delegate = self
        cameraManager.checkPermissionsAndConfigure()
    }

    // MARK: - Controls

    func start() {
        isRunning = true
        state = .scanning
        cameraManager.startSession()
    }

    func pause() {
        isRunning = false
        state = .idle
        cameraManager.stopSession()
        currentGeminiTask?.cancel()
        // CHANGE: also cancel any pending rate-limit retry when pausing,
        // so a stale retry doesn't fire after the user has stopped scanning.
        pendingRetryTask?.cancel()
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func clearHistory() {
        history.removeAll()
        currentOCRText = ""
        geminiAnswer = ""
        changeDetector.reset()
        state = isRunning ? .scanning : .idle
    }

    func copyAnswer() {
        guard !geminiAnswer.isEmpty else { return }
        UIPasteboard.general.string = geminiAnswer
    }

    // MARK: - CameraManagerDelegate (called on a background video queue)

    nonisolated func cameraManager(_ manager: CameraManager, didOutput pixelBuffer: CVPixelBuffer) {
        Task { @MainActor [weak self] in
            await self?.handleFrame(pixelBuffer)
        }
    }

    // MARK: - Frame handling / OCR throttling

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) async {
        guard isRunning, !isProcessingFrame else { return }

        let now = Date()
        guard now.timeIntervalSince(lastOCRRunTime) >= ocrInterval else { return }
        lastOCRRunTime = now
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let visionROI = Self.convertToVisionSpace(regionOfInterest)
        let text = await ocrProcessor.recognizeText(in: pixelBuffer, regionOfInterest: visionROI)

        guard !text.isEmpty else { return }
        currentOCRText = text
        if isRunning { state = .scanning }

        if changeDetector.shouldSend(newText: text) {
            sendToGemini(text: text)
        }
    }

    /// UIKit's top-left-origin normalized rect -> Vision's bottom-left-origin normalized rect.
    private static func convertToVisionSpace(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: 1 - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Gemini call

    private func sendToGemini(text: String) {
        // CHANGE: enforce the hard cooldown on top of the change-detector's
        // own heuristic. If we're still within the cooldown window, just
        // drop this particular update rather than calling the API — the
        // next change-worthy frame will get picked up once the cooldown
        // elapses, so we don't lose text permanently, only intermediate
        // updates while typing/scanning fast.
        let now = Date()
        guard now.timeIntervalSince(lastGeminiCallTime) >= geminiCooldown else { return }

        currentGeminiTask?.cancel()
        pendingRetryTask?.cancel() // CHANGE: new text supersedes any queued retry of older text
        state = .sendingToAI

        currentGeminiTask = Task { [weak self] in
            guard let self else { return }
            await self.performGeminiRequest(text: text, isRetry: false)
        }
    }

    // CHANGE: extracted the actual request + response handling into its own
    // method so both the initial call and the auto-retry-after-429 path can
    // share the same success/failure logic instead of duplicating it.
    private func performGeminiRequest(text: String, isRetry: Bool) async {
        lastGeminiCallTime = Date()
        do {
            let answer = try await geminiService.ask(ocrText: text)
            guard !Task.isCancelled else { return }
            geminiAnswer = answer
            state = .answerReady
            history.insert(HistoryItem(question: text, answer: answer, date: Date()), at: 0)
        } catch GeminiError.rateLimited(let retryAfter) {
            // CHANGE: on a 429, don't just show an error — schedule one
            // automatic retry after the delay Google told us to wait
            // (falling back to a sane default if it didn't give us one).
            guard !Task.isCancelled else { return }
            let delay = retryAfter ?? geminiCooldown
            state = .error("Rate limited — retrying in \(Int(delay.rounded()))s")
            scheduleRetry(text: text, after: delay)
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(error.localizedDescription)
        }
    }

    // CHANGE: new — schedules a single retry attempt after a 429, cancellable
    // if the user pauses, clears history, or new OCR text arrives first.
    private func scheduleRetry(text: String, after delay: TimeInterval) {
        pendingRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.state = .sendingToAI
            await self.performGeminiRequest(text: text, isRetry: true)
        }
    }
}