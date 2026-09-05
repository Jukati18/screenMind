import Foundation

/// Decides whether newly-OCR'd text is "different enough" from the last text
/// we sent to Gemini to justify another API call. This is what keeps the app
/// from spamming the network on every near-identical frame while the camera
/// is just holding steady on the same page.
struct TextChangeDetector {
    private var lastSentText: String = ""

    /// - Returns: true if `newText` should be sent to Gemini.
    mutating func shouldSend(newText: String) -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ignore near-empty OCR noise.
        guard trimmed.count > 3 else { return false }

        // Don't resend the exact same text we already sent.
        guard trimmed != lastSentText else { return false }

        // A question mark is a strong signal this is a new exercise/question,
        // so treat it as an immediate trigger.
        if trimmed.contains("?") {
            lastSentText = trimmed
            return true
        }

        // Otherwise require a meaningful edit distance vs. the last sent text.
        let diffRatio = Self.differenceRatio(lastSentText, trimmed)
        if diffRatio > 0.3 {
            lastSentText = trimmed
            return true
        }
        return false
    }

    mutating func reset() {
        lastSentText = ""
    }

    // MARK: - Similarity

    /// 0 = identical, 1 = completely different. Normalized Levenshtein distance.
    private static func differenceRatio(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        if a.isEmpty || b.isEmpty { return 1 }
        let distance = levenshtein(a, b)
        let maxLength = max(a.count, b.count)
        return Double(distance) / Double(maxLength)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var dp = Array(repeating: Array(repeating: 0, count: bChars.count + 1), count: aChars.count + 1)

        for i in 0...aChars.count { dp[i][0] = i }
        for j in 0...bChars.count { dp[0][j] = j }

        guard aChars.count > 0, bChars.count > 0 else { return max(aChars.count, bChars.count) }

        for i in 1...aChars.count {
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
                }
            }
        }
        return dp[aChars.count][bChars.count]
    }
}
