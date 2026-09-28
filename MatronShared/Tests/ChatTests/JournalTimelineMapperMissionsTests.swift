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

final class JournalTimelineMapperMemoryTests: XCTestCase {
    private func event(_ payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: 9, convoID: "c1", ts: Date(timeIntervalSince1970: 1), sender: "agent:bev",
                     type: JournalEventType.memory, payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    /// A `memory` marker is a quiet notice — never the unknown-event fallback.
    func testMemoryEventBecomesANotice() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(["memory_id": "me_1", "name": "avoid-eric", "type": "feedback",
                         "description": "Never start sessions on eric.", "action": "saved", "created": true, "by": "agent"]),
            ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .stateChange(let text) = item.kind else { return XCTFail("expected .stateChange, got \(item.kind)") }
        XCTAssertEqual(text, "🧠 Agent saved a memory · avoid-eric — Never start sessions on eric.")
    }

    func testMalformedMemoryEventIsSkipped() {
        XCTAssertNil(JournalTimelineMapper.timelineItem(from: event(["action": "saved"]),
                                                        ownSender: "user:dan", serverURL: URL(string: "https://j")!))
    }
}
