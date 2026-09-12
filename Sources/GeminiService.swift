import Foundation

enum GeminiError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case emptyAnswer
    case rateLimited(retryAfter: TimeInterval?)
    // CHANGE: new case — surfaced only if BOTH the primary model and the
    // fallback ("gemini-flash-latest") return 404. If just the primary
    // model 404s, ask() silently retries on the fallback instead of
    // throwing this — this case means we're truly out of options.
    case modelUnavailable(triedModels: [String])

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Gemini API URL."
        case .invalidResponse: return "Invalid response from Gemini."
        case .apiError(let msg): return "Gemini API error: \(msg)"
        case .emptyAnswer: return "Gemini returned an empty answer."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limit reached. Retrying in \(Int(retryAfter.rounded()))s…"
            }
            return "Rate limit reached. Please wait a moment and try again."
        // CHANGE: user-facing message for the "nothing worked" case.
        case .modelUnavailable(let triedModels):
            return "No available Gemini model (tried: \(triedModels.joined(separator: ", "))). Check https://ai.google.dev/gemini-api/docs/models for current model names."
        }
    }
}

/// Thin client for Google's Gemini `generateContent` REST endpoint.
///
/// SECURITY NOTE: hardcoding the API key in the client is fine for a quick
/// personal test build, but it ships inside the app binary and can be
/// extracted. For anything you distribute, proxy this call through your own
/// backend and keep the key server-side.
final class GeminiService {

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    // CHANGE: fallback model used only if `model` returns a 404 (model
    // retired/renamed/never existed). "gemini-flash-latest" is Google's
    // own alias that always resolves to *whatever* current Flash model is
    // live, so it should never itself 404 — it's the safest possible net.
    private let fallbackModel: String

    /// - Parameters:
    ///   - apiKey: get one at https://aistudio.google.com/app/apikey
    ///   - model: primary model to try first. Pinned to a lightweight model
    ///     on purpose (see prior comment) rather than an alias, so its
    ///     free-tier rate limit is predictable.
    ///   - fallbackModel: CHANGE — used automatically if `model` 404s, so a
    ///     model being deprecated doesn't hard-break the app. Defaults to
    ///     Google's "latest Flash" alias.
    init(
        apiKey: String = "YOUR_GEMINI_API_KEY",
        model: String = "gemini-3.5-flash-lite",
        fallbackModel: String = "gemini-flash-latest"
    ) {
        self.apiKey = apiKey
        self.model = model
        self.fallbackModel = fallbackModel
    }

    // CHANGE: endpoint is now parameterized by model so both the primary
    // and fallback attempts can reuse the same URL-building logic.
    private func endpoint(for model: String) -> URL? {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")
    }

    // MARK: - Request

    func ask(ocrText: String) async throws -> String {
        // CHANGE: try the primary (lightweight) model first.
        do {
            return try await performRequest(ocrText: ocrText, model: model)
        } catch GeminiError.apiError(let message) where Self.isModelNotFound(message) {
            // CHANGE: primary model doesn't exist / was retired — silently
            // retry once against the fallback alias instead of failing the
            // whole call. Any other error type (429, network, etc.) is
            // NOT caught here and propagates immediately as before.
            do {
                return try await performRequest(ocrText: ocrText, model: fallbackModel)
            } catch GeminiError.apiError(let fallbackMessage) where Self.isModelNotFound(fallbackMessage) {
                // CHANGE: even the fallback alias 404'd — very unusual, but
                // report it clearly instead of a confusing generic error.
                throw GeminiError.modelUnavailable(triedModels: [model, fallbackModel])
            }
            // Any other error from the fallback attempt (rate limit, etc.)
            // propagates as-is from the inner `try`.
        }
        // Any non-404 error from the primary attempt propagates as-is.
    }

    // CHANGE: extracted the actual network call so both the primary and
    // fallback attempts share identical request-building/parsing logic.
    private func performRequest(ocrText: String, model: String) async throws -> String {
        guard let url = endpoint(for: model) else { throw GeminiError.invalidURL }

        let prompt = Self.buildPrompt(from: ocrText)

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 350,
                "topP": 0.9
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            let retryAfter = Self.parseRetryDelay(from: data)
            throw GeminiError.rateLimited(retryAfter: retryAfter)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.parseErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(httpResponse.statusCode)"
            throw GeminiError.apiError(message)
        }

        return try Self.parseAnswer(from: data)
    }

    // CHANGE: distinguishes "model doesn't exist" from any other API error
    // message. Google's 404 body reliably contains "is not found for API
    // version" — matching on that substring rather than just status code
    // 404 alone, since parseErrorMessage already discarded the numeric
    // status code by the time this is checked.
    private static func isModelNotFound(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("is not found for API version")
            || message.localizedCaseInsensitiveContains("NOT_FOUND")
            || message.localizedCaseInsensitiveContains("no longer available")
            || message.localizedCaseInsensitiveContains("is deprecated")
            || message.localizedCaseInsensitiveContains("is not supported")
    }

    // MARK: - Prompt engineering for dirty OCR text

    private static func buildPrompt(from ocrText: String) -> String {
        """
        You are helping someone who just scanned a page (textbook, worksheet, slide, \
        or sign) with a phone camera. The text below came out of an on-device OCR \
        engine running in fast mode, so it MAY be noisy: missing Vietnamese diacritics, \
        misrecognized look-alike characters, merged or split words, broken line breaks, \
        or stray symbols.

        Do this:
        1. Silently reconstruct the most likely original question or exercise from the \
        noisy text below — don't show your reconstruction.
        2. If it is a question or exercise, answer it directly and concisely.
        3. If it isn't a question (just a heading, label, or caption), say briefly what \
        it appears to be — don't invent an answer to a question that isn't there.
        4. Reply in whichever language the reconstructed text is in (Vietnamese or \
        English), matching the register of a helpful tutor.
        5. Do not repeat the raw OCR text back to the user and do not narrate your \
        reasoning process.
        6. Keep the answer short and focused: a few sentences, or a short list — not \
        an essay.

        Noisy OCR text:
        \"\"\"
        \(ocrText)
        \"\"\"
        """
    }

    // MARK: - Response parsing

    private static func parseAnswer(from data: Data) throws -> String {
        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.emptyAnswer
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseErrorMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct ErrorBody: Decodable { let message: String? }
            let error: ErrorBody?
        }
        guard let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else {
            return nil
        }
        return decoded.error?.message
    }

    private static func parseRetryDelay(from data: Data) -> TimeInterval? {
        struct ErrorEnvelope: Decodable {
            struct ErrorBody: Decodable {
                struct Detail: Decodable { let retryDelay: String? }
                let details: [Detail]?
            }
            let error: ErrorBody?
        }
        guard let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let detail = decoded.error?.details?.first(where: { $0.retryDelay != nil }),
              let raw = detail.retryDelay else {
            return nil
        }
        let numeric = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        return TimeInterval(numeric)
    }
}