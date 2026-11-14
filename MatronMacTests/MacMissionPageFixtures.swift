#if os(macOS)
import Foundation
@testable import MatronMac
import MatronModels

/// A made-up mission shaped like the approved wireframes, at a fixed `now`.
enum MacMissionPageFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    static let minute: TimeInterval = 60, hour: TimeInterval = 3_600

    static func item(_ num: Int, _ kind: ItemKind, _ title: String, state: ItemState = .open,
                     resolution: ItemResolution? = nil, awaiting: ItemAwaiting? = nil,
                     updated: TimeInterval, closed: TimeInterval? = nil, convo: String = "c-nav") -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: kind, state: state, resolution: resolution, awaiting: awaiting,
                    title: title, originConvoID: convo, createdAt: ago(updated + hour), updatedAt: ago(updated),
                    closedAt: closed.map(ago), missionID: "ms_1", missionNum: 2240)
    }

    static let openItems: [TrackerItem] = [
        item(2251, .question, "Turn search on for everyone?", awaiting: .user, updated: 3 * hour),
        item(2252, .question, "Results page: two columns, bigger text, filters", awaiting: .user, updated: 5 * minute),
        item(2253, .question, "Ship the results page now?", awaiting: .user, updated: 40 * minute),
        item(2254, .task, "Search: private pages show up in results", updated: 14 * hour, convo: "c-unknown"),
        item(2255, .task, "Group results by section", awaiting: .agent, updated: 20 * minute),
        item(2256, .task, "Tables & code blocks in results", awaiting: .agent, updated: 25 * minute),
        item(2257, .decision, "Search opens the results page", awaiting: .agent, updated: 2 * hour, convo: "c-unknown"),
    ]

    static let closedItems: [TrackerItem] = [
        item(2241, .question, "Ship the search index?", state: .closed, resolution: .answered, updated: 30 * minute,
             closed: 30 * minute),
        item(2242, .decision, "Search always opens the results page", state: .closed, resolution: .decided,
             updated: 8 * hour, closed: 8 * hour),
        item(2243, .task, "Search box: toolbar button / ⌘K", state: .closed, resolution: .done,
             updated: 20 * hour, closed: 20 * hour),
        item(2244, .task, "Old approach to the side panel", state: .closed, resolution: .cancelled,
             updated: 22 * hour, closed: 22 * hour),
    ]

    /// Six, one past `MacMilestonesCard.initialCount`, so the overview
    /// snapshot draws "Show more (1)".
    static let milestones: [Milestone] = [
        milestone(9, .userInput, "Alice: search should cover the guides too",
                  "Guides, reference pages, the changelog and the page titles.", 16 * minute),
        milestone(8, .progress, "Results page: all 14 tasks built and reviewed",
                  "Phone and desktop layouts opened for review, on top of the index.", 7 * hour),
        milestone(7, .progress, "Search index done and reviewed", "The results page waits on Alice.", 9 * hour),
        milestone(6, .progress, "Search live on staging",
                  "Checked on staging after a fresh build.", 12 * hour),
        milestone(5, .userInput, "Alice: drop the side panel; show results on a page of their own", "", 16 * hour),
        milestone(4, .progress, "Mission created from the docs planning chat", "", 20 * hour),
    ]

    static func milestone(_ num: Int, _ kind: MilestoneKind, _ title: String, _ body: String,
                          _ age: TimeInterval) -> Milestone {
        Milestone(id: "ml_\(num)", missionID: "ms_1", num: num, kind: kind, title: title, body: body,
                  convoID: "c-nav", seq: Int64(num * 10), createdAt: ago(age))
    }

    static let project = Project(id: "pj_1", num: 2100, title: "Docs site launch")

    static let conversations: [MissionConversation] = [
        MissionConversation(id: "c-nav", title: "Docs search", box: "lab-mac", state: "running",
                            isCurrent: true, joinedAt: ago(3 * 86_400), how: "origin", subchatCount: 6,
                            otherMissions: [MissionOtherLink(id: "ms_2171", num: 2171, title: "Docs search",
                                                             joinedAt: ago(2 * 86_400))]),
        MissionConversation(id: "c-verify", title: "staging check", box: "lab-mac", state: "waiting",
                            joinedAt: ago(86_400), how: "joined"),
        MissionConversation(id: "c-mem", title: "Search index build", box: "alder", state: "done",
                            joinedAt: ago(2 * 86_400), endedAt: ago(86_400), how: "joined",
                            otherMissions: [MissionOtherLink(id: "ms_2174", num: 2174, title: "Docs site analytics", isCurrent: true,
                                                             joinedAt: ago(86_400))]),
    ]

    /// Active links only (`pageMissionSessions`, R7): `c-mem` ended, so it is
    /// never in here — its Conversations-card row falls back to its own
    /// `endedAt` for an age, as the app does.
    static let sessions: [DashboardSession] = [
        DashboardSession(id: "c-nav", title: "Docs search", state: .running, lastActivity: ago(60),
                         summary: "Grouping results by section, with tables and code blocks.",
                         tag: SessionTagInputs(boxLetter: "L", boxName: "lab-mac", sessionShort: "nv")),
        DashboardSession(id: "c-verify", title: "staging check", state: .waiting,
                         lastActivity: ago(3_600), summary: "Waiting: checked the search page on staging.",
                         tag: SessionTagInputs(boxLetter: "L", boxName: "lab-mac", sessionShort: "pj")),
    ]

    static let mission = Mission(
        id: "ms_1", num: 2240, title: "Add search to the docs site", originConvoID: "c-nav",
        createdAt: ago(3 * 86_400), updatedAt: ago(12 * minute), needsYou: 3,
        status: "Search works on staging. The index is merged; the results page is green and waiting on "
            + "your merge, and turning search on for everyone waits for your go.",
        statusBy: .agent, statusUpdatedAt: ago(12 * minute), projectID: "pj_1")

    /// An agent-chat room between `c-nav` (on this mission) and a session
    /// on another box — the Conversations card's Rooms group.
    static let room = MissionRoom(id: "r-1", title: "Merge order for the search changes", sessionState: "waiting",
                                  lastActivity: ago(5 * minute), participantConvoIDs: ["c-nav", "c-slate"])
    static let roomTags: [String: SessionTagInputs] = [
        "c-nav": SessionTagInputs(boxLetter: "L", boxName: "lab-mac", sessionShort: "nv"),
        "c-slate": SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "0b"),
    ]

    static func model(showOnlyUserInput: Bool = false, rooms: [MissionRoom] = []) -> MacMissionPageModel {
        let shown = showOnlyUserInput ? milestones.filter { $0.kind == .userInput } : milestones
        return MacMissionPageModel(
            mission: mission, milestones: shown,
            milestoneBodies: MacMilestoneBodyCache().bodies(for: shown),
            showOnlyUserInput: showOnlyUserInput, openItems: openItems, openItemsLoaded: true,
            closedItems: closedItems, closedItemsTotal: closedItems.count,
            sessions: sessions, conversations: conversations,
            project: project, moveTargets: [project],
            conversationGroups: MissionConversationGroups(conversations: conversations, missionState: .open,
                                                          rooms: rooms),
            sessionTags: rooms.isEmpty ? [:] : roomTags, isBusy: false)
    }
}
#endif
