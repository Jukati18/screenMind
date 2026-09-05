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
        currentGeminiTask?.cancel()
        state = .sendingToAI

        currentGeminiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.geminiService.ask(ocrText: text)
                guard !Task.isCancelled else { return }
                self.geminiAnswer = answer
                self.state = .answerReady
                self.history.insert(HistoryItem(question: text, answer: answer, date: Date()), at: 0)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .error(error.localizedDescription)
            }
        }
    }
}
