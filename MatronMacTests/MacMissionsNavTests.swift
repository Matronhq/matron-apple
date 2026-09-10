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

    /// The sidebar keeps the list width for Missions — only Coordinator
    /// collapses to the bare nav column.
    func testSidebarWidthForMissionsMatchesTheOtherLists() {
        let missions = MacChatListView.sidebarWidths(for: .missions)
        let decisions = MacChatListView.sidebarWidths(for: .decisions)
        XCTAssertEqual(missions.min, decisions.min)
        XCTAssertEqual(missions.ideal, decisions.ideal)
        XCTAssertEqual(missions.max, decisions.max)
        let coordinator = MacChatListView.sidebarWidths(for: .coordinator)
        XCTAssertEqual(coordinator.min, MacNavColumn.width)
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
}
