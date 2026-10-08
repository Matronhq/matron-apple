import XCTest
import MatronModels
@testable import MatronEvents

final class ConsentDecisionEventTests: XCTestCase {
    /// The chat form names its ask by room and target device — the same key
    /// the card and the consent link carry.
    func testAChatDecisionNamesItsAsk() throws {
        let d = try XCTUnwrap(ConsentDecisionEvent.parse(payload: [
            "kind": "chat", "room_id": "room-1", "target_device_id": 7, "decision": "approve",
            "by": "coordinator", "convo_id": "coord", "reason": "follows the box rules",
        ]))
        XCTAssertEqual(d.askID, "room-1/7")
        XCTAssertEqual(d.askID, AgentChatRequest(ask: .invite, roomID: "room-1", fromDeviceID: 4, fromName: "a",
                                                 targetDeviceID: 7, topic: nil, justification: nil).askID)
        XCTAssertEqual(d.text, "Coordinator approved the chat request — follows the box rules")
    }

    func testASpawnDecisionNamesItsRequest() throws {
        let d = try XCTUnwrap(ConsentDecisionEvent.parse(payload: [
            "kind": "spawn", "request_id": "sp_1", "decision": "decline",
        ]))
        XCTAssertEqual(d.askID, "sp_1")
    }

    func testADecisionWithoutItsAskStillParses() throws {
        let d = try XCTUnwrap(ConsentDecisionEvent.parse(payload: ["kind": "chat", "decision": "decline"]))
        XCTAssertNil(d.askID)
    }
}
