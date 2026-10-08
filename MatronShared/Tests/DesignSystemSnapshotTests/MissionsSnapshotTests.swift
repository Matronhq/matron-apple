import XCTest
import SwiftUI
import MatronModels
import MatronEvents
@testable import MatronDesignSystem

final class MissionsSnapshotTests: XCTestCase {
    private let mission = Mission(
        id: "ms_1", num: 61, title: "Missions & milestones", body: "Give every piece of work a readable record.",
        originConvoID: "c1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
        lastMilestoneAt: Date(timeIntervalSince1970: 1_700_000_400),
        openItems: 3, needsYou: 1, conversationCount: 2, milestoneCount: 5,
        lastMilestone: MissionLastMilestone(num: 63, title: "Wired the journal migration",
                                            kind: .userInput, createdAt: Date(timeIntervalSince1970: 1_700_000_400)))

    private let milestones = [
        Milestone(id: "ml_2", missionID: "ms_1", num: 63, kind: .userInput, title: "Alice asked for missions",
                  body: "the brief", convoID: "c1", seq: 4210, createdAt: Date(timeIntervalSince1970: 1_700_000_400)),
        Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .progress, title: "Journal half merged",
                  body: "", convoID: "c1", seq: 3100, createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
    ]

    // MARK: Pure logic

    func testGlyphsAreDistinctPerKindAndState() {
        XCTAssertNotEqual(MissionGlyph.symbol(MilestoneKind.userInput), MissionGlyph.symbol(MilestoneKind.progress))
        XCTAssertEqual(MissionGlyph.label(MilestoneKind.userInput), "Your input")
        XCTAssertEqual(MissionGlyph.label(MilestoneKind.progress), "Progress")
        XCTAssertEqual(MissionGlyph.label(MissionState.open), "Open")
        XCTAssertEqual(MissionGlyph.label(MissionState.closed), "Closed")
    }

    /// A marker whose `mission_title` was sieved away must still name the
    /// mission — as `#61`, never as an empty string.
    func testInlineCardsNameTheMissionEvenWithoutATitle() {
        let sieved = MilestoneMarkerEvent(milestoneID: "ml_2", num: 63, kind: .userInput,
                                          title: "Alice asked for missions", body: "the brief",
                                          missionID: "ms_1", missionNum: 61, missionTitle: nil, by: .agent)
        XCTAssertEqual(MilestoneCard.subtitle(for: sieved), "Your input · #61")
        let titled = MilestoneMarkerEvent(milestoneID: "ml_2", num: 63, kind: .progress, title: "t",
                                          missionID: "ms_1", missionNum: 61, missionTitle: "Missions & milestones", by: .agent)
        XCTAssertEqual(MilestoneCard.subtitle(for: titled), "Progress · Missions & milestones")
    }

