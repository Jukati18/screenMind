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

    // CHANGE: exposes the client-side estimate of today's quota usage so
    // the UI can show "x/20 today" and disable the Ask button pre-emptively.
    // This is advisory only — Google's server-side quota is authoritative
    // and may reset at a different time than local midnight — but it's
    // enough to stop the user from tapping into an obvious 429.
    @Published var requestsUsedToday: Int = 0
    let estimatedDailyQuota = 20 // matches the RPD shown for this project's free-tier Flash-Lite allocation in AI Studio

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
    /// CHANGE: this still only controls the *live preview* text now — it no
    /// longer drives any network call. OCR keeps running continuously so the
    /// user can see what will be sent before they tap "Ask".
    private let ocrInterval: TimeInterval = 1.0
    private var lastOCRRunTime: Date = .distantPast
    private var isProcessingFrame = false
    private var currentGeminiTask: Task<Void, Never>?

    // CHANGE: short cooldown on the manual "Ask" button — this is no longer
    // guarding against a 1s auto-loop, just against accidental double-taps
    // (e.g. someone mashing the button while a request is in flight).
    private let manualAskCooldown: TimeInterval = 3
    private var lastGeminiCallTime: Date = .distantPast

    // CHANGE: cancellable auto-retry task scheduled after a 429.
    private var pendingRetryTask: Task<Void, Never>?

    // CHANGE: #4 — in-memory cache of normalized-OCR-text -> answer. If the
    // user re-asks about text they've effectively already asked about
    // (same content, maybe reformatted by OCR jitter), we serve the cached
    // answer instantly with zero network calls and zero quota cost.
    private var answerCache: [String: String] = [:]
    private let answerCacheLimit = 50 // simple cap so this can't grow unbounded during a long session

    // CHANGE: UserDefaults keys backing the daily quota counter, persisted
    // across app launches/re-signs so the estimate survives a restart.
    private let quotaCountKey = "gemini_requests_used_today"
    private let quotaDateKey = "gemini_requests_date"

    init() {
        cameraManager.delegate = self
        cameraManager.checkPermissionsAndConfigure()
        loadQuotaCounter() // CHANGE: restore (or reset, if it's a new day) the persisted daily count
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
        pendingRetryTask?.cancel() // CHANGE: don't let a queued retry fire after pausing
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
        // NOTE: deliberately NOT clearing answerCache here — cached answers
        // stay valid even after clearing the visible history list.
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

    // MARK: - Frame handling / OCR (preview only — no network call here anymore)

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

        // CHANGE (#3): removed the automatic `sendToGemini` call that used
        // to fire here on every meaningful text change. OCR still runs
        // continuously to keep `currentOCRText` live for the preview and
        // for the "Ask Gemini" button to use, but nothing hits the network
        // until the user explicitly taps Ask.
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

    // MARK: - Manual "Ask Gemini" trigger (CHANGE: replaces the old auto-send path)

    /// Call this from a button tap. Handles, in order: double-tap cooldown,
    /// cache lookup (#4), the "text hasn't really changed" dedupe check,
    /// and the client-side daily quota estimate — only falling through to an
    /// actual network call if none of those short-circuit it.
    func askGemini() {
        let text = currentOCRText
        guard !text.isEmpty else { return }

        // Guard 1: accidental double-tap protection.
        let now = Date()
        guard now.timeIntervalSince(lastGeminiCallTime) >= manualAskCooldown else { return }

        // Guard 2 (#4): exact/near-duplicate cache hit — instant, free, no quota used.
        let key = Self.normalize(text)
        if let cached = answerCache[key] {
            geminiAnswer = cached
            state = .answerReady
            return
        }

        // Guard 3 (#4): if this text isn't meaningfully different from the
        // last text we actually sent to the API, there's nothing new to ask
        // — avoid spending a request re-confirming the same content.
        guard changeDetector.shouldSend(newText: text) else { return }

        // Guard 4: client-side daily quota estimate. Advisory, not
        // authoritative — Google's server is the real source of truth — but
        // stops an obviously-futile tap from spending the cooldown window.
        guard requestsUsedToday < estimatedDailyQuota else {
            state = .error("Daily quota likely reached (~\(estimatedDailyQuota)/day free tier). Try again tomorrow or enable billing.")
            return
        }

        currentGeminiTask?.cancel()
        pendingRetryTask?.cancel()
        state = .sendingToAI

        currentGeminiTask = Task { [weak self] in
            guard let self else { return }
            await self.performGeminiRequest(text: text, cacheKey: key)
        }
    }

    private func performGeminiRequest(text: String, cacheKey: String) async {
        lastGeminiCallTime = Date()
        incrementQuotaCounter() // CHANGE: count this attempt against today's estimate before we know the result — a 429 still consumed a real request server-side

        do {
            let answer = try await geminiService.ask(ocrText: text)
            guard !Task.isCancelled else { return }
            geminiAnswer = answer
            state = .answerReady
            history.insert(HistoryItem(question: text, answer: answer, date: Date()), at: 0)
            cacheAnswer(answer, for: cacheKey) // CHANGE (#4): remember this answer for next time
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

    // MARK: - Answer cache (#4)

    private func cacheAnswer(_ answer: String, for key: String) {
        if answerCache.count >= answerCacheLimit {
            // Cheap eviction: just drop everything once we hit the cap
            // rather than tracking LRU order for a 50-entry hobby cache.
            answerCache.removeAll()
        }
        answerCache[key] = answer
    }

    /// Collapses whitespace/case/newline differences so near-identical OCR
    /// passes over the same physical text hit the same cache key even if
    /// Vision's exact line-breaking varies slightly between frames.
    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Daily quota counter (advisory, client-side)

    private func loadQuotaCounter() {
        let defaults = UserDefaults.standard
        let storedDateString = defaults.string(forKey: quotaDateKey)
        let todayString = Self.dateKeyString(for: Date())

        if storedDateString == todayString {
            requestsUsedToday = defaults.integer(forKey: quotaCountKey)
        } else {
            // New day (or first launch) — reset the counter.
            requestsUsedToday = 0
            defaults.set(todayString, forKey: quotaDateKey)
            defaults.set(0, forKey: quotaCountKey)
        }
    }

    private func incrementQuotaCounter() {
        let defaults = UserDefaults.standard
        let todayString = Self.dateKeyString(for: Date())
        if defaults.string(forKey: quotaDateKey) != todayString {
            // Crossed midnight since the app launched — reset before counting.
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