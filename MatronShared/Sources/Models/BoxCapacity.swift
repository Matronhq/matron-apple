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

/// A box's own capacity report as the journal stores it (journal PR #82):
/// the bridge sends `box_status` on every hello, after each usage-limits
/// refresh and at shutdown, and the journal serves the latest one as
/// `status` on `GET /devices` and fans it live as a `box_status` frame. Same
/// blocks as a `recent_folders` reply, plus when the box reported them —
/// the journal's clock, so a sleeping box's numbers carry an honest age.
public struct BoxStatus: Equatable, Sendable {
    public let reportedAt: Date
    public let capacity: BoxCapacity

    public init(reportedAt: Date, capacity: BoxCapacity) {
        self.reportedAt = reportedAt
        self.capacity = capacity
    }

    /// Parses a `status` object or a `box_status` frame (both carry
    /// `reported_at` in epoch ms beside the blocks). Nil without a usable
    /// `reported_at`: an unaged report can't be captioned honestly, so it
    /// is treated as no report at all. The blocks degrade as in
    /// `BoxCapacity.parse`.
    public static func parse(_ object: [String: Any]) -> BoxStatus? {
        guard let millis = object["reported_at"] as? NSNumber,
              CFGetTypeID(millis) != CFBooleanGetTypeID() else { return nil }
        return BoxStatus(reportedAt: Date(timeIntervalSince1970: millis.doubleValue / 1000),
                         capacity: BoxCapacity.parse(replyObject: object))
    }
}

/// A box's `disk` block: free and total bytes on its working volume.
public struct BoxDisk: Equatable, Sendable {
    public let freeBytes: Int64
    public let totalBytes: Int64

    public init(freeBytes: Int64, totalBytes: Int64) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }

    /// Whole percent of the volume still free.
    public var percentFree: Int { Int((Double(freeBytes) / Double(totalBytes) * 100).rounded()) }

    /// Nil unless both sizes are whole, non-negative and consistent.
    static func parse(_ object: [String: Any]?) -> BoxDisk? {
        guard let free = BoxCapacity.wholeInt64(object?["free_bytes"]),
              let total = BoxCapacity.wholeInt64(object?["total_bytes"]),
              free >= 0, total > 0, free <= total else { return nil }
        return BoxDisk(freeBytes: free, totalBytes: total)
    }

    /// 1024-based and dense: "7.4G", "233G", "1.8T". One decimal under ten,
    /// whole numbers above; the reader is judging "is this box full".
    public static func sizeText(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        // The unit is picked before rounding, so 1023.9G must carry to 1.0T.
        if value >= 1023.5, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number = value >= 10 || value == value.rounded()
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
        return number + units[index]
    }
}

/// What a new session on the box starts as, resolved by the bridge (the
/// journal's box defaults, else the box's own environment).
public struct BoxResolvedDefaults: Equatable, Sendable {
    public let agent: String
    public let model: String?
    public let effort: String?

    public init(agent: String, model: String?, effort: String?) {
        self.agent = agent
        self.model = model
        self.effort = effort
    }

    static func parse(_ object: [String: Any]?) -> BoxResolvedDefaults? {
        guard let agent = object?["agent"] as? String, !agent.isEmpty else { return nil }
        return BoxResolvedDefaults(agent: agent, model: object?["model"] as? String,
                                   effort: object?["effort"] as? String)
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
    /// The `disk` block — nil when the bridge sent none.
    public let disk: BoxDisk?
    /// `limits.as_of`: when the usage numbers themselves were read, which
    /// can be well before the report that carried them.
    public let limitsAsOf: Date?
    /// The `defaults` block — nil for a bridge predating it.
    public let defaults: BoxResolvedDefaults?

    public init(liveSessions: Int?, limitLines: [LimitLine], accountEmail: String?,
                disk: BoxDisk? = nil, limitsAsOf: Date? = nil,
                defaults: BoxResolvedDefaults? = nil) {
        self.liveSessions = liveSessions
        self.limitLines = limitLines
        self.accountEmail = accountEmail
        self.disk = disk
        self.limitsAsOf = limitsAsOf
        self.defaults = defaults
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

        let limits = replyObject["limits"] as? [String: Any]
        let lines = (limits?["lines"] as? [[String: Any]]) ?? []
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
                           accountEmail: (email?.isEmpty == false) ? email : nil,
                           disk: BoxDisk.parse(replyObject["disk"] as? [String: Any]),
                           limitsAsOf: wholeInt64(limits?["as_of"]).map {
                               Date(timeIntervalSince1970: Double($0) / 1000)
                           },
                           defaults: BoxResolvedDefaults.parse(replyObject["defaults"] as? [String: Any]))
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

    /// A JSON number that has to be whole but may be large: byte counts and
    /// epoch milliseconds, which `wholeNumber`'s Int32 bound would drop.
    static func wholeInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return number.int64Value
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
    /// the given calendar, "resets Fri 5 PM" within the next seven days (a
    /// weekly limit's reset always is; `resetCountdown` tells a reset a week
    /// off from one later today), else "resets Aug 15". A reset already behind `now`
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
        // Same-day resets read best as a clock time, this week's as a
        // weekday and hour, anything later as a date.
        let onTheHour = calendar.component(.minute, from: date) == 0
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
        } else if date.timeIntervalSince(now) < 7 * 86_400 {
            formatter.dateFormat = onTheHour ? "EEE h a" : "EEE h:mm a"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return "resets \(formatter.string(from: date))"
    }

    /// How long until a reset more than six hours off: "in 30h", "in 3d 4h",
    /// so which box's week ends first reads at a glance. Nil for an unknown
    /// or nearer reset (its clock time is close enough to read).
    public static func resetCountdown(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval >= 6 * 3600 else { return nil }
        let hours = Int(interval / 3600)
        if hours < 48 { return "in \(hours)h" }
        let rest = hours % 24
        return "in \(hours / 24)d" + (rest == 0 ? "" : " \(rest)h")
    }

    /// A limit line's whole reset caption: `resetText`, then the countdown
    /// when there is one — "resets Fri 5 PM · in 30h".
    public static func resetCaption(_ date: Date?, now: Date = Date(),
                                    calendar: Calendar = .current) -> String? {
        guard let text = resetText(date, now: now, calendar: calendar) else { return nil }
        return resetCountdown(date, now: now).map { "\(text) · \($0)" } ?? text
    }
}
