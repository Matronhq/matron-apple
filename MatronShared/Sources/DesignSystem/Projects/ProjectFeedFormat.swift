import SwiftUI
import MatronModels

/// Projects view v2's words (the card's waiting line and footer, the page's
/// meta line and roll-up headings, the milestone days), pure so each is a
/// plain test and the Mac and iOS pages say it the same way.
public enum ProjectFeedFormat {
    // MARK: Card

    /// The card's description: the Coordinator's status, else the goal;
    /// nil when both are empty (the host falls back to the "No written
    /// status yet" line).
    public static func cardDescription(_ project: Project) -> String? {
        for text in [project.status, project.body] {
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// "Waiting on you: send Harrier the manifesting email".
    public static func waitingText(_ waiting: ProjectWaitingOn) -> String {
        "Waiting on you: \(ProjectsFormat.oneLine(waiting.title))"
    }

    /// The waiting box's right-hand note: "#3432 · +3 more", or "#5882"
    /// when it is the only one.
    public static func waitingTrailing(_ waiting: ProjectWaitingOn) -> String {
        waiting.more > 0 ? "#\(waiting.num) · +\(waiting.more) more" : "#\(waiting.num)"
    }

    /// "2 missions · 14 sessions on it now"; "1 mission" when nobody is on
    /// it.
    public static func cardFooter(openMissions: Int, sessionsNow: Int) -> String {
        var parts = [plural(openMissions, "mission")]
        if sessionsNow > 0 { parts.append("\(plural(sessionsNow, "session")) on it now") }
        return parts.joined(separator: " · ")
    }

    // MARK: Page

    /// The header's meta line: "5 missions · 9 sessions on 7 boxes · last
    /// activity 3h ago". The boxes drop when none is named (a single-box
    /// journal never tags its sessions), the sessions when there are none,
    /// the activity when it is unknown.
    public static func pageMetaLine(openMissions: Int, sessions: Int, boxes: Int, lastActivityAt: Date?,
                                    now: Date) -> String {
        var parts = [plural(openMissions, "mission")]
        if sessions > 0 {
            parts.append(boxes > 0 ? "\(plural(sessions, "session")) on \(plural(boxes, "box", "boxes"))"
                                   : plural(sessions, "session"))
        }
        if let lastActivityAt { parts.append("last activity \(MissionsDashboardFormat.relative(lastActivityAt, now: now))") }
        return parts.joined(separator: " · ")
    }

    /// `pageMetaLine` from the page: its sessions and boxes counted the way
    /// "Sessions on it now" counts them — the live rows once the missions'
    /// sessions have loaded, the journal's `sessions_by_box` until then.
    public static func pageMetaLine(_ page: ProjectPageModel, now: Date) -> String {
        let rows = ProjectPageSections.sessionRows(page)
        let counts = ProjectPageSections.boxCounts(rows, fallback: page.sessionsByBox)
        let sessions = rows.isEmpty ? counts.reduce(0) { $0 + $1.count } : rows.count
        return pageMetaLine(openMissions: page.missions.count, sessions: sessions, boxes: counts.count,
                            lastActivityAt: page.project.lastActivityAt, now: now)
    }

    public static func feedCount(_ page: ProjectFeedPage<ProjectDecision>) -> String {
        feedCount(total: page.total, missionNums: page.rows.map(\.missionNum), complete: !page.hasMore)
    }

    public static func feedCount(_ page: ProjectFeedPage<ProjectMilestone>) -> String {
        feedCount(total: page.total, missionNums: page.rows.map(\.missionNum), complete: !page.hasMore)
    }

    /// A roll-up heading's count: "23 across 4 missions". `missionNums` are
    /// the loaded rows' missions; while more pages wait (`complete` false)
    /// the rows seen so far are a lower bound, so it says "4+ missions".
    /// Bare "23" when no row names its mission.
    public static func feedCount(total: Int, missionNums: [Int?], complete: Bool) -> String {
        let missions = Set(missionNums.compactMap { $0 }).count
        guard missions > 0 else { return "\(total)" }
        if complete { return "\(total) across \(plural(missions, "mission"))" }
        return "\(total) across \(missions)+ missions"
    }

    // MARK: Days

    /// "Today", "Yesterday", else "26 Sep" — a milestone group's heading
    /// and a decision row's date.
    public static func dayLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return ProjectsFormat.shortDate(date, timeZone: calendar.timeZone)
    }

    /// "09:54", a milestone row's time within its day.
    public static func timeOfDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// The milestones grouped by calendar day in their own (newest-first)
    /// order: one group per run of rows on the same day.
    public static func milestoneDays(_ rows: [ProjectMilestone], now: Date,
                                     calendar: Calendar = .current) -> [ProjectMilestoneDay] {
        var days: [ProjectMilestoneDay] = []
        for row in rows {
            let start = calendar.startOfDay(for: row.milestone.createdAt)
            if let last = days.last, last.start == start {
                days[days.count - 1].rows.append(row)
            } else {
                days.append(ProjectMilestoneDay(start: start, label: dayLabel(row.milestone.createdAt, now: now,
                                                                              calendar: calendar), rows: [row]))
            }
        }
        return days
    }

    // MARK: Files

    /// A file tile's caption under its name: "#5008 · 1d", "chat · 5d";
    /// no age when the journal sent no `posted_at`.
    public static func fileMeta(_ file: ProjectFile, now: Date) -> String {
        let source: String
        switch file.source {
        case .item(let num): source = "#\(num)"
        case .chat: source = "chat"
        }
        guard let posted = file.postedAt else { return source }
        return "\(source) · \(MissionBoard.ago(posted, now: now))"
    }

    /// A file's name, falling back to its caption, then its kind.
    public static func fileName(_ file: ProjectFile) -> String {
        if let name = file.name, !name.isEmpty { return name }
        if let caption = file.caption, !caption.isEmpty { return ProjectsFormat.oneLine(caption) }
        return file.isImage ? "Image" : "File"
    }

    /// The document tile's label: the name's extension ("PDF"), else the
    /// content type's subtype ("ZIP"), else "FILE". At most 4 characters.
    public static func fileExtension(_ file: ProjectFile) -> String {
        let fromName = (file.name as NSString?)?.pathExtension ?? ""
        let fromType = file.contentType?.split(separator: "/").last.map(String.init) ?? ""
        let raw = !fromName.isEmpty ? fromName : fromType
        guard !raw.isEmpty, raw.count <= 4, raw.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "FILE" }
        return raw.uppercased()
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }
}

