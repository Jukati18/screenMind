import Foundation

enum GeminiError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Gemini API URL."
        case .invalidResponse: return "Invalid response from Gemini."
        case .apiError(let msg): return "Gemini API error: \(msg)"
        case .emptyAnswer: return "Gemini returned an empty answer."
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

    /// - Parameters:
    ///   - apiKey: get one at https://aistudio.google.com/app/apikey
    ///   - model: "gemini-2.0-flash" (recommended) or "gemini-1.5-flash".
    init(apiKey: String = "YOUR_GEMINI_API_KEY", model: String = "gemini-2.0-flash") {
        self.apiKey = apiKey
        self.model = model
    }

    private var endpoint: URL? {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")
    }

    // MARK: - Request

    func ask(ocrText: String) async throws -> String {
        guard let url = endpoint else { throw GeminiError.invalidURL }

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
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw GeminiError.apiError(message)
        }

        return try Self.parseAnswer(from: data)
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
}
