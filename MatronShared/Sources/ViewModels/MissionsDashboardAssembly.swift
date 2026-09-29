import Foundation
import MatronChat
import MatronJournal
import MatronModels

/// Everything the dashboard is assembled from, as the view model last
/// received it. A value, so the assembly is a pure function of it.
public struct MissionsDashboardInputs: Equatable, Sendable {
    public var missions: [Mission] = []
    public var summaries: [ChatSummary] = []
    /// Conversation id → roster `summary` (`JournalAPI.roster()`).
    public var roster: [String: String] = [:]
    /// Conversation id → newest TOC heading.
    public var tocs: [String: String] = [:]
    public var conversationsByMission: [String: [MissionConversation]] = [:]
    public var latestMilestones: [String: Milestone] = [:]
    public var needsYouItems: [String: [TrackerItem]] = [:]
    public var coordinatorConvoID: String?
    /// Conversation id → session state (`JournalStore.sessionStates`).
    /// `ChatSummary` no longer carries a state (dropped for chat-list
    /// performance), so this live map is the only source for a cached
    /// session's dot — it wins over a mission detail row's own `state`
    /// (`MissionConversation.state`), which can be stale the moment this
    /// device has synced fresher activity.
    public var sessionStates: [String: String] = [:]
    public init() {}
}

public struct MissionsDashboardSnapshot: Equatable, Sendable {
    public var cards: [DashboardMissionCard]
    public var looseSessions: [DashboardSession]
    public var closed: [Mission]
    /// Every mission's sessions, sorted and UNCAPPED — the Mac
    /// mission page's Sessions card lists them all, where a dashboard card
    /// shows `maxSessionRows`. Same rows, same sub-agent rule, so the card
    /// and the page never disagree about which sessions a mission has.
    public var sessionsByMission: [String: [DashboardSession]] = [:]
}

/// The dashboard's rules (spec 2026-09-28 §3.2–§3.6), pure so every one of
/// them is a plain unit test.
public enum MissionsDashboardAssembly {
    public static let maxNeedsYouRows = 3
    public static let maxSessionRows = 4
    /// A waiting session counts as "loose and live" for this long after its
    /// last activity (spec §3.3).
    public static let looseWaitingWindow: TimeInterval = 24 * 60 * 60

