import Foundation

/// One finished weekly window of a usage meter: what was left unused when
/// it reset.
public struct UsageWeek: Equatable, Sendable {
    public let resetsAt: Date
    /// 0 to 100: the allowance left when the week reset.
    public let unused: Int
    /// The highest reading of the week, as a percentage used.
    public let peak: Int
    /// When the last reading before the reset was taken.
    public let lastReadingAt: Date?

    public init(resetsAt: Date, unused: Int, peak: Int, lastReadingAt: Date?) {
        self.resetsAt = resetsAt
        self.unused = unused
        self.peak = peak
        self.lastReadingAt = lastReadingAt
    }
}

/// The week still running: what is left so far.
public struct UsageWeekInProgress: Equatable, Sendable {
    public let resetsAt: Date
    public let unused: Int
    public let asOf: Date?

    public init(resetsAt: Date, unused: Int, asOf: Date?) {
        self.resetsAt = resetsAt
        self.unused = unused
        self.asOf = asOf
    }
}

/// One weekly meter of an account ("Week (all models)", "Week (Fable)").
public struct UsageMeter: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// The account's headline meter.
    public let isPrimary: Bool
    public let current: UsageWeekInProgress?
    /// Finished weeks, newest first.
    public let weeks: [UsageWeek]

    public init(id: String, label: String, isPrimary: Bool, current: UsageWeekInProgress?, weeks: [UsageWeek]) {
        self.id = id
        self.label = label
        self.isPrimary = isPrimary
        self.current = current
        self.weeks = weeks
    }
}

/// One login's allowance. Boxes sharing a login are one account.
public struct UsageAccount: Equatable, Sendable, Identifiable {
    public let id: String
    /// "claude" or "codex".
    public let agent: String
    /// Nil for a box that reports no login: it is then its own account.
    public let email: String?
    public let boxes: [String]
    public let meters: [UsageMeter]

    public init(id: String, agent: String, email: String?, boxes: [String], meters: [UsageMeter]) {
        self.id = id
        self.agent = agent
        self.email = email
        self.boxes = boxes
        self.meters = meters
    }

    /// The login, else the box, else a stand-in for a box since removed.
    public var title: String { email ?? boxes.first ?? "Removed box" }

    /// "Claude · 3 boxes", or "Codex" for a box that is its own account.
    public var subtitle: String {
        let name = agent == "codex" ? "Codex" : "Claude"
        guard email != nil, !boxes.isEmpty else { return name }
        return "\(name) · \(boxes.count) \(boxes.count == 1 ? "box" : "boxes")"
    }
}

/// `GET /usage/history`: every account's weekly meters over the last weeks.
public struct UsageHistory: Equatable, Sendable {
    public let accounts: [UsageAccount]

    public init(accounts: [UsageAccount]) {
        self.accounts = accounts
    }

    /// Nil when the reply has no `accounts` list. A malformed account, meter
    /// or week is skipped, not the whole reply.
    public static func parse(_ object: [String: Any]) -> UsageHistory? {
        guard let rows = object["accounts"] as? [[String: Any]] else { return nil }
        return UsageHistory(accounts: rows.compactMap(parseAccount))
    }

    private static func parseAccount(_ row: [String: Any]) -> UsageAccount? {
        guard let key = row["key"] as? String, !key.isEmpty else { return nil }
        let email = row["email"] as? String
        let meters = (row["meters"] as? [[String: Any]] ?? []).compactMap(parseMeter)
        return UsageAccount(id: key, agent: row["agent"] as? String ?? "claude",
                            email: (email?.isEmpty == false) ? email : nil,
                            boxes: row["boxes"] as? [String] ?? [], meters: meters)
    }

