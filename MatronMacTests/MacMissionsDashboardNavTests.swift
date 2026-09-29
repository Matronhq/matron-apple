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
}
