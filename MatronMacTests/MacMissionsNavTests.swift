import XCTest
import SwiftUI
@testable import MatronMac

@MainActor
final class MacMissionsNavTests: XCTestCase {
    func testNavOrderIsMissionsDecisionsConversations() {
        XCTAssertEqual(MacNav.allCases, [.missions, .decisions, .conversations])
        XCTAssertEqual(MacNav.missions.title, "Missions")
        XCTAssertEqual(MacNav.missions.symbol, "flag.checkered")
    }

    /// The badge map generalises the old `decisionsCount`: two entries can
    /// carry a count at once, and zero hides.
    func testNavColumnBadgeMapCoversBothEntries() {
        let badges: [MacNav: Int] = [.decisions: 3, .missions: 1, .conversations: 0]
        XCTAssertEqual(MacNavColumn.badgeCount(badges, for: .decisions), 3)
        XCTAssertEqual(MacNavColumn.badgeCount(badges, for: .missions), 1)
        XCTAssertNil(MacNavColumn.badgeCount(badges, for: .conversations), "zero hides the badge")
    }

    func testNavColumnSnapshotEntriesRespectTheSupportedFilter() {
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: true), MacNav.allCases)
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: false),
                       [.decisions, .conversations],
                       "an old journal hides the Missions entry entirely")
    }

    /// A sidebar pick carries no originating conversation, so any
    /// "back to the conversation" affordance left by an earlier title-tap
    /// open must not survive it (Bugbot: `pickMission` used to leave
    /// `missionBackConvoID` untouched).
    func testMissionBackConvoIDClearsOnSidebarPickAndCarriesOnTitleTap() {
        XCTAssertNil(MacChatListView.missionBackConvoID(for: .sidebarPick))
        XCTAssertEqual(MacChatListView.missionBackConvoID(for: .titleTap(fromConvoID: "c1")), "c1")
        XCTAssertNil(MacChatListView.missionBackConvoID(for: .titleTap(fromConvoID: nil)))
    }

    /// Spec §3b: a search hit, notification tap, milestone jump or "Open
    /// conversation" into the Coordinator's conversation opens the panel;
    /// every other conversation opens in the detail.
    func testConversationTarget_opensTheCoordinatorInThePanel() {
        XCTAssertEqual(MacChatListView.conversationTarget("c-coord", coordinatorConvoID: "c-coord"), .panel)
        XCTAssertEqual(MacChatListView.conversationTarget("c-other", coordinatorConvoID: "c-coord"), .detail)
        XCTAssertEqual(MacChatListView.conversationTarget("c-coord", coordinatorConvoID: nil), .detail)
        XCTAssertEqual(MacChatListView.conversationTarget("c-coord", coordinatorConvoID: ""), .detail)
    }

    /// Fix round 1: Back/Forward onto a place that shows the Coordinator's
    /// conversation opens the panel; the detail keeps the place (so the
    /// history is not rewritten) but draws "Select a chat", never a second
    /// copy of the Coordinator.
    func testRestoringTheCoordinatorsConversation_opensThePanel_andNotTheDetail() {
        XCTAssertTrue(MacChatListView.restoreOpensPanel("c-coord", coordinatorConvoID: "c-coord"))
        XCTAssertFalse(MacChatListView.restoreOpensPanel("c-other", coordinatorConvoID: "c-coord"))
        XCTAssertFalse(MacChatListView.restoreOpensPanel(nil, coordinatorConvoID: "c-coord"))
        XCTAssertFalse(MacChatListView.detailShowsChat("c-coord", coordinatorConvoID: "c-coord", isStaleRestore: false))
        XCTAssertTrue(MacChatListView.detailShowsChat("c-other", coordinatorConvoID: "c-coord", isStaleRestore: false))
        XCTAssertFalse(MacChatListView.detailShowsChat("c-other", coordinatorConvoID: "c-coord", isStaleRestore: true))
        XCTAssertFalse(MacChatListView.detailShowsChat(nil, coordinatorConvoID: nil, isStaleRestore: false))
    }

    /// Fix round 1: making the OPEN conversation the Coordinator moves it
    /// out of the detail and into the panel.
    func testCoordinatorBecomingTheSelectedChat_clearsTheSelection_andOpensThePanel() {
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c1"),
                       .init(selection: nil, opensPanel: true))
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c2"),
                       .init(selection: "c1", opensPanel: false))
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: nil, coordinatorConvoID: "c2"),
                       .init(selection: nil, opensPanel: false))
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: nil),
                       .init(selection: "c1", opensPanel: false))
    }
}
