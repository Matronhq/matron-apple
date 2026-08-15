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

/// One fleet-wide usage column in the Mac New Chat chooser: the union of
/// every box's limit-line ids, so all rows align to the same columns even
/// when an individual bridge reports fewer lines.
public struct LimitColumn: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
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

    /// True when this capacity carries anything the chooser grid can show.
    /// Legacy bridges answer `recent_folders` without capacity blocks and
    /// parse to an empty value — that entry must not summon the grid chrome
    /// (header + placeholder cells). `accountEmail` doesn't count: it renders
    /// in the box cell, not the grid.
    public var hasDisplayableData: Bool {
        liveSessions != nil || !limitLines.isEmpty
    }

    /// Parses the capacity blocks out of a `recent_folders` reply object.
    /// Never throws; every block degrades independently. `activity.last_hour`
    /// is ignored on purpose — it's a spawn-side detail and the folder step
    /// already shows recent paths.
    public static func parse(replyObject: [String: Any]) -> BoxCapacity {
        let activity = replyObject["activity"] as? [String: Any]
        // A negative count is malformed and would flip `hasDisplayableData`;
        // drop it here rather than in `wholeNumber`, whose callers for
        // `percent` clamp negatives instead.
        let liveSessions = wholeNumber(activity?["live_sessions"])
            .flatMap { $0 >= 0 ? $0 : nil }

        let lines = ((replyObject["limits"] as? [String: Any])?["lines"] as? [[String: Any]]) ?? []
        let limitLines = lines.compactMap { line -> LimitLine? in
            guard let id = line["id"] as? String, !id.isEmpty,
                  let label = line["label"] as? String, !label.isEmpty,
                  let percent = wholeNumber(line["percent"]) else { return nil }
            let resetsAt = (line["resets_at"] as? String).flatMap(parseISODate)
            return LimitLine(id: id, label: label,
                             percent: min(max(percent, 0), 999), resetsAt: resetsAt)
        }

        let email = (replyObject["account"] as? [String: Any])?["email"] as? String
        return BoxCapacity(liveSessions: liveSessions, limitLines: limitLines,
                           accountEmail: (email?.isEmpty == false) ? email : nil)
    }

    /// Union of limit lines across a fleet, in first-encounter order — the
    /// caller passes capacities in its display (sorted-agents) order, which
    /// keeps the result deterministic. The label is the first one seen for
    /// an id; bridges of one journal all derive labels the same way.
    public static func limitColumns(across capacities: [BoxCapacity]) -> [LimitColumn] {
        var seen = Set<String>()
        var columns: [LimitColumn] = []
        for capacity in capacities {
            for line in capacity.limitLines where seen.insert(line.id).inserted {
                columns.append(LimitColumn(id: line.id, label: line.label))
            }
        }
        return columns
    }

    /// A JSON number that has to be a whole count. `JSONSerialization`
    /// bridges `true` to an `NSNumber`, so a plain `intValue` would read a
    /// Boolean as 1, and it silently truncates `39.5` to 39. Both are wire
    /// contract violations — drop the field like every other malformed value
    /// here rather than inventing a number for it.
    static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        // Both fields are small counts; anything past Int32 is malformed too.
        guard double.rounded() == double, abs(double) <= 2_147_483_647 else { return nil }
        return number.intValue
    }

    /// Bridge timestamps come from `Date.toISOString()` (always fractional),
    /// but plain ISO is accepted too — the same two-formatter rule
    /// `WireModels` uses. `ISO8601DateFormatter` is thread-safe, so shared
    /// statics are fine.
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseISODate(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    /// True when the line's reset moment is known and already behind `now`:
    /// the limit has rolled over since the bridge cached this line, so the
    /// percent on screen predates the reset. Callers de-emphasise the stale
    /// number instead of presenting it as current.
    public static func hasReset(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date <= now
    }

    /// Compact reset caption: "resets 11:59 PM" if the reset falls today in
    /// the given calendar, else "resets Aug 15". A reset already behind `now`
    /// reads "reset" — showing a past moment as upcoming ("resets 5:30 PM"
    /// the day after) is how stale cache lines used to masquerade as live.
    /// Nil `date` → nil, so the caller drops the trailing text (the limit
    /// line still renders).
    public static func resetText(_ date: Date?, now: Date = Date(),
                                calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        if date <= now { return "reset" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // A fixed `dateFormat` still renders its symbols (AM/PM, "Aug") in
        // the formatter's locale, so take that from the calendar too: a
        // caller passing a fixed calendar gets a fixed caption, while the
        // `.current` default keeps the user's own language.
        formatter.locale = calendar.locale ?? .current
        // Same-day resets read best as a clock time; anything later as a date.
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d"
        return "resets \(formatter.string(from: date))"
    }
}
