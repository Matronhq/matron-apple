import Foundation

/// One box's usage numbers, as the Boxes screen weighs them.
public struct BoxAllowanceReading: Equatable, Sendable {
    public let boxID: Int64
    public let accountEmail: String?
    public let lines: [LimitLine]

    public init(boxID: Int64, accountEmail: String?, lines: [LimitLine]) {
        self.boxID = boxID
        self.accountEmail = accountEmail
        self.lines = lines
    }
}

/// The login with the most allowance to spend per day before it resets.
public struct AllowanceSpare: Equatable, Sendable {
    /// Nil for boxes that report no login.
    public let accountEmail: String?
    /// Every box on this login, in reading order.
    public let boxIDs: [Int64]
    public let percentLeft: Int
    public let percentPerDay: Int
    public let resetsAt: Date

    public init(accountEmail: String?, boxIDs: [Int64], percentLeft: Int, percentPerDay: Int, resetsAt: Date) {
        self.accountEmail = accountEmail
        self.boxIDs = boxIDs
        self.percentLeft = percentLeft
        self.percentPerDay = percentPerDay
        self.resetsAt = resetsAt
    }
}

/// The Boxes screen's two highlights, off the views so they unit-test.
public enum BoxAllowances {
    /// The bridge's stable id for the all-models weekly meter.
    public static let allModelsLineID = "week_all"
    /// Where a usage percentage turns red everywhere else in the app.
    public static let nearLimitPercent = 80

    /// Whether the box's weekly meter is near its limit. An expired line
    /// predates its reset, so it no longer says anything about today.
    public static func isNearLimit(_ lines: [LimitLine], now: Date = Date()) -> Bool {
        guard let line = lines.first(where: { $0.id == allModelsLineID }) else { return false }
        return line.percent >= nearLimitPercent && !BoxCapacity.hasReset(line.resetsAt, now: now)
    }

    /// The login with the highest percent left per day until its reset.
    ///
    /// Boxes sharing a login spend one allowance, so they count once, at
    /// their highest reading and earliest reset. A reset under a day away
    /// counts as one full day: otherwise a sliver left with an hour to go
    /// would outrank a login with most of its week ahead of it.
    public static func mostSpare(_ readings: [BoxAllowanceReading], now: Date = Date()) -> AllowanceSpare? {
        struct Group {
            let email: String?
            var boxIDs: [Int64]
            var percent: Int
            var resetsAt: Date
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for reading in readings {
            guard let line = reading.lines.first(where: { $0.id == allModelsLineID }),
                  let resetsAt = line.resetsAt, resetsAt > now else { continue }
            let key = reading.accountEmail.map { "login:\($0)" } ?? "box:\(reading.boxID)"
            if var group = groups[key] {
                group.boxIDs.append(reading.boxID)
                group.percent = max(group.percent, line.percent)
                group.resetsAt = min(group.resetsAt, resetsAt)
                groups[key] = group
            } else {
                order.append(key)
                groups[key] = Group(email: reading.accountEmail, boxIDs: [reading.boxID],
                                    percent: line.percent, resetsAt: resetsAt)
            }
        }
        var best: AllowanceSpare?
        var bestRate = 0.0
        for key in order {
            guard let group = groups[key] else { continue }
            let left = max(0, 100 - group.percent)
            let days = max(1, group.resetsAt.timeIntervalSince(now) / 86_400)
            let rate = Double(left) / days
            let beatsBest = rate > bestRate
                || (rate == bestRate && best.map { group.resetsAt < $0.resetsAt } == true)
            guard rate > 0, beatsBest else { continue }
            bestRate = rate
            best = AllowanceSpare(accountEmail: group.email, boxIDs: group.boxIDs, percentLeft: left,
                                  percentPerDay: Int(rate.rounded()), resetsAt: group.resetsAt)
        }
        return best
    }

    /// "4 min ago", "2 h ago", "3 d ago", or "just now" under a minute.
    public static func ageText(since date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    /// "Claude · Opus · high" for a box's default agent, model and effort.
    /// A bare alias is capitalised; a full model id is left as it is.
    public static func defaultsText(agent: String, model: String?, effort: String?) -> String {
        let agentName = agent == "codex" ? "Codex" : agent == "claude" ? "Claude" : agent
        let modelName: String
        if let model, !model.isEmpty {
            let isAlias = model.allSatisfy(\.isLetter)
            modelName = isAlias ? model.prefix(1).uppercased() + model.dropFirst() : model
        } else {
            modelName = agent == "codex" ? "Codex's own model" : "Claude Code's own model"
        }
        return ([agentName, modelName] + (effort.map { [$0] } ?? [])).joined(separator: " · ")
    }
}

/// Whether a box can be reached, and how.
public enum BoxConnectionState: Equatable, Sendable {
    case online
    /// Disconnected, and the journal can start it again.
    case asleep
    /// Disconnected, with no way to start it from here.
    case offline

    public var title: String {
        switch self {
        case .online: return "Online"
        case .asleep: return "Asleep"
        case .offline: return "Offline"
        }
    }
}
