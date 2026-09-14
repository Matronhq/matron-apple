import XCTest
import MatronEvents
import MatronJournal
import MatronModels
@testable import MatronChat

final class JournalTimelineMapperMissionsTests: XCTestCase {
    private func event(_ type: String, _ payload: [String: Any], seq: Int64 = 4210) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: 1), sender: "agent:dev-2",
                     type: type, payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testMilestoneEventBecomesACardKeyedByItsOwnSeq() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.milestone, [
                "milestone_id": "ml_2", "num": 63, "kind": "user_input", "title": "Dan asked",
                "body": "the brief", "mission_id": "ms_1", "mission_num": 61,
                "mission_title": "Missions & milestones", "by": "agent",
            ]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .milestoneMarker(let eventID, let marker) = item.kind else {
            return XCTFail("expected .milestoneMarker, got \(item.kind)")
        }
        // The event's OWN seq is the anchor, so it is also the row id the
        // transcript scrolls to.
        XCTAssertEqual(eventID, "4210")
        XCTAssertEqual(item.id, "4210")
        XCTAssertEqual(marker.num, 63)
        XCTAssertEqual(marker.missionLabel, "Missions & milestones")
    }

    func testMilestoneEventWithoutMissionTitleStillRenders() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.milestone, [
                "milestone_id": "ml_2", "num": 63, "kind": "progress", "title": "landed",
                "mission_id": "ms_1", "mission_num": 61, "by": "agent",
            ]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .milestoneMarker(_, let marker) = item.kind else { return XCTFail("expected .milestoneMarker") }
        XCTAssertEqual(marker.missionLabel, "#61")
    }

    func testMissionEventBecomesANotice() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.mission, [
                "mission_id": "ms_1", "num": 61, "title": "Missions & milestones",
                "action": "closed", "by": "user", "open_item_nums": [64, 70],
            ]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .missionMarker(_, let marker) = item.kind else { return XCTFail("expected .missionMarker") }
        XCTAssertEqual(marker.action, .closed)
        XCTAssertEqual(marker.openItemNums, [64, 70])
    }

    func testMalformedMarkersAreSkippedRatherThanRenderedAsUnknown() {
        XCTAssertNil(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.milestone, ["milestone_id": "ml_2"]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        XCTAssertNil(JournalTimelineMapper.timelineItem(
            from: event(JournalEventType.mission, ["mission_id": "ms_1", "num": 61, "action": "exploded", "by": "agent"]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
    }
}
