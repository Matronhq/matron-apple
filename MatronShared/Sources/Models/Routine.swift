import Foundation

/// What a triggered routine fires on instead of a clock (journal
/// "Coordinator routines → Triggers"). Each subject — a session or a box —
/// fires once per crossing.
public enum RoutineTrigger: Equatable, Hashable, Sendable {
    /// A live session's context gauge at or past `pct` (1–99) of its window.
    case contextOver(pct: Int)
    /// A session stalled on a usage limit whose reset is at least
    /// `resetMinutes` (0–10080) away, or unknown.
    case stalled(resetMinutes: Int)
    /// An agent box with under `pct` (1–99) percent free disk.
    case diskUnder(pct: Int)
    /// A weekly limit that resets between `fromHours` and `toHours` from
    /// now with under `pct` (1–99) percent used: allowance that would
    /// otherwise go to waste. The window is the journal's (default 6–12 h);
    /// it is kept exactly as received, `nil` when the journal sent none, so
    /// an edit of the percent sends it back unchanged.
    case allowanceExpiring(pct: Int, fromHours: Double? = nil, toHours: Double? = nil)

    /// The journal's reset window when a trigger names none.
    public static let defaultAllowanceWindow: (from: Double, to: Double) = (6, 12)

    public enum Kind: String, CaseIterable, Sendable {
        case contextOver = "context_over"
        case stalled
        case diskUnder = "disk_under"
        case allowanceExpiring = "allowance_expiring"

        public var label: String {
            switch self {
            case .contextOver: return "Session context"
            case .stalled: return "Stalled session"
            case .diskUnder: return "Low disk"
            case .allowanceExpiring: return "Spare weekly allowance"
            }
        }

        /// The value a new trigger of this kind starts with: the starter
        /// routines' thresholds.
        public var defaultTrigger: RoutineTrigger {
            switch self {
            case .contextOver: return .contextOver(pct: 40)
            case .stalled: return .stalled(resetMinutes: 120)
            case .diskUnder: return .diskUnder(pct: 20)
            case .allowanceExpiring: return .allowanceExpiring(pct: 70)
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .contextOver: return .contextOver
        case .stalled: return .stalled
        case .diskUnder: return .diskUnder
        case .allowanceExpiring: return .allowanceExpiring
        }
    }

    /// The trigger's one number: a percentage, or minutes for `stalled`.
    public var threshold: Int {
        switch self {
        case .contextOver(let pct), .diskUnder(let pct), .allowanceExpiring(let pct, _, _): return pct
        case .stalled(let minutes): return minutes
        }
    }

    public static func make(kind: Kind, threshold: Int) -> RoutineTrigger {
        switch kind {
        case .contextOver: return .contextOver(pct: threshold)
        case .stalled: return .stalled(resetMinutes: threshold)
        case .diskUnder: return .diskUnder(pct: threshold)
        case .allowanceExpiring: return .allowanceExpiring(pct: threshold)
        }
    }

    /// The journal's ranges (`validateTrigger`).
    public static func thresholdRange(for kind: Kind) -> ClosedRange<Int> {
        kind == .stalled ? 0...RoutineRules.stalledMaxMinutes : 1...99
    }

    public init?(json: [String: Any]) {
        guard let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        switch kind {
        case .stalled:
            let minutes = (json["reset_minutes"] as? NSNumber)?.intValue ?? 120
            self = .stalled(resetMinutes: minutes)
        case .contextOver, .diskUnder:
            guard let pct = (json["pct"] as? NSNumber)?.intValue else { return nil }
            self = .make(kind: kind, threshold: pct)
        case .allowanceExpiring:
            guard let pct = (json["pct"] as? NSNumber)?.intValue else { return nil }
            self = .allowanceExpiring(pct: pct, fromHours: (json["from_hours"] as? NSNumber)?.doubleValue,
                                      toHours: (json["to_hours"] as? NSNumber)?.doubleValue)
        }
    }

    public var json: [String: Any] {
        switch self {
        case .contextOver(let pct): return ["kind": Kind.contextOver.rawValue, "pct": pct]
        case .stalled(let minutes): return ["kind": Kind.stalled.rawValue, "reset_minutes": minutes]
        case .diskUnder(let pct): return ["kind": Kind.diskUnder.rawValue, "pct": pct]
        case .allowanceExpiring(let pct, let from, let to):
            // The window goes back only as the journal sent it.
            var out: [String: Any] = ["kind": Kind.allowanceExpiring.rawValue, "pct": pct]
            if let from { out["from_hours"] = from }
            if let to { out["to_hours"] = to }
            return out
        }
    }