/// One day of the page's milestones.
public struct ProjectMilestoneDay: Identifiable, Equatable, Sendable {
    /// The day's first instant, in the grouping calendar.
    public let start: Date
    /// "Today", "Yesterday", "26 Sep".
    public let label: String
    public var rows: [ProjectMilestone]
    public var id: Date { start }
}

/// A decision row's glyph: a green check for a decision in force or
/// decided, a grey check (and the title struck through) for one reversed,
/// a blue "?" for an answered question.
public enum ProjectDecisionMark: Equatable, Sendable {
    case decided, reversed, answered

    public init(_ decision: ProjectDecision) {
        if decision.kind == .question { self = .answered; return }
        self = decision.resolution == .reversed ? .reversed : .decided
    }

    public var symbol: String {
        switch self {
        case .decided: return "checkmark.circle.fill"
        case .reversed: return "checkmark.circle"
        case .answered: return "questionmark.circle.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .decided: return .green
        case .reversed: return .secondary
        case .answered: return .blue
        }
    }

    /// The reversed decision's title is struck through and greyed.
    public var isStruck: Bool { self == .reversed }

    public var label: String {
        switch self {
        case .decided: return "Decision"
        case .reversed: return "Reversed decision"
        case .answered: return "Answered question"
        }
    }
}
