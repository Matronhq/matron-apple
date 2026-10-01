import Foundation

// Value types for the Projects home and project page (spec 2026-09-30 §2,
// §6). Built by `ProjectsHomeAssembly` / `ProjectDetailViewModel`
// (MatronViewModels), drawn by the Projects views (MatronDesignSystem).

/// One project card: title, needs-you, one status paragraph, the state
/// bar and counts. No sessions, milestones or item rows (spec §2).
public struct ProjectCard: Identifiable, Equatable, Hashable, Sendable {
    public let project: Project
    /// The larger of the server's `needs_you` and the local mission counts.
    public let needsYouCount: Int
    /// Newest milestone across the project's missions — the "No written
    /// status yet — latest: …" line.
    public let latestMilestone: MissionLastMilestone?
    /// Projects view v2 card fields, from the journal's list row: the
    /// newest item awaiting the user (and how many more), the newest
    /// milestone across every mission (closed ones included), and the live
    /// sessions on the open missions. Nil / 0 from an older journal.
    public let waitingOn: ProjectWaitingOn?
    public let latest: ProjectLatest?
    public let sessionsNow: Int
    public var id: String { project.id }
    public init(project: Project, needsYouCount: Int = 0, latestMilestone: MissionLastMilestone? = nil,
                waitingOn: ProjectWaitingOn? = nil, latest: ProjectLatest? = nil, sessionsNow: Int = 0) {
        self.project = project; self.needsYouCount = needsYouCount; self.latestMilestone = latestMilestone
        self.waitingOn = waitingOn; self.latest = latest; self.sessionsNow = sessionsNow
    }
}

/// One slim mission row: dot · #num · title · one-line status · needs-you · age.
public struct MissionRowModel: Identifiable, Equatable, Hashable, Sendable {
    public let mission: Mission
    public let activity: MissionActivity
    public let needsYouCount: Int
    public let lastActivity: Date
    public var id: String { mission.id }
    public init(mission: Mission, activity: MissionActivity, needsYouCount: Int = 0, lastActivity: Date) {
        self.mission = mission; self.activity = activity; self.needsYouCount = needsYouCount
        self.lastActivity = lastActivity
    }
    /// A closed mission's row (the Closed fold): grey dot, closing time.
    public init(closed mission: Mission) {
        self.init(mission: mission, activity: .idle, lastActivity: mission.closedAt ?? mission.updatedAt)
    }
}

public struct ProjectsHomeSnapshot: Equatable, Sendable {
    public var cards: [ProjectCard]
    /// Open missions in no (known, open) project, not quiet.
    public var unfiled: [MissionRowModel]
    /// Open unfiled missions quiet for over a week.
    public var quiet: [MissionRowModel]
    public var closed: [Mission]
    /// Newest project status time — "Status refreshed 20m ago".
    public var statusRefreshedAt: Date?
    public init(cards: [ProjectCard] = [], unfiled: [MissionRowModel] = [], quiet: [MissionRowModel] = [],
                closed: [Mission] = [], statusRefreshedAt: Date? = nil) {
        self.cards = cards; self.unfiled = unfiled; self.quiet = quiet; self.closed = closed
        self.statusRefreshedAt = statusRefreshedAt
    }
    public var isEmpty: Bool { cards.isEmpty && unfiled.isEmpty && quiet.isEmpty && closed.isEmpty }
    /// The "Move to project…" choices.
    public var openProjects: [Project] { cards.map(\.project) }
}

/// Every tap on the Projects home, routed through one function per host.
public enum ProjectsHomeAction: Equatable, Hashable, Sendable {
    case openProject(String)
    case openMission(String)
    case newProject
    /// `projectID == nil` takes the mission out of its project.
    case moveMission(missionID: String, projectID: String?)
}

/// Everything the project page draws (spec §2 "Project page").
public struct ProjectPageModel: Equatable, Sendable {
    public var project: Project
    /// Open missions, needs-you first, then activity.
    public var missions: [MissionRowModel]
    public var closedMissions: [Mission]
    public var needsYou: [TrackerItem]
    /// Every open item on the project's missions, Needs you's included —
    /// `ProjectPageSections.otherItems` leaves those out.
    public var openItems: [TrackerItem]
    /// The latest 5 milestones across the project's missions.
    public var recentMilestones: [Milestone]
    /// Mission id → `#num`, for the milestone rows' chips.
    public var missionNums: [String: Int]
    public var sessionsByBox: [String: Int]
    /// Filled by the host from `MissionsDashboardViewModel.sessionsByMission`.
    public var sessionsByMission: [String: [DashboardSession]]
    /// Filled by the host from `MissionsDashboardViewModel.roomCountsByMission`.
    public var roomCountsByMission: [String: Int]
    /// "Merge into…" choices: open projects other than this one, and none
    /// when this project is closed (preflight R5).
    public var mergeTargets: [Project]
    /// A row's "Move to project…" choices: every open project (this one
    /// ticked when open). Offered even on a closed project, because the
    /// journal refuses only a closed *target*, so a mission can always move
    /// out of a closed project into an open one.
    public var moveTargets: [Project]
    /// "Add a mission" choices.
    public var unfiledMissions: [Mission]
    /// Projects view v2 roll-up across the project's missions: the
    /// detail's first page of each kind plus any pages `loadMore(kind:)`
    /// has fetched since. Each page's `total` counts every row, its
    /// `nextBefore` is nil once the last is loaded.
    public var decisions: ProjectFeedPage<ProjectDecision>
    public var files: ProjectFeedPage<ProjectFile>
    public var milestonesPage: ProjectFeedPage<ProjectMilestone>
    /// The journal has sent the roll-up (false from an older journal, or
    /// before the first detail refresh): hosts hide its sections.
    public var hasFeed: Bool

    public init(project: Project, missions: [MissionRowModel] = [], closedMissions: [Mission] = [],
                needsYou: [TrackerItem] = [], openItems: [TrackerItem] = [], recentMilestones: [Milestone] = [], missionNums: [String: Int] = [:],
                sessionsByBox: [String: Int] = [:], sessionsByMission: [String: [DashboardSession]] = [:],
                roomCountsByMission: [String: Int] = [:],
                mergeTargets: [Project] = [], moveTargets: [Project] = [], unfiledMissions: [Mission] = [],
                decisions: ProjectFeedPage<ProjectDecision> = .init(), files: ProjectFeedPage<ProjectFile> = .init(),
                milestonesPage: ProjectFeedPage<ProjectMilestone> = .init(), hasFeed: Bool = false) {
        self.project = project; self.missions = missions; self.closedMissions = closedMissions
        self.needsYou = needsYou; self.openItems = openItems; self.recentMilestones = recentMilestones; self.missionNums = missionNums
        self.sessionsByBox = sessionsByBox; self.sessionsByMission = sessionsByMission
        self.roomCountsByMission = roomCountsByMission
        self.mergeTargets = mergeTargets; self.moveTargets = moveTargets; self.unfiledMissions = unfiledMissions
        self.decisions = decisions; self.files = files; self.milestonesPage = milestonesPage; self.hasFeed = hasFeed
    }

    public var needsYouCount: Int { max(project.needsYou, needsYou.count) }
}
