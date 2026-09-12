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

    // CHANGE: new — published so the UI can show a live sharpness score.
    // Use this to calibrate `minimumSharpnessScore` below against your real
    // device/lighting before considering the badge in ContentView optional.
    @Published var currentSharpnessScore: Double = 0

    @Published var regionOfInterest: CGRect = CGRect(x: 0.1, y: 0.32, width: 0.8, height: 0.36)

    // MARK: - Dependencies

    let cameraManager = CameraManager()
    private let ocrProcessor = OCRProcessor()
    private let geminiService = GeminiService(apiKey: Secrets.geminiAPIKey)
    private var changeDetector = TextChangeDetector()

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

    // CHANGE: new — blur-gate tuning. Watch the "sharp: N" badge (added in
    // ContentView) in real conditions and adjust minimumSharpnessScore so
    // it sits comfortably between your sharp and blurry readings.
    private let minimumSharpnessScore: Double = 6.0
    private let blurRetryLimit = 3
    private let blurRetryDelayNanoseconds: UInt64 = 200_000_000 // 0.2s

    // CHANGE: new — confidence-gate tuning. Vision's per-line confidence is
    // 0...1; start here and adjust based on how often real scans get
    // rejected vs. how often bad text still slips through.
    private let minimumOCRConfidence: Float = 0.4

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
        focusCameraOnROI() // CHANGE: lock focus on the current ROI as soon as scanning starts.
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

    // MARK: - Focus (CHANGE: new)

    /// Locks the camera's focus/exposure on the ROI box's center. Called
    /// when scanning starts and whenever the user finishes dragging the ROI
    /// (see ContentView), so continuous autofocus — which can keep
    /// "hunting" on close-up text — gets a specific point to settle on.
    func focusCameraOnROI() {
        let center = CGPoint(x: regionOfInterest.midX, y: regionOfInterest.midY)
        // CHANGE: convert from our view-space convention (x right, y down,
        // origin top-left) to AVFoundation's focusPointOfInterest
        // convention for a back camera locked to `.portrait`
        // videoOrientation: x_device = y_view, y_device = 1 - x_view.
        // Verify on your actual device — if focus consistently locks on the
        // wrong part of the frame, swap/invert these two lines to match.
        let devicePoint = CGPoint(x: center.y, y: 1 - center.x)
        cameraManager.focus(on: devicePoint)
    }

    // MARK: - CameraManagerDelegate

    nonisolated func cameraManager(_ manager: CameraManager, didOutput pixelBuffer: CVPixelBuffer) {
        Task { @MainActor [weak self] in
            self?.latestPixelBuffer = pixelBuffer
            await self?.handleFrame(pixelBuffer)
        }
    }

    // MARK: - Frame handling / OCR (preview only)

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) async {
        guard isRunning, !isProcessingFrame else { return }

        let now = Date()
        guard now.timeIntervalSince(lastOCRRunTime) >= ocrInterval else { return }
        lastOCRRunTime = now
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        // CHANGE: piggybacks on the existing 1s throttle so this costs
        // nothing extra — cheap on its own (fixed 64x64 grid) but no reason
        // to run it more often than the preview OCR already runs.
        if let score = BlurDetector.sharpnessScore(for: pixelBuffer) {
            currentSharpnessScore = score
        }

        let visionROI = Self.convertToVisionSpace(regionOfInterest)
        // CHANGE: recognizeText now returns OCRResult instead of a bare
        // String — preview only needs the text, confidence is ignored here.
        let result = await ocrProcessor.recognizeText(in: pixelBuffer, regionOfInterest: visionROI)

        guard !result.text.isEmpty else { return }
        currentOCRText = result.text
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

    func askGemini() {
        guard let pixelBuffer = latestPixelBuffer else { return }

        let now = Date()
        guard now.timeIntervalSince(lastGeminiCallTime) >= manualAskCooldown else { return }

        currentGeminiTask?.cancel()
        pendingRetryTask?.cancel()
        state = .sendingToAI

        currentGeminiTask = Task { [weak self] in
            guard let self else { return }
            await self.performAccurateScanAndAsk(pixelBuffer: pixelBuffer)
        }
    }

    // CHANGE: runs the high-accuracy, cropped-to-ROI OCR pass at the moment
    // of the tap. Now gated by two new quality checks before anything is
    // sent to Gemini:
    //   1. A blur/sharpness pre-check (with a few short retries against
    //      fresh frames) — skips running OCR at all on a frame that's still
    //      shaking or out of focus.
    //   2. An OCR-confidence post-check — skips sending text to Gemini that
    //      Vision itself wasn't confident about, even if some text came
    //      back.
    // Both surface a clear, actionable error instead of silently producing a
    // bad answer or spending a Gemini quota slot on garbage input.
    private func performAccurateScanAndAsk(pixelBuffer initialPixelBuffer: CVPixelBuffer) async {
        var pixelBuffer = initialPixelBuffer

        var attempt = 0
        while let score = BlurDetector.sharpnessScore(for: pixelBuffer),
              score < minimumSharpnessScore,
              attempt < blurRetryLimit {
            attempt += 1
            try? await Task.sleep(nanoseconds: blurRetryDelayNanoseconds)
            guard let freshest = latestPixelBuffer else { break }
            pixelBuffer = freshest
        }

        if let finalScore = BlurDetector.sharpnessScore(for: pixelBuffer), finalScore < minimumSharpnessScore {
            state = .error("Image too blurry (sharpness \(Int(finalScore))) — hold steady and make sure the text is in focus, then try again.")
            return
        }

        let visionROI = Self.convertToVisionSpace(regionOfInterest)

        let result = await ocrProcessor.recognizeText(
            in: pixelBuffer,
            regionOfInterest: visionROI,
            recognitionLevel: .accurate,
            minimumTextHeight: 0.01,
            cropToRegion: true
        )

        guard !result.text.isEmpty else {
            state = .error("No text found in the scan box — reposition it over the question and try again.")
            return
        }

        guard result.averageConfidence >= minimumOCRConfidence else {
            state = .error("Scan confidence too low (\(Int(result.averageConfidence * 100))%) — move closer or hold steadier, then try again.")
            return
        }

        let text = result.text
        currentOCRText = text

        let key = Self.normalize(text)
        if let cached = answerCache[key] {
            geminiAnswer = cached
            state = .answerReady
            return
        }

        guard changeDetector.shouldSend(newText: text) else {
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