    func testMissionNoticeText() {
        let created = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Missions & milestones", action: .created, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: created), "🏁 Mission #61 started · Missions & milestones")
        let joined = MissionMarkerEvent(missionID: "ms_1", num: 61, title: nil, action: .joined, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: joined), "🏁 Joined mission #61")
        let closed = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Missions & milestones",
                                        action: .closed, by: .user, openItemNums: [64, 70])
        XCTAssertEqual(MissionNotice.text(for: closed), "🏁 Mission #61 · Missions & milestones closed over #64, #70")
        let updated = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Renamed", action: .updated, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: updated), "🏁 Mission #61 renamed · Renamed")
        let left = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Promo", action: .left, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: left), "🏁 Left mission #61 · Promo")
        let now = MissionMarkerEvent(missionID: "ms_1", num: 61, title: nil, action: .currentChanged, by: .agent)
        XCTAssertEqual(MissionNotice.text(for: now), "🏁 Now on mission #61")
        let moved = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Promo", action: .updated, by: .user,
                                       projectChanged: true)
        XCTAssertEqual(MissionNotice.text(for: moved), "🏁 Mission #61 · Promo changed project")
    }

    /// The close confirmation's title, on the symbol the user actually
    /// sees rendered (moved off the view model's dead `closeConfirmation`
    /// property, MINOR-2).
    func testConfirmationTitleCountsOpenItems() {
        XCTAssertEqual(MissionDetailView.confirmationTitle(openItems: 0), "Close this mission?")
        XCTAssertEqual(MissionDetailView.confirmationTitle(openItems: 1), "Close with 1 item still open?")
        XCTAssertEqual(MissionDetailView.confirmationTitle(openItems: 2), "Close with 2 items still open?")
    }

    /// The detail now asks for `history=1&subchats=1`, so the cache holds
    /// conversations that left and every sub-chat. The Conversations
    /// section lists only the current members, as before the flags.
    func testConversationsSectionListsOnlyCurrentMembers() {
        let model = MissionDetailView.Model(
            mission: mission, milestones: [MissionDetailView.Model.MilestoneRow](), openItems: [],
            conversations: [
                MissionConversation(id: "c1", title: "On it", box: nil, state: "running"),
                MissionConversation(id: "c2", title: "Left", box: nil, state: "done",
                                    endedAt: Date(timeIntervalSince1970: 100)),
                MissionConversation(id: "c1:sub:a", title: "Sub-chat", box: nil, state: "running",
                                    parentConvoID: "c1"),
            ],
            showOnlyUserInput: false, closeSummary: "", isBusy: false)
        XCTAssertEqual(model.groups.onItNow.map(\.id), ["c1"])
        XCTAssertEqual(model.groups.onItNow.first?.subchatCount, 1, "the sub-chat folds under its parent")
        XCTAssertEqual(model.groups.earlier.map(\.id), ["c2"])
        let passed = MissionConversationGroups(conversations: model.conversations, missionState: .open,
                                               liveStates: ["c1": "idle"])
        var fed = model
        fed.conversationGroups = passed
        XCTAssertEqual(fed.groups, passed, "the view model's groups win over the fallback")
    }

    // MARK: Snapshots

    func testMissionRow() {
        assertVariants(of: MissionRowView(row: MissionRowModel(closed: Mission(
            id: "ms_1", num: 61, state: .closed, title: "Missions & milestones", closeSummary: "Shipped on both apps.",
            originConvoID: "c1", closedAt: Date(timeIntervalSince1970: 1_700_000_400))),
                                          now: Date(timeIntervalSince1970: 1_700_100_000))
            .frame(width: 380).padding(), named: "mission-row")
    }

    func testMissionDetail() {
        let model = MissionDetailView.Model(
            mission: mission,
            // One row tagged (its conversation is cached on this device),
            // one untagged — the two states the page has to draw.
            milestones: [
                .init(milestone: milestones[0],
                      sessionTag: SessionTagInputs(boxLetter: "B", boxName: "box-2", sessionShort: "bc")),
                .init(milestone: milestones[1], sessionTag: nil),
            ],
            openItems: [TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Which order for the tabs?", originConvoID: "c1")],
            conversations: [MissionConversation(id: "c1", title: "Session", box: "box-2", state: "running")],
            showOnlyUserInput: false, closeSummary: "", isBusy: false)
        assertVariants(of: MissionDetailView(model: model, onToggleUserInputOnly: { _ in },
                                             onOpenMilestone: { _ in }, onOpenItem: { _ in },
                                             onOpenConversation: { _ in }, onEditCloseSummary: { _ in },
                                             onClose: {}, onRefresh: {})
            .frame(width: 420, height: 640), named: "mission-detail")
    }

    func testMissionDetailPagesMilestonesAtFive() {
        XCTAssertEqual(MissionDetailView.initialMilestones, 5)
        XCTAssertEqual(MissionDetailView.milestonePage, 20)
    }

    func testMissionDetailWithProjectStatusAndConversations() {
        let now = Date(timeIntervalSince1970: 1_700_000_600)
        let withStatus = Mission(
            id: "ms_1", num: 4907, title: "Launch day: Wed 7 Oct 07:00", originConvoID: "c1",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000), updatedAt: now,
            needsYou: 1, status: "Branch green; S7 confirmed, robots.txt in the purge.", statusBy: .agent,
            statusUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000), projectID: "pj_1")
        let milestones = (0..<8).map { i in
            Milestone(id: "ml_\(i)", missionID: "ms_1", num: 100 + i, kind: .progress, title: "Step \(i)",
                      convoID: "c1", seq: Int64(i), createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(i) * 600))
        }
        let model = MissionDetailView.Model(
            mission: withStatus, project: Project(id: "pj_1", num: 4000, title: "Promo launch"),
            milestones: milestones, sessionTags: [:],
            openItems: [TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Cloudflare: page rule for /blog", originConvoID: "c1"),
                        TrackerItem(id: "it_2", num: 65, kind: .task, awaiting: .agent, title: "Purge list", originConvoID: "c1")],
            conversations: [
                MissionConversation(id: "c1", title: "sales-chat launch coordination", box: "slate", state: "waiting",
                                    isCurrent: true, joinedAt: Date(timeIntervalSince1970: 1_699_500_000), how: "origin",
                                    subchatCount: 6,
                                    otherMissions: [MissionOtherLink(id: "ms_4791", num: 4791, title: "Promo branch",
                                                                     isCurrent: true,
                                                                     joinedAt: Date(timeIntervalSince1970: 1_699_300_000))]),
                MissionConversation(id: "c2", title: "SEO rows for launch", box: "slate", state: "done",
                                    joinedAt: Date(timeIntervalSince1970: 1_699_400_000),
                                    endedAt: Date(timeIntervalSince1970: 1_699_490_000),
                                    otherMissions: [MissionOtherLink(id: "ms_4905", num: 4905, title: "SEO phase 2",
                                                                     isCurrent: true,
                                                                     joinedAt: Date(timeIntervalSince1970: 1_699_490_000))]),
            ],
            moveTargets: [Project(id: "pj_1", num: 4000, title: "Promo launch")],
            showOnlyUserInput: false, closeSummary: "", isBusy: false)
        assertVariants(of: MissionDetailView(model: model, onToggleUserInputOnly: { _ in }, onOpenMilestone: { _ in },
                                             onOpenItem: { _ in }, onOpenConversation: { _ in }, onEditCloseSummary: { _ in },
                                             onClose: {}, onRefresh: {}, onOpenProject: { _ in }, onMove: { _ in },
                                             onOpenMission: { _ in })
            .frame(width: 390, height: 1_300), named: "mission-detail-project")
    }

    /// A mission page with an agent-chat room in its own Rooms group,
    /// after On it now, its participants by their session tags.
    func testMissionDetailWithARoom() {
        let conversations = [
            MissionConversation(id: "c1", title: "merge queue", box: "box-2", state: "running",
                                isCurrent: true, joinedAt: Date(timeIntervalSince1970: 1_699_500_000), how: "origin"),
        ]
        let room = MissionRoom(id: "r1", title: "PR 8693 review", sessionState: "waiting",
                               lastActivity: Date(timeIntervalSince1970: 1_699_000_000),
                               participantConvoIDs: ["c1", "c9"])
        let groups = MissionConversationGroups(conversations: conversations, missionState: .open, rooms: [room])
        let model = MissionDetailView.Model(
            mission: mission, milestones: [milestones[0]],
            sessionTags: ["c1": SessionTagInputs(boxLetter: "B", boxName: "box-2", sessionShort: "f3"),
                          "c9": SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "0b")],
            openItems: [], conversations: conversations, conversationGroups: groups,
            showOnlyUserInput: false, closeSummary: "", isBusy: false)
        assertVariants(of: MissionDetailView(model: model, onToggleUserInputOnly: { _ in }, onOpenMilestone: { _ in },
                                             onOpenItem: { _ in }, onOpenConversation: { _ in }, onEditCloseSummary: { _ in },
                                             onClose: {}, onRefresh: {})
            .frame(width: 390, height: 900), named: "mission-detail-room")
    }

    func testMilestoneCardAndMissionNotice() {
        let marker = MilestoneMarkerEvent(milestoneID: "ml_2", num: 63, kind: .userInput,
                                          title: "Alice asked for missions", body: "Make the work readable.",
                                          missionID: "ms_1", missionNum: 61, missionTitle: "Missions & milestones", by: .agent)
        assertVariants(of: MilestoneCard(marker: marker, onOpen: {}).frame(width: 360).padding(), named: "milestone-card")
        let notice = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Missions & milestones", action: .closed, by: .user)
        assertVariants(of: MissionNotice(marker: notice, onOpen: {}).frame(width: 360).padding(), named: "mission-notice")
    }
}
