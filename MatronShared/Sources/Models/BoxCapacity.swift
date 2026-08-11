import Foundation

/// One usage-limit meter from a bridge's `recent_folders` → `limits.lines`
/// (spec: 2026-08-11-chooser-capacity-design.md). Deliberately NOT
/// `SessionStatus.Limit`: that one is a per-conversation status frame line
/// (raw `resets` text, no stable id), while these are keyed by the bridge's
/// line id so a chooser row can `ForEach` them.
public struct LimitLine: Equatable, Sendable, Identifiable {
    public var id: String
    public let label: String
    public let percent: Int
    public let resetsAt: Date?

    public init(id: String, label: String, percent: Int, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

/// The capacity blocks a bridge attaches to its `recent_folders` reply:
/// live-session count, usage-limit lines, logged-in account. Every block is
/// optional wire-side (an old bridge omits them all), so parsing degrades
/// per-block and can never fail the folders parse it rides along with.
///
/// Lives in `MatronModels` (like `SessionStatus`) so the view model that
/// parses it and the design-system row that renders it can both see it
/// without the design system depending on view models.
public struct BoxCapacity: Equatable, Sendable {
    /// `activity.live_sessions` — nil when the bridge sent no activity block.
    public let liveSessions: Int?
    /// `limits.lines` in bridge order.
    public let limitLines: [LimitLine]
    /// `account.email` — nil for API-key accounts and older bridges.
    public let accountEmail: String?

    public init(liveSessions: Int?, limitLines: [LimitLine], accountEmail: String?) {
        self.liveSessions = liveSessions
        self.limitLines = limitLines
        self.accountEmail = accountEmail
    }

    /// Parses the capacity blocks out of a `recent_folders` reply object.
    /// Never throws; every block degrades independently. `activity.last_hour`
    /// is ignored on purpose — it's a spawn-side detail and the folder step
    /// already shows recent paths.
    public static func parse(replyObject: [String: Any]) -> BoxCapacity {
        let activity = replyObject["activity"] as? [String: Any]
        let liveSessions = (activity?["live_sessions"] as? NSNumber)?.intValue

        let lines = ((replyObject["limits"] as? [String: Any])?["lines"] as? [[String: Any]]) ?? []
        let limitLines = lines.compactMap { line -> LimitLine? in
            guard let id = line["id"] as? String, !id.isEmpty,
                  let label = line["label"] as? String, !label.isEmpty,
                  let percent = (line["percent"] as? NSNumber)?.intValue else { return nil }
            let resetsAt = (line["resets_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            return LimitLine(id: id, label: label,
                             percent: min(max(percent, 0), 999), resetsAt: resetsAt)
        }

        let email = (replyObject["account"] as? [String: Any])?["email"] as? String
        return BoxCapacity(liveSessions: liveSessions, limitLines: limitLines,
                           accountEmail: (email?.isEmpty == false) ? email : nil)
    }

    /// Compact reset caption: "resets 11:59 PM" if the reset falls today in
    /// the given calendar, else "resets Aug 15". Nil `date` → nil, so the
    /// caller drops the trailing text (the limit line still renders).
    public static func resetText(_ date: Date?, now: Date = Date(),
                                calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Same-day resets read best as a clock time; anything later as a date.
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d"
        return "resets \(formatter.string(from: date))"
    }
}
