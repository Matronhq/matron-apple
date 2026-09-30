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
        Milestone(id: "ml_2", missionID: "ms_1", num: 63, kind: .userInput, title: "Dan asked for missions",
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
                                          title: "Dan asked for missions", body: "the brief",
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
        XCTAssertEqual(model.memberConversations.map(\.id), ["c1"])
    }

    // MARK: Snapshots

    func testMissionRow() {
        assertVariants(of: MissionRowView(mission: mission).frame(width: 380).padding(), named: "mission-row")
    }

    func testMissionDetail() {
        let model = MissionDetailView.Model(
            mission: mission,
            // One row tagged (its conversation is cached on this device),
            // one untagged — the two states the page has to draw.
            milestones: [
                .init(milestone: milestones[0],
                      sessionTag: SessionTagInputs(boxLetter: "D", boxName: "dev-2", sessionShort: "bc")),
                .init(milestone: milestones[1], sessionTag: nil),
            ],
            openItems: [TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user,
                                    title: "Which order for the tabs?", originConvoID: "c1")],
            conversations: [MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running")],
            showOnlyUserInput: false, closeSummary: "", isBusy: false)
        assertVariants(of: MissionDetailView(model: model, onToggleUserInputOnly: { _ in },
                                             onOpenMilestone: { _ in }, onOpenItem: { _ in },
                                             onOpenConversation: { _ in }, onEditCloseSummary: { _ in },
                                             onClose: {}, onRefresh: {})
            .frame(width: 420, height: 640), named: "mission-detail")
    }

    func testMilestoneCardAndMissionNotice() {
        let marker = MilestoneMarkerEvent(milestoneID: "ml_2", num: 63, kind: .userInput,
                                          title: "Dan asked for missions", body: "Make the work readable.",
                                          missionID: "ms_1", missionNum: 61, missionTitle: "Missions & milestones", by: .agent)
        assertVariants(of: MilestoneCard(marker: marker, onOpen: {}).frame(width: 360).padding(), named: "milestone-card")
        let notice = MissionMarkerEvent(missionID: "ms_1", num: 61, title: "Missions & milestones", action: .closed, by: .user)
        assertVariants(of: MissionNotice(marker: notice, onOpen: {}).frame(width: 360).padding(), named: "mission-notice")
    }
}
