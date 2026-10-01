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

final class JournalTimelineMapperRoutineTests: XCTestCase {
    private func event(_ payload: [String: Any], sender: String = "journal") -> JournalEvent {
        JournalEvent(seq: 12, convoID: "coord", ts: Date(timeIntervalSince1970: 1), sender: sender,
                     type: JournalEventType.routine, payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    private func marker(_ payload: [String: Any]) throws -> RoutineMarkerEvent {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(
            from: event(payload), ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .routineMarker(let eventID, let marker) = item.kind else {
            XCTFail("expected .routineMarker, got \(item.kind)")
            throw CocoaError(.coderValueNotFound)
        }
        XCTAssertEqual(eventID, "12")
        return marker
    }

    private func notice(_ payload: [String: Any]) throws -> String { try marker(payload).text }

    /// A `routine` marker is its own visible row — never "[unsupported event:
    /// routine]", and never `.stateChange`, which both apps hide.
    func testFiredRoutineBecomesANotice() throws {
        XCTAssertEqual(try notice(["routine_id": "rt_1", "name": "daily-sweep", "action": "fired",
                                   "outcome": "applied now", "next_at": 1_759_381_500_000]),
                       "Routine fired · daily-sweep")
        XCTAssertEqual(try notice(["routine_id": "rt_1", "name": "context-over", "action": "fired",
                                   "outcome": "applied deferred", "next_at": NSNull()]),
                       "Routine fired · context-over — queued for the next idle point")
    }

    /// A fire that never reached the Coordinator is the one case nothing else
    /// in the transcript shows — the reason must be on the row.
    func testUndeliveredFireSaysWhy() throws {
        XCTAssertEqual(try notice(["routine_id": "rt_1", "name": "daily-sweep", "action": "fired",
                                   "outcome": "failed agent_unreachable"]),
                       "Routine not delivered · daily-sweep — agent_unreachable")
        XCTAssertEqual(try notice(["routine_id": "rt_1", "name": "daily-sweep", "action": "fired",
                                   "outcome": "no_coordinator"]),
                       "Routine not delivered · daily-sweep — no Coordinator box")
        XCTAssertEqual(try notice(["routine_id": "rt_1", "name": "daily-sweep", "action": "fired",
                                   "outcome": "missed"]),
                       "Routine missed · daily-sweep")
    }

    func testSavedAndDeletedRoutines() throws {
        XCTAssertEqual(try notice(["routine_id": "rt_2", "name": "deploy-window", "action": "saved",
                                   "by": "user", "created": true]),
                       "You created a routine · deploy-window")
        XCTAssertEqual(try notice(["routine_id": "rt_2", "name": "deploy-window", "action": "saved",
                                   "by": "agent", "created": false]),
                       "Coordinator updated a routine · deploy-window")
        XCTAssertEqual(try notice(["routine_id": "rt_2", "name": "deploy-window", "action": "deleted", "by": "user"]),
                       "You deleted a routine · deploy-window")
    }

    func testOnlyUndeliveredFiresAreFlagged() throws {
        XCTAssertFalse(try marker(["routine_id": "rt_1", "name": "a", "action": "fired", "outcome": "applied now"]).isUndelivered)
        XCTAssertFalse(try marker(["routine_id": "rt_1", "name": "a", "action": "saved", "by": "user"]).isUndelivered)
        XCTAssertTrue(try marker(["routine_id": "rt_1", "name": "a", "action": "fired", "outcome": "failed timeout"]).isUndelivered)
        XCTAssertTrue(try marker(["routine_id": "rt_1", "name": "a", "action": "fired", "outcome": "missed"]).isUndelivered)
    }

    func testMalformedRoutineEventIsSkipped() {
        for payload: [String: Any] in [["action": "fired", "name": "x"],
                                       ["routine_id": "rt_1", "name": "x", "action": "exploded"],
                                       ["routine_id": "rt_1", "action": "fired"]] {
            XCTAssertNil(JournalTimelineMapper.timelineItem(from: event(payload), ownSender: "user:dan",
                                                            serverURL: URL(string: "https://j")!), "\(payload)")
        }
    }
}
