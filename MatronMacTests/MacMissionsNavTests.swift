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
}
