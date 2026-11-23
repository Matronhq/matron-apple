import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectsSnapshotTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    static let utc = TimeZone(identifier: "UTC")!

    static func row(_ num: Int, _ title: String, activity: MissionActivity, status: String?, needsYou: Int = 0,
                    age: TimeInterval) -> MissionRowModel {
        MissionRowModel(mission: Mission(id: "ms_\(num)", num: num, title: title, originConvoID: "c1",
                                         lastMilestone: MissionLastMilestone(num: num + 1, title: "Search page merged",
                                                                             kind: .progress, createdAt: ago(86_400)),
                                         status: status),
                        activity: activity, needsYouCount: needsYou, lastActivity: ago(age))
    }

    // MARK: Pure

    func testStatusHeadingNeverSaysNowAgoOrDateAgo() {
        XCTAssertEqual(ProjectsFormat.statusHeading(updatedAt: nil, now: Self.now), "STATUS")
        XCTAssertEqual(ProjectsFormat.statusHeading(updatedAt: Self.ago(30), now: Self.now), "STATUS · just now")
        XCTAssertEqual(ProjectsFormat.statusHeading(updatedAt: Self.ago(1_200), now: Self.now), "STATUS · 20m ago")
        let old = ProjectsFormat.statusHeading(updatedAt: Self.ago(8 * 86_400), now: Self.now)
        XCTAssertTrue(old.hasPrefix("STATUS · on "), old)
        XCTAssertFalse(old.hasSuffix(" ago"), old)
    }

    /// Review M5: an empty or whitespace close summary never leaves a blank line.
    func testClosedMissionLineFallsBackWhenTheSummaryIsBlank() {
        func closed(_ summary: String?) -> Mission {
            Mission(id: "ms_1", num: 1, state: .closed, title: "T", closeSummary: summary, originConvoID: "c1")
        }
        let label = MissionGlyph.label(.closed)
        XCTAssertEqual(ProjectsFormat.closedMissionLine(closed(nil)), label)
        XCTAssertEqual(ProjectsFormat.closedMissionLine(closed("")), label)
        XCTAssertEqual(ProjectsFormat.closedMissionLine(closed("  \n \t")), label)
        XCTAssertEqual(ProjectsFormat.closedMissionLine(closed("Shipped.\nBoth apps.")), "Shipped. Both apps.")
    }

    func testNoStatusAndMissionLines() {
        XCTAssertEqual(ProjectsFormat.noStatusLine(latest: nil, now: Self.now), "No written status yet")
        XCTAssertEqual(ProjectsFormat.noStatusLine(
            latest: MissionLastMilestone(num: 1, title: "Guide draft final", kind: .progress, createdAt: Self.ago(3 * 3_600)),
            now: Self.now), "No written status yet — latest: “Guide draft final” (3h ago)")
        let noStatus = Self.row(2172, "Move the old pages", activity: .idle, status: nil, age: 86_400).mission
        XCTAssertEqual(ProjectsFormat.missionLine(noStatus, now: Self.now),
                       "No status · last milestone 1d ago: “Search page merged”")
        let multi = Self.row(1, "T", activity: .idle, status: "Line one.\nLine two.", age: 60).mission
        XCTAssertEqual(ProjectsFormat.missionLine(multi, now: Self.now), "Line one. Line two.")
    }

    func testLinkWording() {
        let d29 = Date(timeIntervalSince1970: 1_759_104_000) // 29 Sep 2025 00:00 UTC
        let d30 = d29.addingTimeInterval(86_400)
        XCTAssertEqual(ProjectsFormat.shortDate(d29, timeZone: Self.utc), "29 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: nil, how: "origin", timeZone: Self.utc),
                       "since 29 Sep (started this mission)")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: nil, how: "joined", timeZone: Self.utc), "joined 29 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: d30, how: "joined", timeZone: Self.utc), "29 Sep → 30 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: nil, endedAt: nil, how: nil, timeZone: Self.utc), "")
        let mission = Mission(id: "ms_1", num: 1, title: "M", originConvoID: "c1")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, isCurrent: true, joinedAt: d29),
                                                 timeZone: Self.utc), "Current · since 29 Sep")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, joinedAt: d30),
                                                 timeZone: Self.utc), "Also on · joined 30 Sep")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, isActive: false, joinedAt: d29,
                                                                         endedAt: d30), timeZone: Self.utc), "29 Sep → 30 Sep")
    }

    func testSessionsByBoxAndConversationSummary() {
        XCTAssertEqual(ProjectsFormat.boxCounts(ProjectPageSections.boxCounts([], fallback: ["box-a": 1, "slate": 2, "aspen": 1])),
                       "slate 2 · aspen 1 · box-a 1")
        let groups = MissionConversationGroups(conversations: [
            MissionConversation(id: "c1", title: "a", box: nil, state: "running", subchatCount: 6),
            MissionConversation(id: "c2", title: "b", box: nil, state: "done", endedAt: Self.ago(60)),
        ], missionState: .open)
        XCTAssertEqual(ProjectsFormat.conversationsSummary(groups), "1 on it now · 1 earlier · 6 sub-chats folded")
    }

    func testConversationSummaryCountsRooms() {
        let groups = MissionConversationGroups(conversations: [
            MissionConversation(id: "c1", title: "a", box: nil, state: "running"),
        ], missionState: .open, rooms: [
            MissionRoom(id: "r1", title: "r", sessionState: "waiting", lastActivity: nil, participantConvoIDs: ["c1"]),
            MissionRoom(id: "r2", title: "r", sessionState: "waiting", lastActivity: nil, participantConvoIDs: ["c1"]),
        ])
        XCTAssertEqual(ProjectsFormat.conversationsSummary(groups), "1 on it now · 2 rooms")
        XCTAssertEqual(MissionsDashboardFormat.rooms(1), "+1 room")
        XCTAssertEqual(MissionsDashboardFormat.rooms(3), "+3 rooms")
    }

    /// Review I1/M6: VoiceOver hears a room row's state and age, and the
    /// participants this device has no tag for.
    func testRoomRowAccessibilityLabel() {
        let tag = SessionTagInputs(boxLetter: "B", boxName: "box-2", sessionShort: "f3")
        XCTAssertEqual(SessionTagText.participantsLabel([tag], missing: 1), "box-2, f3 and 1 more")
        XCTAssertEqual(SessionTagText.participantsLabel([], missing: 2), "2 participants")
        XCTAssertNil(SessionTagText.participantsLabel([], missing: 0))
        XCTAssertEqual(MissionsDashboardFormat.roomAccessibilityLabel(
            state: .running, participants: SessionTagText.participantsLabel([tag], missing: 1),
            title: "PR review", age: "5m ago"), "Running, box-2, f3 and 1 more, PR review, 5m ago")
    }

    func testLinkedMissionChipOpensItsMission() {
        var opened: String?
        let chip = LinkedMissionChip(linked: .movedTo(MissionOtherLink(id: "ms_2174", num: 2174, title: "Docs site analytics"))) {
            opened = "ms_2174"
        }
        chip.action()
        XCTAssertEqual(opened, "ms_2174")
        XCTAssertEqual(LinkedMissionChip.accessibilityText(.alsoOn(MissionOtherLink(id: "ms_1", num: 47, title: "Docs"))),
                       "also on mission 47, Docs")
    }

    // MARK: Snapshots

    func testLinkedMissionChips() {
        let chips = VStack(alignment: .leading, spacing: 8) {
            LinkedMissionChip(linked: .alsoOn(MissionOtherLink(id: "ms_2171", num: 2171, title: "Docs search")), action: {})
            LinkedMissionChip(linked: .movedTo(MissionOtherLink(id: "ms_2174", num: 2174, title: "Docs site analytics")), action: {})
        }
        assertVariants(of: chips.padding(), named: "linked-mission-chips")
    }

    func testMissionRows() {
        let rows = VStack(spacing: 0) {
            MissionRowView(row: Self.row(2190, "Translate the docs: status page + email + chat alerts", activity: .running,
                                         status: "The change is open; waiting on tests and review, then the merge.", age: 240),
                           now: Self.now)
            Divider()
            MissionRowView(row: Self.row(2191, "Design review feedback for Bob", activity: .waiting,
                                         status: "Pages 4–41 done; waiting on you to dictate the rest.", needsYou: 1, age: 300),
                           now: Self.now)
            Divider()
            MissionRowView(row: Self.row(2172, "Move the old pages across: list and report", activity: .idle,
                                         status: nil, age: 86_400), now: Self.now)
        }
        assertVariants(of: rows.frame(width: 720).padding(), named: "mission-rows")
    }
}