    public static func assemble(_ inputs: MissionsDashboardInputs, now: Date) -> MissionsDashboardSnapshot {
        let summariesByID = Dictionary(inputs.summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Task 3's store reads return every mission, closed included: cards,
        // loose-session exclusion, and needs-you all key off `open` alone —
        // a closed mission's own row goes only to `snapshot.closed` below,
        // and a still-running session on it falls through to loose (it has
        // nowhere else on this page to appear; see `looseSessions`).
        let open = inputs.missions.filter { $0.state == .open }
        // Every mission, closed included: a closed mission's page still
        // lists the sessions that did its work.
        var sessionsByMission: [String: [DashboardSession]] = [:]
        for mission in inputs.missions {
            sessionsByMission[mission.id] = missionSessions(for: mission, inputs: inputs, summariesByID: summariesByID)
        }
        let cards = open.map {
            card(for: $0, sessions: sessionsByMission[$0.id] ?? [], inputs: inputs, summariesByID: summariesByID)
        }.sorted(by: cardPrecedes)
        let closed = inputs.missions.filter { $0.state == .closed }
            .sorted { a, b in
                let (closedA, closedB) = (a.closedAt ?? .distantPast, b.closedAt ?? .distantPast)
                if closedA != closedB { return closedA > closedB }
                return a.num > b.num
            }
        let loose = looseSessions(inputs: inputs, openMissions: open, now: now)
        return MissionsDashboardSnapshot(cards: cards, looseSessions: loose, closed: closed,
                                         sessionsByMission: sessionsByMission)
    }

    // MARK: Cards

    /// One mission's sessions, sorted, uncapped. Sub-agent sessions stay
    /// off: they are the work of a session already listed, not work of
    /// their own. The `:sub:` id is the only marker available here — the
    /// chat summaries this reads come from `conversationsStream()`, which
    /// already drops every row with a parent, so a child is never in
    /// `summariesByID` to check.
    static func missionSessions(for mission: Mission, inputs: MissionsDashboardInputs,
                                summariesByID: [String: ChatSummary]) -> [DashboardSession] {
        let conversations = (inputs.conversationsByMission[mission.id] ?? []).filter { convo in
            !convo.id.contains(JournalEventType.childConvoInfix)
        }
        return sortedSessions(conversations.map { convo in
            session(for: convo, summary: summariesByID[convo.id], inputs: inputs)
        })
    }

    /// `sessions` is `missionSessions(for:…)` for this mission, computed
    /// once by `assemble` and shared with `sessionsByMission`.
    static func card(for mission: Mission, sessions: [DashboardSession], inputs: MissionsDashboardInputs,
                     summariesByID: [String: ChatSummary]) -> DashboardMissionCard {
        let items = inputs.needsYouItems[mission.id] ?? []
        let unassigned = mission.conversationCount == 0 && sessions.isEmpty
        let sessionTimes: [Date] = sessions.compactMap(\.lastActivity)
        let activity = ([mission.lastMilestoneAt, mission.statusUpdatedAt].compactMap { $0 } + sessionTimes).max()
        return DashboardMissionCard(
            mission: mission,
            attribution: unassigned ? attribution(for: mission, coordinatorConvoID: inputs.coordinatorConvoID,
                                                  originTitle: summariesByID[mission.originConvoID]?.title) : nil,
            latestStep: latestStep(for: mission, cached: inputs.latestMilestones[mission.id]),
            needsYouCount: max(mission.needsYou, items.count),
            needsYouItems: items.prefix(maxNeedsYouRows).map {
                DashboardNeedsYouItem(id: $0.id, num: $0.num, kind: $0.kind, title: $0.title)
            },
            sessions: Array(sessions.prefix(maxSessionRows)),
            moreSessions: max(0, sessions.count - maxSessionRows),
            anyRunning: sessions.contains { $0.state == .running },
            lastActivity: activity ?? mission.createdAt)
    }

    /// Needs you first, then any session running, then the rest; newest
    /// activity first within a group; the higher number breaks a tie.
    static func cardPrecedes(_ a: DashboardMissionCard, _ b: DashboardMissionCard) -> Bool {
        let groupA = group(a), groupB = group(b)
        if groupA != groupB { return groupA < groupB }
        if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
        return a.mission.num > b.mission.num
    }

    private static func group(_ card: DashboardMissionCard) -> Int {
        if card.needsYouCount > 0 { return 0 }
        return card.anyRunning ? 1 : 2
    }

    /// The cached newest milestone (it has a body) when it is at least as
    /// new as the list row's `last_milestone`; otherwise the list row's
    /// title alone.
    static func latestStep(for mission: Mission, cached: Milestone?) -> DashboardLatestStep? {
        if let cached {
            let listRow = mission.lastMilestone
            let isCurrent = listRow == nil || listRow?.num == cached.num || cached.createdAt >= (listRow?.createdAt ?? .distantPast)
            if isCurrent {
                return DashboardLatestStep(num: cached.num, kind: cached.kind, title: cached.title,
                                           body: cached.body, createdAt: cached.createdAt)
            }
        }
        guard let last = mission.lastMilestone else { return nil }
        return DashboardLatestStep(num: last.num, kind: last.kind, title: last.title, createdAt: last.createdAt)
    }

    /// "from Coordinator" when the mission was born in the Coordinator's
    /// conversation, otherwise "from <origin title>" when this device knows
    /// that conversation, otherwise nil. Takes the one title this mission
    /// could possibly need (its origin conversation's, or nil when this
    /// device has no cached summary for it) rather than a lookup table —
    /// `card(for:)` used to build `summariesByID.mapValues(\.title)` in
    /// full on every card, on every rebuild (~700 entries per card with
    /// ~200 open missions cached).
    public static func attribution(for mission: Mission, coordinatorConvoID: String?,
                                   originTitle: String?) -> String? {
        if let coordinatorConvoID, !coordinatorConvoID.isEmpty, mission.originConvoID == coordinatorConvoID {
            return "from Coordinator"
        }
        guard let originTitle, !originTitle.isEmpty else { return nil }
        return "from \(originTitle)"
    }

    // MARK: Sessions

    /// A mission conversation: the cached chat summary when this device has
    /// one (activity, tag), else the detail row itself. The state always
    /// comes from the live `sessionStates` map when this device has one —
    /// `ChatSummary` carries no state of its own — falling back to the
    /// mission detail's own (possibly stale) `state`.
    static func session(for convo: MissionConversation, summary: ChatSummary?,
                        inputs: MissionsDashboardInputs) -> DashboardSession {
        let text = summaryText(convoID: convo.id, roster: inputs.roster, tocs: inputs.tocs, snippet: summary?.snippet)
        let stateString = inputs.sessionStates[convo.id] ?? convo.state
        if let summary { return session(from: summary, text: text, stateString: stateString) }
        let split = SessionTag.splitTitle(convo.title)
        return DashboardSession(
            id: convo.id, title: split.title.isEmpty ? convo.id : split.title,
            state: DashboardSessionState(sessionState: stateString), lastActivity: nil, summary: text,
            tag: split.sessionShort.map { SessionTagInputs(boxLetter: nil, boxName: nil, sessionShort: $0) },
            boxName: convo.box, needsYou: 0)
    }

    static func session(from summary: ChatSummary, text: String?, stateString: String) -> DashboardSession {
        DashboardSession(id: summary.id, title: summary.title,
                         state: DashboardSessionState(sessionState: stateString),
                         lastActivity: summary.lastActivity, summary: text, tag: tagInputs(summary),
                         boxName: nil, needsYou: summary.needsUserCount)
    }

    static func tagInputs(_ summary: ChatSummary) -> SessionTagInputs? {
        guard summary.boxShort != nil || summary.sessionShort != nil || !summary.roomBoxNames.isEmpty else { return nil }
        return SessionTagInputs(boxLetter: summary.boxShort, boxName: summary.boxName, sessionShort: summary.sessionShort,
                                roomBoxNames: summary.roomBoxNames, roomBoxShorts: summary.roomBoxShorts)
    }

    /// Running → waiting → done, then newest activity (never-active last),
    /// then id so the order is stable.
    static func sortedSessions(_ sessions: [DashboardSession]) -> [DashboardSession] {
        sessions.sorted { a, b in
            if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
            switch (a.lastActivity, b.lastActivity) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
    }

    /// Spec §3.3. "On a mission" means literally in an OPEN mission's loaded
    /// conversation list — never every open mission's origin by default, or
    /// an unassigned mission born outside the Coordinator would make its own
    /// still-running origin session vanish from the page (its card has no
    /// sessions either, since `conversationCount == 0`). The origin stands
    /// in only when that mission's conversation list hasn't loaded yet
    /// (`conversationsByMission[mission.id] == nil`) AND the mission is
    /// known to have conversations (`conversationCount > 0`) — otherwise a
    /// session still running after its mission closed, or before the first
    /// detail fetch lands, has nowhere else on this page to appear. A loose
    /// session's state comes from the live `sessionStates` map, falling back
    /// to the store's own default ("waiting") when this device has no entry
    /// for it — `ChatSummary` carries no state of its own.
    static func looseSessions(inputs: MissionsDashboardInputs, openMissions: [Mission], now: Date) -> [DashboardSession] {
        var onMission = Set<String>()
        for mission in openMissions {
            if let convos = inputs.conversationsByMission[mission.id] {
                for convo in convos { onMission.insert(convo.id) }
            } else if mission.conversationCount > 0 {
                onMission.insert(mission.originConvoID)
            }
        }
        let coordinator = inputs.coordinatorConvoID.flatMap { $0.isEmpty ? nil : $0 }
        let cutoff = now.addingTimeInterval(-looseWaitingWindow)
        let loose: [DashboardSession] = inputs.summaries.compactMap { summary in
            guard summary.parentConvoID == nil, !onMission.contains(summary.id), summary.id != coordinator else { return nil }
            let stateString = inputs.sessionStates[summary.id] ?? "waiting"
            switch DashboardSessionState(sessionState: stateString) {
            case .running: break
            case .waiting:
                guard let last = summary.lastActivity, last >= cutoff else { return nil }
            case .done: return nil
            }
            let text = summaryText(convoID: summary.id, roster: inputs.roster, tocs: inputs.tocs, snippet: summary.snippet)
            return session(from: summary, text: text, stateString: stateString)
        }
        return sortedSessions(loose)
    }

    /// Spec §3.5: roster summary, else newest TOC heading, else the chat
    /// snippet, else nothing. Blank candidates fall through.
    public static func summaryText(convoID: String, roster: [String: String], tocs: [String: String],
                                   snippet: String?) -> String? {
        for candidate in [roster[convoID], tocs[convoID], snippet] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }
}
