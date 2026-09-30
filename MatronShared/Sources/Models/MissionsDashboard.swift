import Foundation

// Value types for the Missions dashboard (spec 2026-09-28 missions
// dashboard §3). Built by `MissionsDashboardAssembly` (MatronViewModels),
// drawn by `MissionsDashboardView` (MatronDesignSystem) — the one module
// both can see.

/// A session's state as the dashboard's dot shows it.
public enum DashboardSessionState: String, Sendable, Equatable, Hashable, CaseIterable {
    case running, waiting, done

    /// The store's / journal's `session_state`. Anything that is not
    /// `running` or `done` reads as waiting — the store's own default.
    public init(sessionState: String) {
        switch sessionState {
        case "running": self = .running
        case "done": self = .done
        default: self = .waiting
        }
    }

    /// Running first, then waiting, then done (spec §3.2).
    public var sortRank: Int {
        switch self {
        case .running: return 0
        case .waiting: return 1
        case .done: return 2
        }
    }
}

/// One session row on a mission card, or one loose-session card.
public struct DashboardSession: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let state: DashboardSessionState
    public let lastActivity: Date?
    /// The two-line "what's happening now" text (spec §3.5), or nil.
    public let summary: String?
    /// The `A:bc` tag halves when this device has the conversation cached.
    public let tag: SessionTagInputs?
    /// A bare box name from the mission detail, for a conversation this
    /// device has never synced (no `tag` to draw) — rendered as a chip.
    public let boxName: String?
    public let needsYou: Int

    public init(id: String, title: String, state: DashboardSessionState, lastActivity: Date? = nil,
                summary: String? = nil, tag: SessionTagInputs? = nil, boxName: String? = nil, needsYou: Int = 0) {
        self.id = id; self.title = title; self.state = state; self.lastActivity = lastActivity
        self.summary = summary; self.tag = tag; self.boxName = boxName; self.needsYou = needsYou
    }
}

/// One open item awaiting the user, as a card row.
public struct DashboardNeedsYouItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let num: Int
    public let kind: ItemKind
    public let title: String
    public init(id: String, num: Int, kind: ItemKind, title: String) {
        self.id = id; self.num = num; self.kind = kind; self.title = title
    }
}

/// The card's "latest step": the newest milestone, with its body when this
/// device has cached it (`Mission.lastMilestone` carries no body).
public struct DashboardLatestStep: Equatable, Hashable, Sendable {
    public let num: Int
    public let kind: MilestoneKind
    public let title: String
    public let body: String
    public let createdAt: Date
    public init(num: Int, kind: MilestoneKind, title: String, body: String = "", createdAt: Date) {
        self.num = num; self.kind = kind; self.title = title; self.body = body; self.createdAt = createdAt
    }
}

/// One open mission's card (spec §3.2).
public struct DashboardMissionCard: Identifiable, Equatable, Hashable, Sendable {
    public let mission: Mission
    /// "from Coordinator" / "from <title>" — unassigned missions only.
    public let attribution: String?
    public let latestStep: DashboardLatestStep?
    /// The larger of the server's `needs_you` and the local rows, so a
    /// cache that hasn't caught up never under-reports.
    public let needsYouCount: Int
    /// At most `MissionsDashboardAssembly.maxNeedsYouRows`.
    public let needsYouItems: [DashboardNeedsYouItem]
    /// At most `MissionsDashboardAssembly.maxSessionRows`, sorted.
    public let sessions: [DashboardSession]
    public let moreSessions: Int
    /// Any of the mission's sessions (not only the listed ones) running.
    public let anyRunning: Bool
    /// Max of last milestone, status time and sessions' last activity.
    public let lastActivity: Date

    public var id: String { mission.id }
    public var moreNeedsYou: Int { max(0, needsYouCount - needsYouItems.count) }

    public init(mission: Mission, attribution: String? = nil, latestStep: DashboardLatestStep? = nil,
                needsYouCount: Int = 0, needsYouItems: [DashboardNeedsYouItem] = [],
                sessions: [DashboardSession] = [], moreSessions: Int = 0, anyRunning: Bool = false,
                lastActivity: Date) {
        self.mission = mission; self.attribution = attribution; self.latestStep = latestStep
        self.needsYouCount = needsYouCount; self.needsYouItems = needsYouItems; self.sessions = sessions
        self.moreSessions = moreSessions; self.anyRunning = anyRunning; self.lastActivity = lastActivity
    }
}

/// What a tap on the dashboard asks the host to do. One enum so both hosts
/// route every tap through one function each (`AppShellNavigation
/// .handleDashboard`, `MacChatListView.handleDashboardAction`).
public enum MissionsDashboardAction: Equatable, Hashable, Sendable {
    case openMission(String)
    case openSession(String)
    case openItem(String)
}
