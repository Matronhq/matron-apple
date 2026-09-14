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

    /// A sidebar pick carries no originating conversation, so any
    /// "back to the conversation" affordance left by an earlier title-tap
    /// open must not survive it (Bugbot: `pickMission` used to leave
    /// `missionBackConvoID` untouched).
    func testMissionBackConvoIDClearsOnSidebarPickAndCarriesOnTitleTap() {
        XCTAssertNil(MacChatListView.missionBackConvoID(for: .sidebarPick))
        XCTAssertEqual(MacChatListView.missionBackConvoID(for: .titleTap(fromConvoID: "c1")), "c1")
        XCTAssertNil(MacChatListView.missionBackConvoID(for: .titleTap(fromConvoID: nil)))
    }

    /// A title tap from the coordinator chat, a mission page's back
    /// button, a milestone jump into the coordinator room, and "Open
    /// conversation" for that room all fold through `showConversation` —
    /// pinning `navForShowingConversation` covers all four call paths
    /// Bugbot listed at once (the coordinator entry must stay selected,
    /// mirroring iOS's `AppShellNavigation.openChat`).
    func testNavForShowingConversationKeepsTheCoordinatorEntryForItsOwnRoom() {
        XCTAssertEqual(MacChatListView.navForShowingConversation("c-coord", coordinatorConvoID: "c-coord"), .coordinator)
        XCTAssertEqual(MacChatListView.navForShowingConversation("c-other", coordinatorConvoID: "c-coord"), .conversations)
        XCTAssertEqual(MacChatListView.navForShowingConversation("c-coord", coordinatorConvoID: nil), .conversations)
        XCTAssertEqual(MacChatListView.navForShowingConversation("c-coord", coordinatorConvoID: ""), .conversations,
                       "an empty stored value is no coordinator, same as CoordinatorTabView.root(for:)")
    }
}
