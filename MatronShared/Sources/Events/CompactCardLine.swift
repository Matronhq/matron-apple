import Foundation

/// The one quiet line a bulky timeline card folds to (icon, summary and,
/// once it is settled, a short status), drawn by `CompactCardRow` the way a
/// bridge notice is: click it for the whole card. A reminder's Send now /
/// Cancel card is always folded; a consent card folds once it is answered,
/// because until then the facts it shows are what the decision rests on.
public struct CompactCardLine: Equatable, Sendable {
    public let icon: String
    public let summary: String
    public let status: String?

    public init(icon: String, summary: String, status: String?) {
        self.icon = icon
        self.summary = summary
        self.status = status
    }

    /// `text` on one line: runs of whitespace and line breaks become one
    /// space.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// A leading emoji or symbol followed by a space, split off ("⏰ In
    /// 10m" → "⏰", "In 10m"); `nil` and the text untouched otherwise.
    static func leadingGlyph(_ text: String) -> (glyph: String?, rest: String) {
        guard let first = text.first, !first.isWhitespace, !first.isLetter, !first.isNumber,
              !first.isPunctuation,
              let next = text.dropFirst().first, next.isWhitespace else { return (nil, text) }
        let rest = text.dropFirst().drop(while: \.isWhitespace)
        return rest.isEmpty ? (nil, text) : (String(first), String(rest))
    }
}

extension AskUserEvent {
    /// The bridge's reminder card: a choice whose every option is one of
    /// its `timer:` actions (Send now, Cancel timer).
    public var isReminderCard: Bool {
        guard case .choice(let options, _) = kind, !options.isEmpty else { return false }
        return options.allSatisfy { $0.value.hasPrefix("timer:") }
    }

    /// The prompt on one line, its leading glyph as the icon.
    public var compactLine: CompactCardLine {
        let split = CompactCardLine.leadingGlyph(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        return CompactCardLine(icon: split.glyph ?? "⏰", summary: CompactCardLine.oneLine(split.rest), status: nil)
    }
}

extension AgentSpawnRequest {
    /// `nil` while the request still waits for an answer.
    public func compactLine(_ state: AgentSpawnCardState) -> CompactCardLine? {
        guard case .resolved(let outcome) = state else { return nil }
        let (icon, status): (String, String) = switch outcome.kind {
        case .started: ("🚀", "Started")
        case .declined: ("🚫", "Declined")
        case .expired: ("⌛", "Expired")
        case .approved: ("✅", "Approved")
        case .failed: ("❌", "Failed")
        case nil: ("✨", "Resolved")
        }
        return CompactCardLine(icon: icon, summary: "Spawn on \(targetLabel): \(headline)", status: status)
    }
}

extension AgentChatRequest {
    /// `nil` while the request still waits for an answer.
    public func compactLine(_ state: AgentChatCardState) -> CompactCardLine? {
        let status: String
        switch state {
        case .idle, .sending, .failed: return nil
        case .answered(let approved): status = approved ? "Approved" : "Declined"
        case .answeredByCoordinator(let approved):
            status = approved ? "Approved by the Coordinator" : "Declined by the Coordinator"
        case .expired: status = "No longer waiting"
        }
        return CompactCardLine(icon: "👥", summary: CompactCardLine.oneLine(headline), status: status)
    }
}
