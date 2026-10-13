import SwiftUI
import MatronModels

/// The project page's words for its merged "Latest" feed and its pulse
/// line, pure so each is a plain test and the iOS and Mac pages say them
/// the same way.
public enum ProjectActivityFormat {
    public static let heading = "Latest"
    public static let showMore = "Show more"
    public static let empty = "Nothing has happened on this project yet."

    /// The row's main line.
    public static func title(_ event: ProjectActivityEvent) -> String {
        switch event {
        case .milestone(let m): return m.milestone.title
        case .decision(let d): return d.title
        case .file(let f): return ProjectFeedFormat.fileName(f)
        case .item(let i): return i.title
        }
    }

    /// The line under the title that says what kind of thing it is: a
    /// question's answer, "Decision" / "Decision reversed", "Your input"
    /// on your own milestones, where a file was posted, who a question or
    /// notice waits on. Nil for an ordinary milestone, the common row.
    public static func note(_ event: ProjectActivityEvent) -> String? {
        switch event {
        case .milestone(let m):
            return m.milestone.kind == .userInput ? "Your input" : nil
        case .decision(let d):
            if d.kind == .question {
                let answer = d.answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return answer.isEmpty ? "Answered" : "Answered: “\(ProjectsFormat.oneLine(answer))”"
            }
            return d.resolution == .reversed ? "Decision reversed" : "Decision"
        case .file(let f):
            let what = f.isImage ? "Image" : "File"
            switch f.source {
            case .item(let num): return "\(what) on #\(num)"
            case .chat: return "\(what) in chat"
            }
        case .item(let i):
            switch (i.kind, i.awaiting) {
            case (.question, .user): return "Question for you"
            case (.question, _): return "Question"
            case (.notice, .user): return "For you to read"
            case (.notice, _): return "Notice"
            default: return ItemGlyph.label(i.kind)
            }
        }
    }

    /// "09:54": the row's time within its day.
    public static func time(_ event: ProjectActivityEvent, timeZone: TimeZone = .current) -> String {
        ProjectFeedFormat.timeOfDay(event.at, timeZone: timeZone)
    }

    /// What VoiceOver reads for a row: the kind, the title, the mission.
    public static func accessibilityLabel(_ event: ProjectActivityEvent) -> String {
        var parts = [kindLabel(event), title(event)]
        if let note = note(event), !note.hasPrefix("Answered") { parts.append(note) }
        if let num = event.missionNum { parts.append("mission \(num)") }
        return parts.joined(separator: ", ")
    }

    static func kindLabel(_ event: ProjectActivityEvent) -> String {
        switch event {
        case .milestone(let m): return MissionGlyph.label(m.milestone.kind)
        case .decision(let d): return ProjectDecisionMark(d).label
        case .file(let f): return f.isImage ? "Image" : "File"
        case .item(let i): return ItemGlyph.label(i.kind)
        }
    }

    /// The feed's rows grouped by day, newest first, each day labelled
    /// "Today", "Yesterday", else "26 Sep".
    public static func sections(_ events: [ProjectActivityEvent], now: Date,
                                calendar: Calendar = .current) -> [ProjectActivitySection] {
        ProjectActivity.days(events, calendar: calendar).map { day in
            ProjectActivitySection(start: day.start,
                                   label: ProjectFeedFormat.dayLabel(day.start, now: now, calendar: calendar),
                                   events: day.events)
        }
    }

    // MARK: Pulse line

    /// "2 running · 1 waiting · 1 idle · 1 closed": the mission counts
    /// that are not zero, each with its dot. Empty for a project with no
    /// missions at all.
    public static func missionParts(_ counts: ProjectMissionCounts) -> [ProjectPulsePart] {
        var parts: [ProjectPulsePart] = []
        func add(_ activity: MissionActivity?, _ n: Int, _ word: String) {
            if n > 0 { parts.append(ProjectPulsePart(activity: activity, text: "\(n) \(word)")) }
        }
        add(.running, counts.running, "running")
        add(.waiting, counts.waiting, "waiting")
        add(.idle, counts.idle, "idle")
        add(.quiet, counts.quiet, "quiet")
        add(nil, counts.closed, "closed")
        return parts
    }

