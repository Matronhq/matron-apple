import Foundation

/// One row of the project page's merged activity feed: a milestone, a
/// decision or answered question, a file, or a question or notice posted
/// for the user — whatever the page already holds, in one newest-first
/// list.
public enum ProjectActivityEvent: Identifiable, Equatable, Hashable, Sendable {
    case milestone(ProjectMilestone)
    case decision(ProjectDecision)
    case file(ProjectFile)
    /// An open question or notice on one of the missions (`ProjectActivity.isFeedItem`).
    case item(TrackerItem)

    public var id: String {
        switch self {
        case .milestone(let m): return "milestone:" + m.id
        case .decision(let d): return "decision:" + d.id
        case .file(let f): return "file:" + f.id
        case .item(let i): return "item:" + i.id
        }
    }

    /// When it happened: a milestone when posted, a decision when recorded
    /// (an answered question when it closed), a file when posted, an item
    /// when filed. A file the journal sent no `posted_at` for sorts last.
    public var at: Date {
        switch self {
        case .milestone(let m): return m.milestone.createdAt
        case .decision(let d): return d.at
        case .file(let f): return f.postedAt ?? .distantPast
        case .item(let i): return i.createdAt
        }
    }

    public var missionNum: Int? {
        switch self {
        case .milestone(let m): return m.missionNum
        case .decision(let d): return d.missionNum
        case .file(let f): return f.missionNum
        case .item(let i): return i.missionNum
        }
    }

    /// Tie-break order at the same instant: what happened, then what was
    /// decided, then what was asked, then what was attached.
    var kindRank: Int {
        switch self {
        case .milestone: return 0
        case .decision: return 1
        case .item: return 2
        case .file: return 3
        }
    }
}

/// The merged feed's rules, pure so every page (iOS, Mac, and the tests)
/// shares them.
public enum ProjectActivity {
    /// Rows shown before the first "Show more".
    public static let firstPageLimit = 12

    /// Whether an open item belongs in the feed: a question or a notice
    /// (something posted for the user to answer or read). Tasks and
    /// decision items stay out — a decision already appears through the
    /// decisions roll-up, and tasks doubled up with the milestones that
    /// report them.
    public static func isFeedItem(_ item: TrackerItem) -> Bool {
        item.kind == .question || item.kind == .notice
    }

    /// Every event the page holds, newest first. An open question that is
    /// also in Needs you still appears here: the feed says when it was
    /// asked, Needs you that it is still waiting.
    public static func events(_ page: ProjectPageModel) -> [ProjectActivityEvent] {
        var out: [ProjectActivityEvent] = milestones(page).map { .milestone($0) }
        out += page.decisions.rows.map { .decision($0) }
        out += page.files.rows.map { .file($0) }
        out += page.openItems.filter(isFeedItem).map { .item($0) }
        return out.sorted(by: precedes)
    }

    /// The milestones the feed draws on: the roll-up's page, or, from a
    /// journal without the roll-up, the page's latest few.
    static func milestones(_ page: ProjectPageModel) -> [ProjectMilestone] {
        if page.hasFeed { return page.milestonesPage.rows }
        return page.recentMilestones.map { ProjectMilestone(milestone: $0, missionNum: page.missionNums[$0.missionID]) }
    }

    /// Rows added by each "Show more" past the first page, before any
    /// pages are fetched.
    public static let showMoreStep = 24

    /// The instant the feed is complete back to: the newest "oldest loaded
    /// row" among the kinds that still have pages to load. Older rows of
    /// the other kinds are held back until those pages land, so the list
    /// never shows, say, every old decision beside only this week's
    /// milestones and looks like a quiet month. `nil` when every kind is
    /// fully loaded (or empty).
    public static func horizon(_ page: ProjectPageModel) -> Date? {
        var oldest: [Date] = []
        if page.milestonesPage.hasMore, let last = page.milestonesPage.rows.last { oldest.append(last.milestone.createdAt) }
        if page.decisions.hasMore, let last = page.decisions.rows.last { oldest.append(last.at) }
        if page.files.hasMore, let last = page.files.rows.last?.postedAt { oldest.append(last) }
        return oldest.max()
    }

    /// The events at or after `horizon` (all of them when there is none).
    public static func visible(_ events: [ProjectActivityEvent], horizon: Date?) -> [ProjectActivityEvent] {
        guard let horizon else { return events }
        return events.filter { $0.at >= horizon }
    }

    /// The feed as the page shows it: the visible events, cut to `limit`
    /// when there is one.
    public static func rows(_ page: ProjectPageModel, limit: Int?) -> [ProjectActivityEvent] {
        let shown = visible(events(page), horizon: horizon(page))
        guard let limit else { return shown }
        return Array(shown.prefix(limit))
    }

    /// Whether "Show more" has anything to do: events held back by the
    /// fold or the horizon, or pages still to load.
    public static func hasMore(_ page: ProjectPageModel, limit: Int?) -> Bool {
        let all = events(page)
        let shown = rows(page, limit: limit)
        return shown.count < all.count || kindsWithMore(page).isEmpty == false
    }

    /// The kinds "Show more" fetches another page of: every kind with a
    /// cursor left. (The horizon only ever moves when the kind that sets
    /// it loads, and which kind that is changes as pages land, so loading
    /// them together is the simple rule.)
    public static func kindsWithMore(_ page: ProjectPageModel) -> [ProjectFeedKind] {
        var kinds: [ProjectFeedKind] = []
        if page.milestonesPage.hasMore { kinds.append(.milestones) }
        if page.decisions.hasMore { kinds.append(.decisions) }
        if page.files.hasMore { kinds.append(.files) }
        return kinds
    }

    /// Newest first; at the same instant by kind, then by id.
    static func precedes(_ a: ProjectActivityEvent, _ b: ProjectActivityEvent) -> Bool {
        if a.at != b.at { return a.at > b.at }
        if a.kindRank != b.kindRank { return a.kindRank < b.kindRank }
        return a.id < b.id
    }

    /// The events grouped by calendar day in their own (newest-first)
    /// order: one group per run of rows on the same day.
    public static func days(_ events: [ProjectActivityEvent], calendar: Calendar = .current) -> [ProjectActivityDay] {
        var days: [ProjectActivityDay] = []
        for event in events {
            let start = calendar.startOfDay(for: event.at)
            if let last = days.last, last.start == start {
                days[days.count - 1].events.append(event)
            } else {
                days.append(ProjectActivityDay(start: start, events: [event]))
            }
        }
        return days
    }
}

/// One day of the merged feed.
public struct ProjectActivityDay: Identifiable, Equatable, Sendable {
    /// The day's first instant, in the grouping calendar.
    public let start: Date
    public var events: [ProjectActivityEvent]
    public var id: Date { start }
    public init(start: Date, events: [ProjectActivityEvent]) { self.start = start; self.events = events }
}
