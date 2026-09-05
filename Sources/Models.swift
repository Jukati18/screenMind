import Foundation

/// Drives the status badge and UI affordances (loading spinner, colors, etc.)
enum AppProcessingState: Equatable {
    case idle
    case scanning
    case sendingToAI
    case answerReady
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning…"
        case .sendingToAI: return "Sending to AI…"
        case .answerReady: return "Answer ready"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// One resolved question/answer pair, kept for the in-app history list.
struct HistoryItem: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let answer: String
    let date: Date
}