    /// "4 sessions on 3 boxes · last activity 4m ago": the sessions counted
    /// as "Sessions on it now" counts them, "no sessions on it now" when
    /// there are none; the activity clause drops when unknown.
    public static func sessionsLine(_ page: ProjectPageModel, now: Date) -> String {
        let rows = ProjectPageSections.sessionRows(page)
        let counts = ProjectPageSections.boxCounts(rows, fallback: page.sessionsByBox)
        let sessions = rows.isEmpty ? counts.reduce(0) { $0 + $1.count } : rows.count
        var parts: [String] = []
        if sessions == 0 {
            parts.append("no sessions on it now")
        } else if counts.count > 0 {
            parts.append("\(ProjectFeedFormat.plural(sessions, "session")) on \(ProjectFeedFormat.plural(counts.count, "box", "boxes"))")
        } else {
            parts.append("\(ProjectFeedFormat.plural(sessions, "session")) on it now")
        }
        if let last = page.project.lastActivityAt {
            parts.append("last activity \(MissionsDashboardFormat.relative(last, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Headline

    /// The headline card's caption: "STATUS · 11m ago" over the status,
    /// "ABOUT" over the description when there is no status.
    public static func headlineCaption(_ project: Project, now: Date) -> String {
        project.status == nil ? "ABOUT" : ProjectsFormat.statusHeading(updatedAt: project.statusUpdatedAt, now: now)
    }

    /// The headline's text: the status, else the description, else a
    /// line saying there is neither.
    public static func headlineText(_ project: Project) -> String {
        if let status = project.status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return status }
        if !project.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return project.body }
        return "No written status yet"
    }

    /// Whether the description gets its own "About this project" fold:
    /// only when the headline shows the status instead of it.
    public static func showsAboutFold(_ project: Project) -> Bool {
        project.status != nil && !project.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One day of the feed, labelled.
public struct ProjectActivitySection: Identifiable, Equatable, Sendable {
    public let start: Date
    public let label: String
    public let events: [ProjectActivityEvent]
    public var id: Date { start }
    public init(start: Date, label: String, events: [ProjectActivityEvent]) {
        self.start = start; self.label = label; self.events = events
    }
}

/// One clause of the pulse line's mission counts: "2 running" with the
/// running dot; `activity` nil for the closed count.
public struct ProjectPulsePart: Equatable, Sendable, Identifiable {
    public let activity: MissionActivity?
    public let text: String
    public var id: String { text }
    public init(activity: MissionActivity?, text: String) { self.activity = activity; self.text = text }

    public var tint: Color { MissionActivityDot.color(activity ?? .idle, isClosed: activity == nil) }
}

/// The reference sections folded at the foot of the page, in page order.
public enum ProjectReferenceSection: String, CaseIterable, Sendable, Identifiable {
    case decisions, files, sessions, otherItems, about
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .decisions: return "Decisions"
        case .files: return "Files and images"
        case .sessions: return "Sessions on it now"
        case .otherItems: return "Other open items"
        case .about: return "About this project"
        }
    }

    public var symbol: String {
        switch self {
        case .decisions: return "scalemass.fill"
        case .files: return "photo.on.rectangle"
        case .sessions: return "person.2"
        case .otherItems: return "checklist"
        case .about: return "text.alignleft"
        }
    }

    /// The count beside the title; nil for About.
    public func detail(_ page: ProjectPageModel) -> String? {
        switch self {
        case .decisions: return ProjectFeedFormat.feedCount(page.decisions)
        case .files: return "\(page.files.total)"
        case .sessions:
            let rows = ProjectPageSections.sessionRows(page)
            let counts = ProjectPageSections.boxCounts(rows, fallback: page.sessionsByBox)
            return "\(rows.isEmpty ? counts.reduce(0) { $0 + $1.count } : rows.count)"
        case .otherItems: return "\(ProjectPageSections.otherOpenItemCount(page))"
        case .about: return nil
        }
    }

    /// Whether the page has anything to fold under this heading.
    public func isShown(_ page: ProjectPageModel) -> Bool {
        switch self {
        case .decisions: return !page.decisions.rows.isEmpty
        case .files: return !page.files.rows.isEmpty
        case .sessions:
            let rows = ProjectPageSections.sessionRows(page)
            return ProjectPageSections.showsSessionsCard(rows: rows, counts: ProjectPageSections.boxCounts(rows, fallback: page.sessionsByBox))
        case .otherItems: return ProjectPageSections.otherOpenItemCount(page) > 0
        case .about: return ProjectActivityFormat.showsAboutFold(page.project)
        }
    }
}
