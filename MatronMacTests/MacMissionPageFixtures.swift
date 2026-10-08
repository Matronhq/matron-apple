#if os(macOS)
import Foundation
@testable import MatronMac
import MatronModels

/// A mission shaped like the approved wireframes, at a fixed `now`.
enum MacMissionPageFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    static let minute: TimeInterval = 60, hour: TimeInterval = 3_600

    static func item(_ num: Int, _ kind: ItemKind, _ title: String, state: ItemState = .open,
                     resolution: ItemResolution? = nil, awaiting: ItemAwaiting? = nil,
                     updated: TimeInterval, closed: TimeInterval? = nil, convo: String = "c-nav") -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: kind, state: state, resolution: resolution, awaiting: awaiting,
                    title: title, originConvoID: convo, createdAt: ago(updated + hour), updatedAt: ago(updated),
                    closedAt: closed.map(ago), missionID: "ms_1", missionNum: 3778)
    }

    static let openItems: [TrackerItem] = [
        item(3801, .question, "Merge bridge PR 318 and deploy to the bridges?", awaiting: .user, updated: 3 * hour),
        item(3802, .question, "Mac mission page: two columns, bigger text, a board", awaiting: .user, updated: 5 * minute),
        item(3803, .question, "Merge apple PR 267 (dashboard screens)?", awaiting: .user, updated: 40 * minute),
        item(3804, .task, "Journal: privacy checks fail open on revoke", updated: 14 * hour, convo: "c-unknown"),
        item(3805, .task, "Decided section for answered items", awaiting: .agent, updated: 20 * minute),
        item(3806, .task, "Tables & code blocks in threads", awaiting: .agent, updated: 25 * minute),
        item(3807, .decision, "Missions nav opens the dashboard", awaiting: .agent, updated: 2 * hour, convo: "c-unknown"),
    ]

    static let closedItems: [TrackerItem] = [
        item(3790, .question, "Merge apple PR 265?", state: .closed, resolution: .answered, updated: 30 * minute,
             closed: 30 * minute),
        item(3791, .decision, "Missions nav always opens the dashboard", state: .closed, resolution: .decided,
             updated: 8 * hour, closed: 8 * hour),
        item(3792, .task, "Memories entry: toolbar button / ⌘5", state: .closed, resolution: .done,
             updated: 20 * hour, closed: 20 * hour),
        item(3793, .task, "Old approach to the side panel", state: .closed, resolution: .cancelled,
             updated: 22 * hour, closed: 22 * hour),
    ]

    /// Six, one past `MacMilestonesCard.initialCount`, so the overview
    /// snapshot draws "Show more (1)".
    static let milestones: [Milestone] = [
        milestone(9, .userInput, "Alice: tracker threads need parity with chat",
                  "Decided items, tables, queued drops, image paste, Shift+Return.", 16 * minute),
        milestone(8, .progress, "Dashboard: all 14 app tasks built and reviewed",
                  "iOS/Mac screens PR opened, stacked on the shared layer.", 7 * hour),
        milestone(7, .progress, "Apps shared layer done and reviewed, PR 265 opened", "Bridge PR 318 awaiting Alice.", 9 * hour),
        milestone(6, .progress, "Journal mission status live: PR 95 merged and deployed",
                  "Deployed to host-a, backup taken first.", 12 * hour),
        milestone(5, .userInput, "Alice: remove the ⌘0 side panel; redesign Missions as a live dashboard", "", 16 * hour),
        milestone(4, .progress, "Mission created from the Coordinator memories thread", "", 20 * hour),
    ]

    static func milestone(_ num: Int, _ kind: MilestoneKind, _ title: String, _ body: String,
                          _ age: TimeInterval) -> Milestone {
        Milestone(id: "ml_\(num)", missionID: "ms_1", num: num, kind: kind, title: title, body: body,
                  convoID: "c-nav", seq: Int64(num * 10), createdAt: ago(age))
    }

    static let project = Project(id: "pj_1", num: 4000, title: "Promo launch")

    static let conversations: [MissionConversation] = [
        MissionConversation(id: "c-nav", title: "Missions Navigation Refinement", box: "lab-mac", state: "running",
                            isCurrent: true, joinedAt: ago(3 * 86_400), how: "origin", subchatCount: 6,
                            otherMissions: [MissionOtherLink(id: "ms_4791", num: 4791, title: "Promo branch",
                                                             joinedAt: ago(2 * 86_400))]),
        MissionConversation(id: "c-verify", title: "production journal verification", box: "lab-mac", state: "waiting",
                            joinedAt: ago(86_400), how: "joined"),
        MissionConversation(id: "c-mem", title: "Coordinator memories rollout", box: "alder", state: "done",
                            joinedAt: ago(2 * 86_400), endedAt: ago(86_400), how: "joined",
                            otherMissions: [MissionOtherLink(id: "ms_4905", num: 4905, title: "SEO phase 2", isCurrent: true,
                                                             joinedAt: ago(86_400))]),
    ]

    /// Active links only (`pageMissionSessions`, R7): `c-mem` ended, so it is
    /// never in here — its Conversations-card row falls back to its own
    /// `endedAt` for an age, as the app does.
    static let sessions: [DashboardSession] = [
        DashboardSession(id: "c-nav", title: "Missions Navigation Refinement", state: .running, lastActivity: ago(60),
                         summary: "Fixing tracker thread parity: composer, tables and the Decided section.",
                         tag: SessionTagInputs(boxLetter: "L", boxName: "lab-mac", sessionShort: "nv")),
        DashboardSession(id: "c-verify", title: "production journal verification", state: .waiting,
                         lastActivity: ago(3_600), summary: "Waiting: verified PR 94 on host-a.",
                         tag: SessionTagInputs(boxLetter: "L", boxName: "lab-mac", sessionShort: "pj")),
    ]

    static let mission = Mission(
        id: "ms_1", num: 3778, title: "Give the Coordinator a way to save memories", originConvoID: "c-nav",
        createdAt: ago(3 * 86_400), updatedAt: ago(12 * minute), needsYou: 3,
        status: "Memories shipped on all five platforms. Missions dashboard: shared layer merged; the iOS/Mac "
            + "screens PR is green and waiting on your merge, and bridge PR 318 (mission status tools) waits "
            + "for your go to deploy.",
        statusBy: .agent, statusUpdatedAt: ago(12 * minute), projectID: "pj_1")

    /// An agent-chat room between `c-nav` (on this mission) and a session
    /// on another box — the Conversations card's Rooms group.
    static let room = MissionRoom(id: "r-train", title: "PR 8693 merge order", sessionState: "waiting",
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
