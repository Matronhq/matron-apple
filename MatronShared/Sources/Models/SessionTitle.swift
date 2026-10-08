import Foundation

/// The bridge's `{marker }[xx] {topic}` title shape, parsed here so the leaf
/// modules (design system, models) can read it too. `SessionTag.splitTitle`
/// (MatronChat) is the public face; it delegates here.
public enum SessionTitle {
    /// The bridge's multi-agent room markers (`↔️ [ab] mac ↔ dev-z`,
    /// matron-bridge#225/#228; 🔗 is the legacy one). Mirrored by
    /// `JournalEventType.agentRoomTitleMarkers`.
    public static let roomMarkers = ["↔️ ", "🔗 "]

    /// Every marker that may lead a title ahead of the short: the room
    /// markers and 🐣 (a session another agent spawned, matron-bridge#227).
    public static let markers = roomMarkers + ["🐣 "]

    /// Whether `conversationTitle` already says one of `labels` (a
    /// mission's `name` or `title`): equal to it once the `[xx]` short and
    /// any marker are peeled off and whitespace is collapsed — or the
    /// journal's cut of the title (at most 40 characters, ending "…",
    /// trailing punctuation dropped), which the full label then starts
    /// with. A mission-named conversation (journal PR 136) is titled
    /// "[xx] {mission name}", so this is how the chat-header chip and the
    /// For you origin labels avoid saying the mission's name twice.
    public static func names(_ labels: [String?], conversationTitle: String?) -> Bool {
        guard let conversationTitle else { return false }
        var shown = split(conversationTitle).title
        if let marker = markers.first(where: { shown.hasPrefix($0) }) {
            shown = String(shown.dropFirst(marker.count))
        }
        shown = collapsed(shown)
        guard !shown.isEmpty else { return false }
        let stem = shown.hasSuffix("…") ? collapsed(String(shown.dropLast())) : nil
        return labels.compactMap { $0 }.map(collapsed).contains { label in
            guard !label.isEmpty else { return false }
            if label == shown { return true }
            guard let stem, !stem.isEmpty else { return false }
            return label.hasPrefix(stem)
        }
    }

    private static func collapsed(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// See `SessionTag.splitTitle`.
    public static func split(_ raw: String) -> (sessionShort: String?, title: String) {
        if let marker = markers.first(where: { raw.hasPrefix($0) }) {
            let (short, rest) = split(String(raw.dropFirst(marker.count)))
            guard short != nil else { return (nil, raw) }
            return (short, marker + rest)
        }
        guard raw.hasPrefix("["),
              let close = raw.firstIndex(of: "]") else { return (nil, raw) }
        let short = raw[raw.index(after: raw.startIndex)..<close]
        guard short.count == 2, short.allSatisfy({ $0.isLetter || $0.isNumber }) else { return (nil, raw) }
        let rest = raw[raw.index(after: close)...]
        guard rest.first == " " else { return (nil, raw) }
        let title = String(rest.dropFirst())
        guard !title.isEmpty else { return (nil, raw) }
        return (String(short), title)
    }
}
