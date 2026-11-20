import XCTest
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import MatronMac

@MainActor
final class MacProjectsNavTests: XCTestCase {
    func testTheEntryIsCalledProjects() {
        XCTAssertEqual(MacNav.missions.title, "Projects")
        XCTAssertEqual(MacNav.missions.symbol, ProjectGlyph.symbol)
        XCTAssertEqual(ChatCommands.navShortcuts[1].title, "Projects", "⌘2 keeps its place and takes the name")
    }

    func testChoosingProjectsLandsOnTheTimelineFromAMissionPage() {
        let landing = MacChatListView.selectingNavEntry(.missions, selectedMissionID: "ms_1", missionBackConvoID: "c1")
        XCTAssertEqual(landing, .init(nav: .missions, selectedMissionID: nil, missionBackConvoID: nil))
        let elsewhere = MacChatListView.selectingNavEntry(.decisions, selectedMissionID: "ms_1", missionBackConvoID: "c1")
        XCTAssertEqual(elsewhere.selectedMissionID, "ms_1", "another entry leaves it for Back and ⌘2")
    }

    /// A project page's merge redirect (A merged into C) must not trap Back
    /// on A: the shell replaces the current place with C's page, and the
    /// `visit` that follows from its own `onChange(of: currentPlace)` is a
    /// no-op, so Back goes where the user was before A.
    func testRedirectReplacesCurrentSoBackSkipsThePreMergeProject() {
        let week = TimelinePlace.week("2026-11-02")
        let history = MacNavigationHistory()
        history.visit(MacPlace(detail: .mission(id: "ms_1")))
        history.visit(MacPlace(detail: .timeline(place: week, story: "pj_a")))
        history.replaceCurrent(MacPlace(detail: .timeline(place: week, story: "pj_c")))
        history.visit(MacPlace(detail: .timeline(place: week, story: "pj_c")))
        XCTAssertEqual(history.current, MacPlace(detail: .timeline(place: week, story: "pj_c")))
        XCTAssertEqual(history.back, [MacPlace(detail: .mission(id: "ms_1"))])
        XCTAssertEqual(history.goBack(), MacPlace(detail: .mission(id: "ms_1")))
    }
}
