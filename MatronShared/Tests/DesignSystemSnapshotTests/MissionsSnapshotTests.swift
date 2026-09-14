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
    }

    /// The close confirmation's title, on the symbol the user actually
    /// sees rendered (moved off the view model's dead `closeConfirmation`
    /// property, MINOR-2).
    func testConfirmationTitleCountsOpenItems() {
        XCTAssertEqual(MissionDetailView.confirmationTitle(openItems: 0), "Close this mission?")
        XCTAssertEqual(MissionDetailView.confirmationTitle(openItems: 1), "Close with 1 item still open?")
        XCTAssertEqual(MissionDetailView.confirmationTitle(openItems: 2), "Close with 2 items still open?")
    }

    func testListModelEmptyState() {
        let empty = MissionsListView.Model(open: [], closed: [], isSupported: true, isRefreshing: false)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(MissionsListView.Model(open: [mission], closed: [], isSupported: true, isRefreshing: false).isEmpty)
    }

    // MARK: Snapshots

    func testMissionRow() {
        assertVariants(of: MissionRowView(mission: mission).frame(width: 380).padding(), named: "mission-row")
    }

    func testMissionsList() {
        let model = MissionsListView.Model(
            open: [mission],
            closed: [Mission(id: "ms_0", num: 55, state: .closed, title: "Items tracker",
                             // Declaration order (Task 1): closeSummary /
                             // closedBy / closedOverOpenItems come BEFORE
                             // originConvoID.
                             closeSummary: "Shipped.", closedBy: .agent, originConvoID: "c0",
                             closedAt: Date(timeIntervalSince1970: 1_600_000_000))],
            isSupported: true, isRefreshing: false)
        assertVariants(of: MissionsListView(model: model, onSelect: { _ in }, onRefresh: {})
            .frame(width: 380, height: 420), named: "missions-list")
    }

    func testMissionsListUnsupported() {
        let model = MissionsListView.Model(open: [], closed: [], isSupported: false, isRefreshing: false)
        assertVariants(of: MissionsListView(model: model, onSelect: { _ in }, onRefresh: {})
            .frame(width: 380, height: 260), named: "missions-list-unsupported")
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