    private static func parseMeter(_ row: [String: Any]) -> UsageMeter? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let label = row["label"] as? String
        let weeks = (row["windows"] as? [[String: Any]] ?? []).compactMap { week -> UsageWeek? in
            guard let resetsAt = (week["resets_at"] as? String).flatMap(BoxCapacity.parseISODate),
                  let unused = BoxCapacity.wholeNumber(week["unused"]) else { return nil }
            return UsageWeek(resetsAt: resetsAt, unused: clamp(unused),
                             peak: clamp(BoxCapacity.wholeNumber(week["peak"]) ?? (100 - unused)),
                             lastReadingAt: date(week["last_at"]))
        }
        let current = (row["current"] as? [String: Any]).flatMap { now -> UsageWeekInProgress? in
            guard let resetsAt = (now["resets_at"] as? String).flatMap(BoxCapacity.parseISODate),
                  let unused = BoxCapacity.wholeNumber(now["unused"]) else { return nil }
            return UsageWeekInProgress(resetsAt: resetsAt, unused: clamp(unused), asOf: date(now["as_of"]))
        }
        return UsageMeter(id: id, label: (label?.isEmpty == false) ? label! : id,
                          isPrimary: row["primary"] as? Bool ?? false, current: current,
                          weeks: weeks.sorted { $0.resetsAt > $1.resetsAt })
    }

    private static func clamp(_ percent: Int) -> Int { min(max(percent, 0), 100) }

    private static func date(_ milliseconds: Any?) -> Date? {
        BoxCapacity.wholeInt64(milliseconds).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// Which meter the usage history shows: each account's headline meter, or
/// one of the model meters by its label.
public struct UsageMeterChoice: Equatable, Sendable, Identifiable {
    public static let primaryID = "primary"
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public var isPrimary: Bool { id == Self.primaryID }
}

/// The usage history as a grid: an account per row, a calendar week per
/// column. Off the views so it unit-tests.
public struct UsageHistoryTable: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let subtitle: String
        /// One per column, oldest first; nil for a week with no reading.
        public let cells: [UsageWeek?]
        public let current: UsageWeekInProgress?
        /// The mean unused over the weeks shown; nil when there are none.
        public let averageUnused: Int?

        /// The newest finished week on show.
        public var latest: UsageWeek? { cells.reversed().compactMap { $0 }.first }
    }

    /// The Monday each column's week starts on, oldest first.
    public let columns: [Date]
    public let rows: [Row]
    /// The mean unused across accounts per column; nil where no account
    /// has a reading.
    public let columnAverages: [Int?]

    public static let defaultWeeks = 12

    /// The headline meter first, then each model meter any account has.
    public static func choices(for history: UsageHistory) -> [UsageMeterChoice] {
        var choices = [UsageMeterChoice(id: UsageMeterChoice.primaryID, title: "All models")]
        for meter in history.accounts.flatMap(\.meters) where !meter.isPrimary {
            if !choices.contains(where: { $0.id == meter.label }) {
                choices.append(UsageMeterChoice(id: meter.label, title: shortTitle(meter.label)))
            }
        }
        return choices
    }

    /// "Week (Fable)" reads "Fable"; any other label is kept whole.
    static func shortTitle(_ label: String) -> String {
        guard label.hasPrefix("Week ("), label.hasSuffix(")") else { return label }
        return String(label.dropFirst(6).dropLast())
    }

    /// A week sits in the column of the calendar week (Monday to Sunday,
    /// UTC) its reset falls in. An account resets once a week, so it has at
    /// most one finished week per column; if two land in one, the later
    /// reset is shown. Accounts without the chosen meter are left out.
    public static func build(_ history: UsageHistory, choice: UsageMeterChoice,
                             weeks: Int = defaultWeeks, now: Date = Date()) -> UsageHistoryTable {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let columns = (0..<max(weeks, 1)).reversed().compactMap {
            calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }
        let rows = history.accounts.compactMap { account -> Row? in
            let meter = choice.isPrimary
                ? account.meters.first(where: \.isPrimary)
                : account.meters.first { !$0.isPrimary && $0.label == choice.id }
            guard let meter else { return nil }
            let cells = columns.map { start -> UsageWeek? in
                let end = start.addingTimeInterval(7 * 86_400)
                return meter.weeks.first { $0.resetsAt >= start && $0.resetsAt < end }
            }
            return Row(id: account.id, title: account.title, subtitle: account.subtitle, cells: cells,
                       current: meter.current, averageUnused: mean(cells.compactMap { $0?.unused }))
        }
        let averages = columns.indices.map { index in mean(rows.compactMap { $0.cells[index]?.unused }) }
        return UsageHistoryTable(columns: columns, rows: rows, columnAverages: averages)
    }

    private static func mean(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    /// How strongly to tint a cell: the more left unused, the stronger.
    public static func tintOpacity(unused: Int) -> Double {
        0.10 + 0.75 * Double(min(max(unused, 0), 100)) / 100
    }

    /// "alice@example.com, week ending 5 Jan: 28% unused".
    public static func accessibilityText(account: String, week: UsageWeek) -> String {
        "\(account), week ending \(week.resetsAt.formatted(.dateTime.day().month(.abbreviated))): \(week.unused)% unused"
    }
}
