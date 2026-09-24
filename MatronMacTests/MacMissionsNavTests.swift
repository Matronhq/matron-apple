import XCTest
import SwiftUI
@testable import MatronMac

@MainActor
final class MacMissionsNavTests: XCTestCase {
    func testNavOrderIsCoordinatorMissionsDecisionsConversations() {
        XCTAssertEqual(MacNav.allCases, [.coordinator, .missions, .decisions, .conversations])
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
        XCTAssertNil(MacNavColumn.badgeCount(badges, for: .coordinator))
    }

    func testNavColumnSnapshotEntriesRespectTheSupportedFilter() {
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: true), MacNav.allCases)
        XCTAssertEqual(MacNavColumn.entries(missionsSupported: false),
                       [.coordinator, .decisions, .conversations],
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

    /// The Coordinator's conversation belongs to the Coordinator surfaces
    /// (page and panel, which share its view models); every other
    /// conversation opens in the Conversations detail.
    func testConversationTarget_keepsTheCoordinatorOnItsOwnSurfaces() {
        XCTAssertEqual(MacChatListView.conversationTarget("c-coord", coordinatorConvoID: "c-coord"), .coordinator)
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
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c1",
                                                                     onCoordinatorPage: false),
                       .init(selection: nil, opensPanel: true))
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: "c2",
                                                                     onCoordinatorPage: false),
                       .init(selection: "c1", opensPanel: false))
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: nil, coordinatorConvoID: "c2",
                                                                     onCoordinatorPage: false),
                       .init(selection: nil, opensPanel: false))
        XCTAssertEqual(MacChatListView.landingAfterCoordinatorChange(selected: "c1", coordinatorConvoID: nil,
                                                                     onCoordinatorPage: false),
                       .init(selection: "c1", opensPanel: false))
    }
}
