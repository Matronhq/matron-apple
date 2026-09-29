import XCTest
@testable import MatronMac

/// Spec 2026-09-28 §3.1: the Missions entry shows the dashboard full width.
@MainActor
final class MacMissionsDashboardNavTests: XCTestCase {
    func testMissionsCollapsesTheSidebarToTheNavColumnLikeTheCoordinator() {
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.missions))
        XCTAssertTrue(MacChatListView.showsNavColumnOnly(.coordinator))
        for nav in [MacNav.decisions, .conversations, .memories] {
            XCTAssertFalse(MacChatListView.showsNavColumnOnly(nav), "\(nav) keeps its list column")
        }
        let widths = MacChatListView.sidebarWidths(for: .missions)
        XCTAssertEqual(widths.min, MacNavColumn.width)
        XCTAssertEqual(widths.ideal, MacNavColumn.width)
        XCTAssertEqual(widths.max, MacNavColumn.width)
    }

    func testTheDashboardIsTheMissionsPlaceWithNoMission() {
        let place = MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: nil,
                                          selectedDecisionID: "it_1", paneRoute: .items(path: []),
                                          coordinatorConvoID: "c-coord")
        XCTAssertEqual(place, MacPlace(detail: .mission(id: nil)))
        XCTAssertTrue(MacChatListView.isRecordable(place, historyIsEmpty: true), "the dashboard is a place to go back to")
        XCTAssertNil(MacChatListView.detailChatID(nav: .missions, selectedSummaryID: "c1",
                                                  coordinatorConvoID: nil, isStaleRestore: false),
                     "the dashboard mounts no chat")
    }

    func testBackFromAMissionPageReturnsToTheDashboard() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .mission(id: nil)))
        history.visit(MacPlace(detail: .mission(id: "ms_1")))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .mission(id: nil)))
        XCTAssertEqual(history.goForward(), MacPlace(detail: .mission(id: "ms_1")))
    }

    /// A dashboard session tap goes through `showConversation`: the
    /// Coordinator's chat lands on its page, anything else under
    /// Conversations.
    func testASessionTapRoutesTheCoordinatorToItsPage() {
        XCTAssertEqual(MacChatListView.navForShowingConversation("c-coord", coordinatorConvoID: "c-coord"), .coordinator)
        XCTAssertEqual(MacChatListView.navForShowingConversation("c1", coordinatorConvoID: "c-coord"), .conversations)
    }

    // MARK: Choosing the Missions entry (review I1)

    /// A fresh entry from another nav entry lands on the dashboard, never
    /// on whichever mission page was read last.
    func testChoosingMissionsFromAnotherEntryLandsOnTheDashboard() {
        let landing = MacChatListView.selectingNavEntry(.missions, selectedMissionID: "ms_1", missionBackConvoID: nil)
        XCTAssertEqual(landing, .init(nav: .missions, selectedMissionID: nil, missionBackConvoID: nil))
    }

    /// Re-choosing Missions (a column click or ⌘2) while a mission page
    /// shows is the way back to the dashboard — even from a page opened
    /// from a conversation's title.
    func testReChoosingMissionsOnAMissionPageShowsTheDashboard() {
        let landing = MacChatListView.selectingNavEntry(.missions, selectedMissionID: "ms_1", missionBackConvoID: "c1")
        XCTAssertEqual(landing, .init(nav: .missions, selectedMissionID: nil, missionBackConvoID: nil))
        XCTAssertEqual(MacChatListView.place(nav: landing.nav, selectedSummaryID: "c1",
                                             selectedMissionID: landing.selectedMissionID,
                                             selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil),
                       MacPlace(detail: .mission(id: nil)))
    }

    /// Other entries leave the Missions state alone (it is off screen, and
    /// `navChanged` clears the back affordance on the way out).
    func testChoosingAnotherEntryLeavesTheMissionState() {
        for entry in [MacNav.coordinator, .conversations, .decisions, .memories] {
            let landing = MacChatListView.selectingNavEntry(entry, selectedMissionID: "ms_1", missionBackConvoID: "c1")
            XCTAssertEqual(landing, .init(nav: entry, selectedMissionID: "ms_1", missionBackConvoID: "c1"), "\(entry)")
        }
    }

    /// The entry choice does not reach into history: Back from the
    /// dashboard it lands on still steps to the mission page read before.
    func testBackFromAFreshDashboardEntryStillRestoresTheMissionPage() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .mission(id: "ms_1")))
        history.visit(MacPlace(detail: .conversation(id: "c1", pane: nil)))
        let landing = MacChatListView.selectingNavEntry(.missions, selectedMissionID: "ms_1", missionBackConvoID: nil)
        history.visit(MacChatListView.place(nav: landing.nav, selectedSummaryID: "c1",
                                            selectedMissionID: landing.selectedMissionID,
                                            selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil))
        XCTAssertEqual(history.current, MacPlace(detail: .mission(id: nil)))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .conversation(id: "c1", pane: nil)))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .mission(id: "ms_1")))
    }
}
