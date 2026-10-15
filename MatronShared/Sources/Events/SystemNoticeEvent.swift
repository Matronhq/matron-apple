import Foundation

/// A bridge notice about a turn the bridge injected into the session — a
/// consent request, a routine fire, a room message, a spawn outcome, a
/// reminder. The bridge publishes it as a `text` event and tags it with
/// `payload.notice = {kind, icon, summary}`; the timeline shows it as one
/// short row (icon, summary, time) that expands to the full `body`. Agent
/// replies never carry the tag, so they keep rendering as text.
public struct SystemNoticeEvent: Equatable, Sendable {
    /// `consent`, `routine`, `room`, `spawn`… — informational; an unknown
    /// kind renders the same way.
    public let kind: String
    /// The emoji the row leads with.
    public let icon: String
    /// One line, at most `summaryMax` characters.
    public let summary: String
    /// The notice's full text, shown when the row is expanded.
    public let body: String

    static let summaryMax = 200
    static let iconMax = 8
    static let fallbackIcon = "ℹ️"

    public init(kind: String, icon: String, summary: String, body: String) {
        self.kind = kind; self.icon = icon; self.summary = summary; self.body = body
    }

    /// The tag on a text payload, or nil when it has none (or an unusable
    /// one) — the event then renders as ordinary text.
    public static func parse(payload: [String: Any]) -> SystemNoticeEvent? {
        guard let notice = payload["notice"] as? [String: Any] else { return nil }
        let summary = oneLine(notice["summary"], max: summaryMax)
        guard !summary.isEmpty else { return nil }
        let icon = oneLine(notice["icon"], max: iconMax)
        let kind = oneLine(notice["kind"], max: 32)
        return SystemNoticeEvent(
            kind: kind.isEmpty ? "notice" : kind,
            icon: icon.isEmpty ? fallbackIcon : icon,
            summary: summary,
            body: payload["body"] as? String ?? "")
    }

    private static func oneLine(_ value: Any?, max: Int) -> String {
        guard let s = value as? String else { return "" }
        let flat = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
