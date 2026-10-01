import XCTest
import SwiftUI
import MatronDesignSystem
@testable import MatronMac

@MainActor
final class MacProjectsNavTests: XCTestCase {
    func testTheEntryIsCalledProjects() {
        XCTAssertEqual(MacNav.missions.title, "Projects")
        XCTAssertEqual(MacNav.missions.symbol, ProjectGlyph.symbol)
        XCTAssertEqual(ChatCommands.navShortcuts[1].title, "Projects", "⌘2 keeps its place and takes the name")
    }

    func testAProjectPageIsItsOwnPlace() {
        let place = MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: nil,
                                          selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil,
                                          selectedProjectID: "pj_1")
        XCTAssertEqual(place, MacPlace(detail: .project(id: "pj_1")))
        XCTAssertEqual(place.nav, .missions)
        XCTAssertNil(place.pane)
        XCTAssertNil(place.displayedConversationID)
    }

    func testAMissionWinsOverTheProjectItWasOpenedFrom() {
        let place = MacChatListView.place(nav: .missions, selectedSummaryID: nil, selectedMissionID: "ms_1",
                                          selectedDecisionID: nil, paneRoute: nil, coordinatorConvoID: nil,
                                          selectedProjectID: "pj_1")
        XCTAssertEqual(place, MacPlace(detail: .mission(id: "ms_1")))
    }

    func testChoosingProjectsLandsOnTheHomeFromAProjectPage() {
        let landing = MacChatListView.selectingNavEntry(.missions, selectedMissionID: nil, selectedProjectID: "pj_1",
                                                        missionBackConvoID: nil)
        XCTAssertEqual(landing, .init(nav: .missions, selectedMissionID: nil, missionBackConvoID: nil, selectedProjectID: nil))
        let elsewhere = MacChatListView.selectingNavEntry(.decisions, selectedMissionID: nil, selectedProjectID: "pj_1",
                                                          missionBackConvoID: nil)
        XCTAssertEqual(elsewhere.selectedProjectID, "pj_1", "another entry leaves it for Back and ⌘2")
    }

    func testBackRestoresAProjectPage() {
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .project(id: "pj_1")))
        history.visit(MacPlace(detail: .mission(id: "ms_1")))
        XCTAssertEqual(history.goBack(), MacPlace(detail: .project(id: "pj_1")))
    }

    /// R11: Back to the Projects home must clear the project, or `place()`
    /// re-derives `.project` from the leftover `selectedProjectID` and Back
    /// looks stuck on the project page.
    func testRestoringTheHomeClearsTheProject() {
        XCTAssertNil(MacChatListView.projectAfterRestoring(.mission(id: nil), current: "pj_1"))
        XCTAssertEqual(MacChatListView.projectAfterRestoring(.mission(id: "ms_1"), current: "pj_1"), "pj_1")
    }
}
