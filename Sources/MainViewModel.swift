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

    @Published var requestsUsedToday: Int = 0
    let estimatedDailyQuota = 20

    @Published var regionOfInterest: CGRect = CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.36)

    // MARK: - Dependencies

    let cameraManager = CameraManager()
    private let ocrProcessor = OCRProcessor()
    private let geminiService = GeminiService(apiKey: Secrets.geminiAPIKey)
    private var changeDetector = TextChangeDetector()

    // CHANGE: keeps the most recent camera frame around so the manual "Ask"
    // action can run a fresh, high-accuracy, cropped OCR pass on demand,
    // instead of reusing whatever the low-effort live-preview pass last saw.
    private var latestPixelBuffer: CVPixelBuffer?

    // MARK: - Throttling state

    private let ocrInterval: TimeInterval = 1.0
    private var lastOCRRunTime: Date = .distantPast
    private var isProcessingFrame = false
    private var currentGeminiTask: Task<Void, Never>?

    private let manualAskCooldown: TimeInterval = 3
    private var lastGeminiCallTime: Date = .distantPast

    private var pendingRetryTask: Task<Void, Never>?

    private var answerCache: [String: String] = [:]
    private let answerCacheLimit = 50

    private let quotaCountKey = "gemini_requests_used_today"
    private let quotaDateKey = "gemini_requests_date"

    init() {
        cameraManager.delegate = self
        cameraManager.checkPermissionsAndConfigure()
        loadQuotaCounter()
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
            // CHANGE: always store the freshest frame, independent of the
            // preview OCR throttle below, so a tap on "Ask" always has an
            // up-to-date buffer to run the accurate scan against.
            self?.latestPixelBuffer = pixelBuffer
            await self?.handleFrame(pixelBuffer)
        }
    }

    // MARK: - Frame handling / OCR (preview only — unchanged: still .fast, uncropped, for a cheap live overlay)

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) async {
        guard isRunning, !isProcessingFrame else { return }

        let now = Date()
        guard now.timeIntervalSince(lastOCRRunTime) >= ocrInterval else { return }
        lastOCRRunTime = now
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let visionROI = Self.convertToVisionSpace(regionOfInterest)
        // NOTE: deliberately left as the old .fast / uncropped / 0.02 call —
        // this is just the cheap live-preview text shown under the camera,
        // not what gets sent to Gemini anymore (see performAccurateScanAndAsk).
        let text = await ocrProcessor.recognizeText(in: pixelBuffer, regionOfInterest: visionROI)

        guard !text.isEmpty else { return }
        currentOCRText = text
        if isRunning { state = .scanning }
    }

    private static func convertToVisionSpace(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: 1 - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Manual "Ask Gemini" trigger

    /// CHANGE: this no longer reuses the low-effort preview text. It now
    /// kicks off a fresh, high-accuracy, ROI-cropped OCR pass first (see
    /// performAccurateScanAndAsk), and only that result is ever sent to
    /// Gemini or checked against cache/dedupe/quota.
    func askGemini() {
        // CHANGE: bail out immediately if we don't have a frame yet, before
        // doing any OCR work at all.
        guard let pixelBuffer = latestPixelBuffer else { return }

        // Guard 1: accidental double-tap protection — checked first, before
        // spending effort on an accurate OCR pass.
        let now = Date()
        guard now.timeIntervalSince(lastGeminiCallTime) >= manualAskCooldown else { return }

        currentGeminiTask?.cancel()
        pendingRetryTask?.cancel()
        // CHANGE: reflects that real work (accurate OCR + possibly network)
        // is starting now, not just the network call.
        state = .sendingToAI

        currentGeminiTask = Task { [weak self] in
            guard let self else { return }
            await self.performAccurateScanAndAsk(pixelBuffer: pixelBuffer)
        }
    }

    // CHANGE: new — runs the high-accuracy, cropped-to-ROI OCR pass at the
    // moment of the tap, then falls through into the same cache/dedupe/quota
    // logic askGemini() used to run directly on the preview text.
    private func performAccurateScanAndAsk(pixelBuffer: CVPixelBuffer) async {
        let visionROI = Self.convertToVisionSpace(regionOfInterest)

        let text = await ocrProcessor.recognizeText(
            in: pixelBuffer,
            regionOfInterest: visionROI,
            recognitionLevel: .accurate,   // CHANGE: worth the extra cost since this only runs once per tap.
            minimumTextHeight: 0.01,       // CHANGE: lowered so smaller multiple-choice text isn't filtered before recognition starts.
            cropToRegion: true             // CHANGE: crop first so the text occupies nearly the whole analyzed image.
        )

        guard !text.isEmpty else {
            // CHANGE: clear, actionable message instead of silently doing nothing.
            state = .error("No text found in the scan box — reposition it over the question and try again.")
            return
        }

        // CHANGE: reflect exactly what was actually sent/considered, since it
        // may differ from the fast live-preview text.
        currentOCRText = text

        let key = Self.normalize(text)
        if let cached = answerCache[key] {
            geminiAnswer = cached
            state = .answerReady
            return
        }

        guard changeDetector.shouldSend(newText: text) else {
            // CHANGE: reset state instead of leaving it stuck on "Sending to AI…"
            // now that state is set earlier in askGemini().
            state = isRunning ? .scanning : .idle
            return
        }

        guard requestsUsedToday < estimatedDailyQuota else {
            state = .error("Daily quota likely reached (~\(estimatedDailyQuota)/day free tier). Try again tomorrow or enable billing.")
            return
        }

        await performGeminiRequest(text: text, cacheKey: key)
    }

    private func performGeminiRequest(text: String, cacheKey: String) async {
        lastGeminiCallTime = Date()
        incrementQuotaCounter()

        do {
            let answer = try await geminiService.ask(ocrText: text)
            guard !Task.isCancelled else { return }
            geminiAnswer = answer
            state = .answerReady
            history.insert(HistoryItem(question: text, answer: answer, date: Date()), at: 0)
            cacheAnswer(answer, for: cacheKey)
        } catch GeminiError.rateLimited(let retryAfter) {
            guard !Task.isCancelled else { return }
            let delay = retryAfter ?? manualAskCooldown
            state = .error("Rate limited — retrying in \(Int(delay.rounded()))s")
            scheduleRetry(text: text, cacheKey: cacheKey, after: delay)
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(error.localizedDescription)
        }
    }

    private func scheduleRetry(text: String, cacheKey: String, after delay: TimeInterval) {
        pendingRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.state = .sendingToAI
            await self.performGeminiRequest(text: text, cacheKey: cacheKey)
        }
    }

    // MARK: - Answer cache

    private func cacheAnswer(_ answer: String, for key: String) {
        if answerCache.count >= answerCacheLimit {
            answerCache.removeAll()
        }
        answerCache[key] = answer
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Daily quota counter

    private func loadQuotaCounter() {
        let defaults = UserDefaults.standard
        let storedDateString = defaults.string(forKey: quotaDateKey)
        let todayString = Self.dateKeyString(for: Date())

        if storedDateString == todayString {
            requestsUsedToday = defaults.integer(forKey: quotaCountKey)
        } else {
            requestsUsedToday = 0
            defaults.set(todayString, forKey: quotaDateKey)
            defaults.set(0, forKey: quotaCountKey)
        }
    }

    private func incrementQuotaCounter() {
        let defaults = UserDefaults.standard
        let todayString = Self.dateKeyString(for: Date())
        if defaults.string(forKey: quotaDateKey) != todayString {
            requestsUsedToday = 0
            defaults.set(todayString, forKey: quotaDateKey)
        }
        requestsUsedToday += 1
        defaults.set(requestsUsedToday, forKey: quotaCountKey)
    }

    private static func dateKeyString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}