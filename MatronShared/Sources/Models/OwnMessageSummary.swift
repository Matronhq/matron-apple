import Foundation

/// One message the user themself sent in a conversation, as listed by the
/// Coordinator's "Your requests" (tracker #2864 B): enough to show a row and
/// to jump the transcript to it. `seq` is the journal seq, which is also the
/// transcript row id.
public struct OwnMessageSummary: Equatable, Identifiable, Sendable {
    public let seq: Int64
    public let date: Date
    /// The message's text — the body, an attachment's caption, or its file
    /// name when there is no caption. Never empty.
    public let text: String

    public var id: Int64 { seq }

    public init(seq: Int64, date: Date, text: String) {
        self.seq = seq
        self.date = date
        self.text = text
    }

    /// The row's one-line preview: the first non-blank line, whitespace
    /// trimmed, cut at `limit` characters with an ellipsis.
    public func preview(limit: Int = 120) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard firstLine.count > limit else { return firstLine }
        return String(firstLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