    /// "When a session passes 40% of its context window", "When a session
    /// stalls on a usage limit with no reset within 2 h", "When a box drops
    /// under 20% free disk", "When a weekly limit resets within 6–12 h and
    /// is under 70%".
    public var words: String {
        switch self {
        case .contextOver(let pct):
            return "When a session passes \(pct)% of its context window"
        case .stalled(let minutes):
            guard minutes > 0 else { return "When a session stalls on a usage limit" }
            return "When a session stalls on a usage limit with no reset within \(Self.duration(minutes))"
        case .diskUnder(let pct):
            return "When a box drops under \(pct)% free disk"
        case .allowanceExpiring(let pct, let from, let to):
            let window = Self.defaultAllowanceWindow
            return "When a weekly limit resets within \(Self.hours(from ?? window.from))–\(Self.hours(to ?? window.to)) h and is under \(pct)%"
        }
    }

    /// 6 → "6", 1.5 → "1.5".
    static func hours(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    /// "45 min", "2 h", "1 h 30 min", "3 d".
    public static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) d" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// One Coordinator routine (journal `GET /routines`): a prompt the journal
/// fires into the Coordinator conversation on a schedule or when a trigger
/// trips. Scheduled or triggered for life: exactly one of `schedule` and
/// `trigger` is set, and an edit can never swap one for the other.
public struct Routine: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    /// Slug, unique per user, not editable.
    public let name: String
    public let title: String
    /// Five cron fields, evaluated in `tz`. `nil` for a triggered routine.
    public let schedule: String?
    public let trigger: RoutineTrigger?
    public let tz: String
    public let prompt: String
    public let enabled: Bool
    /// `seed`, `user` or `agent`.
    public let origin: String
    /// The next scheduled fire; `nil` while paused, and always for a
    /// triggered routine.
    public let nextAt: Date?
    public let lastFiredAt: Date?
    /// `applied now`, `applied deferred`, `failed <code>`, `no_coordinator`
    /// or `missed`.
    public let lastOutcome: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, name: String, title: String, schedule: String? = nil, trigger: RoutineTrigger? = nil,
                tz: String = RoutineRules.defaultZone, prompt: String, enabled: Bool = true, origin: String = "user",
                nextAt: Date? = nil, lastFiredAt: Date? = nil, lastOutcome: String? = nil,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.title = title; self.schedule = schedule; self.trigger = trigger
        self.tz = tz; self.prompt = prompt; self.enabled = enabled; self.origin = origin
        self.nextAt = nextAt; self.lastFiredAt = lastFiredAt; self.lastOutcome = lastOutcome
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    /// `nil` when a field the list needs is missing, or when the row has
    /// neither a schedule nor a trigger this build understands — the caller
    /// drops it rather than guessing.
    public init?(json: [String: Any]) {
        func date(_ key: String) -> Date? {
            (json[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        guard let id = json["id"] as? String, !id.isEmpty,
              let name = json["name"] as? String, !name.isEmpty,
              let title = json["title"] as? String,
              let prompt = json["prompt"] as? String,
              let createdAt = date("created_at"), let updatedAt = date("updated_at")
        else { return nil }
        let schedule = (json["schedule"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let trigger = (json["trigger"] as? [String: Any]).flatMap(RoutineTrigger.init(json:))
        guard (schedule == nil) != (trigger == nil) else { return nil }
        self.init(id: id, name: name, title: title, schedule: schedule, trigger: trigger,
                  tz: json["tz"] as? String ?? RoutineRules.defaultZone, prompt: prompt,
                  enabled: (json["enabled"] as? NSNumber)?.boolValue ?? true,
                  origin: json["origin"] as? String ?? "user",
                  nextAt: date("next_at"), lastFiredAt: date("last_fired_at"),
                  lastOutcome: json["last_outcome"] as? String,
                  createdAt: createdAt, updatedAt: updatedAt)
    }

    public var isTriggered: Bool { trigger != nil }

    /// What sets it off, in words: "Every day at 07:05 (Europe/London)", or
    /// the trigger's sentence.
    public var whenWords: String {
        if let trigger { return trigger.words }
        guard let schedule else { return "" }
        return "\(CronWords.describe(schedule) ?? "Cron \(schedule)") (\(tz))"
    }

    /// The last fire's outcome for the list: "Delivered", "Queued for the
    /// next idle point", "Missed", "Not delivered: no Coordinator box",
    /// "Failed: agent_unreachable".
    public var lastOutcomeWords: String? {
        guard let outcome = lastOutcome?.trimmingCharacters(in: .whitespaces), !outcome.isEmpty else { return nil }
        switch outcome {
        case "applied now": return "Delivered"
        case "applied deferred": return "Queued for the next idle point"
        case "missed": return "Missed"
        case "no_coordinator": return "Not delivered: no Coordinator box"
        default:
            if outcome.hasPrefix("failed") {
                let code = outcome.dropFirst("failed".count).trimmingCharacters(in: .whitespaces)
                return code.isEmpty ? "Failed" : "Failed: \(code)"
            }
            return outcome
        }
    }

    /// Whether the last fire did not reach the Coordinator.
    public var lastFireFailed: Bool {
        guard let outcome = lastOutcome else { return false }
        return outcome == "missed" || outcome == "no_coordinator" || outcome.hasPrefix("failed")
    }
}

/// The fields a create or edit sends. On an edit, `nil` leaves a field
/// alone; `schedule` and `trigger` go only to the kind the routine already
/// is.
public struct RoutineDraft: Equatable, Sendable {
    public var title: String
    public var prompt: String
    public var tz: String
    public var schedule: String?
    public var trigger: RoutineTrigger?
    public var enabled: Bool?

    public init(title: String, prompt: String, tz: String, schedule: String? = nil,
                trigger: RoutineTrigger? = nil, enabled: Bool? = nil) {
        self.title = title; self.prompt = prompt; self.tz = tz
        self.schedule = schedule; self.trigger = trigger; self.enabled = enabled
    }

    /// The request body. A triggered routine sends no zone: it has no clock.
    public var requestBody: [String: Any] {
        var out: [String: Any] = [
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let schedule {
            out["schedule"] = schedule.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            out["tz"] = tz
        }
        if let trigger { out["trigger"] = trigger.json }
        if let enabled { out["enabled"] = enabled }
        return out
    }
}

/// The journal's routine rules (`src/routines.js`), restated so the editor
/// refuses a bad value with a reason before any request goes out. The
/// journal answers a bare 400 for every one of them.
public enum RoutineRules {
    public static let maxRoutines = 50
    public static let titleMaxLength = 200
    public static let promptMaxLength = 2000
    public static let stalledMaxMinutes = 7 * 24 * 60
    public static let defaultZone = "Europe/London"
    /// Consecutive fires at least this far apart.
    public static let minGapMinutes = 15

    public static func isValidName(_ name: String) -> Bool {
        guard name.count <= 64, let first = name.unicodeScalars.first else { return false }
        func ok(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("0"..."9").contains(c) }
        return ok(first) && name.unicodeScalars.allSatisfy { ok($0) || $0 == "-" }
    }

    public static func isValidZone(_ tz: String) -> Bool {
        !tz.isEmpty && tz.count <= 64 && TimeZone(identifier: tz) != nil
    }

    /// Why this schedule can't be sent, or `nil`. Checks the shape and the
    /// cases where every minute field fires too often; the journal checks
    /// the real spacing over the next five fires.
    public static func scheduleError(_ schedule: String) -> String? {
        let fields = schedule.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5 else {
            return "A schedule is five cron fields: minute, hour, day of month, month and day of week."
        }
        let minute = String(fields[0])
        let tooOften: Bool
        if minute == "*" {
            tooOften = true
        } else if minute.hasPrefix("*/"), let step = Int(minute.dropFirst(2)) {
            tooOften = step < minGapMinutes
        } else {
            tooOften = false
        }
        if tooOften { return "A routine fires at most every \(minGapMinutes) minutes." }
        return nil
    }

    /// Why this form can't be saved, or `nil`.
    public static func formError(name: String, title: String, prompt: String, tz: String,
                                 schedule: String?, trigger: RoutineTrigger?) -> String? {
        if !isValidName(name) {
            return "The name must be lowercase letters, digits and dashes, start with a letter or digit, and be at most 64 characters."
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return "Give the routine a title." }
        if trimmedTitle.count > titleMaxLength { return "The title can be at most \(titleMaxLength) characters." }
        if trimmedTitle.contains(where: \.isNewline) { return "The title must be one line." }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty { return "Write the prompt the Coordinator receives." }
        if trimmedPrompt.count > promptMaxLength { return "The prompt can be at most \(promptMaxLength) characters." }
        if let schedule {
            if !isValidZone(tz) { return "\"\(tz)\" is not a time zone. Use a name such as Europe/London." }
            if let problem = scheduleError(schedule) { return problem }
        }
        if let trigger {
            let range = RoutineTrigger.thresholdRange(for: trigger.kind)
            if !range.contains(trigger.threshold) {
                return trigger.kind == .stalled
                    ? "The reset window is 0 to \(range.upperBound) minutes."
                    : "The threshold is a percentage from \(range.lowerBound) to \(range.upperBound)."
            }
        }
        return nil
    }
}

/// Plain words for the five-field cron the journal fires routines on —
/// enough for the shapes people write ("5 7 * * *", "0 */2 * * *",
/// "30 18 * * 1-5"). `nil` for anything it can't say plainly; the caller
/// shows the raw fields instead.
public enum CronWords {
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December"]

    public static func describe(_ schedule: String) -> String? {
        let f = schedule.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5 else { return nil }
        let (minute, hour, dom, month, dow) = (f[0], f[1], f[2], f[3], f[4])

        guard let time = timeWords(minute: minute, hour: hour) else { return nil }
        var days: String
        if dom == "*" && dow == "*" {
            days = "Every day"
        } else if dom == "*" {
            guard let d = weekdayWords(dow) else { return nil }
            days = d
        } else if dow == "*" {
            guard let d = numberList(dom, range: 1...31) else { return nil }
            days = "On day \(join(d.map(String.init))) of the month"
        } else {
            return nil
        }
        if month != "*" {
            guard let m = numberList(month, range: 1...12) else { return nil }
            days += " in " + join(m.map { monthNames[$0 - 1] })
        }
        // "Every 2 hours, every day" reads badly: drop "every day" there.
        if days == "Every day" && time.isInterval { return time.text.prefix(1).uppercased() + time.text.dropFirst() }
        return "\(days) \(time.text)"
    }

    private static func timeWords(minute: String, hour: String) -> (text: String, isInterval: Bool)? {
        if minute.hasPrefix("*/"), hour == "*", let step = Int(minute.dropFirst(2)), step > 0 {
            return ("every \(step) minutes", true)
        }
        guard let minutes = numberList(minute, range: 0...59) else { return nil }
        if hour == "*" {
            guard minutes.count == 1 else { return nil }
            return (minutes[0] == 0 ? "every hour, on the hour" : "every hour at \(minutes[0]) past", true)
        }
        if hour.hasPrefix("*/"), let step = Int(hour.dropFirst(2)), step > 0, minutes.count == 1 {
            let at = minutes[0] == 0 ? "on the hour" : "at \(minutes[0]) past"
            return (step == 1 ? "every hour, \(at)" : "every \(step) hours, \(at)", true)
        }
        guard let hours = numberList(hour, range: 0...23) else { return nil }
        let times = hours.flatMap { h in minutes.map { m in String(format: "%02d:%02d", h, m) } }
        guard times.count <= 6 else { return nil }
        return ("at " + join(times), false)
    }

    private static func weekdayWords(_ field: String) -> String? {
        if field == "1-5" { return "Monday to Friday" }
        if field == "0,6" || field == "6,0" || field == "6-7" { return "Saturday and Sunday" }
        let r = field.split(separator: "-", omittingEmptySubsequences: false)
        if r.count == 2, let a = Int(r[0]), let b = Int(r[1]), (0...7).contains(a), (0...7).contains(b), a < b {
            return "\(dayNames[a % 7]) to \(dayNames[b % 7])"
        }
        guard let days = numberList(field, range: 0...7) else { return nil }
        return "Every " + join(days.map { dayNames[$0 % 7] })
    }

    /// "5", "8,17", "1-3", "8,12-14" → the sorted numbers; `nil` for steps,
    /// names or anything out of range.
    private static func numberList(_ field: String, range: ClosedRange<Int>) -> [Int]? {
        var out: [Int] = []
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 1, let n = Int(bounds[0]), range.contains(n) {
                out.append(n)
            } else if bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]),
                      range.contains(a), range.contains(b), a <= b, b - a < 24 {
                out.append(contentsOf: a...b)
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : Array(Set(out)).sorted()
    }

    private static func join(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}
