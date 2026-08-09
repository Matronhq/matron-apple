import XCTest
@testable import MatronEvents

final class AgentChatRequestTests: XCTestCase {
    /// The exact payload the journal mints (matron-journal src/ws.js, the
    /// agent_invite park path). Note what it does NOT carry: `description`
    /// and `options`, the two keys the generic permission-request rendering
    /// reads — which is why that rendering produced the literal string
    /// "Permission request" with buttons that answered on the wrong channel.
    private let invitePayload: [String: Any] = [
        "kind": "agent_chat",
        "request": "invite",
        "room_id": "room-1",
        "from_device_id": NSNumber(value: 4),
        "from_name": "dev-2",
        "target_device_id": NSNumber(value: 7),
        "topic": "ci triage",
        "justification": "need the failing build log",
    ]

    func test_parsesInvite() throws {
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: invitePayload))
        XCTAssertEqual(request.ask, .invite)
        XCTAssertEqual(request.roomID, "room-1")
        XCTAssertEqual(request.fromDeviceID, 4)
        XCTAssertEqual(request.fromName, "dev-2")
        XCTAssertEqual(request.targetDeviceID, 7)
        XCTAssertEqual(request.topic, "ci triage")
        XCTAssertEqual(request.justification, "need the failing build log")
        XCTAssertEqual(request.headline, "dev-2 wants to start a chat with another agent.")
    }

    func test_parsesJoin_whichSelfTargets() throws {
        var payload = invitePayload
        payload["request"] = "join"
        payload["target_device_id"] = NSNumber(value: 4)
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: payload))
        XCTAssertEqual(request.ask, .join)
        XCTAssertEqual(request.targetDeviceID, 4, "a join request's target is the joiner itself")
        XCTAssertEqual(request.headline, "dev-2 wants to join this chat.")
    }

    func test_rejectsAnyOtherPermissionRequest() {
        XCTAssertNil(AgentChatRequest.parse(payload: [
            "description": "Allow writing to /etc?", "options": ["Allow", "Deny"],
        ]), "a non-agent-chat permission request must fall through to the generic rendering")
    }

    /// Each of these is a field `POST /agent-chat/answer` needs, or would be
    /// answered as. A card missing one cannot be resolved, so it must not
    /// draw buttons that would 400 — it falls back instead.
    func test_rejectsPayloadsItCouldNotAnswer() {
        for missing in ["room_id", "request", "from_device_id", "target_device_id"] {
            var payload = invitePayload
            payload.removeValue(forKey: missing)
            XCTAssertNil(AgentChatRequest.parse(payload: payload), "missing \(missing)")
        }
        var unknownAsk = invitePayload
        unknownAsk["request"] = "conscript"
        XCTAssertNil(AgentChatRequest.parse(payload: unknownAsk))
        var blankRoom = invitePayload
        blankRoom["room_id"] = ""
        XCTAssertNil(AgentChatRequest.parse(payload: blankRoom))
    }

    /// The journal defaults an absent topic/justification to `""` rather than
    /// omitting the key, so "absent" and "empty" arrive identically — both
    /// have to collapse to nil or the card draws an empty quote block.
    func test_emptyTopicAndJustificationBecomeNil() throws {
        var payload = invitePayload
        payload["topic"] = ""
        payload["justification"] = "   "
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: payload))
        XCTAssertNil(request.topic)
        XCTAssertNil(request.justification)
    }

    func test_fallsBackToDeviceIDWhenTheRequesterHasNoName() throws {
        var payload = invitePayload
        payload["from_name"] = ""
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: payload))
        XCTAssertEqual(request.requesterLabel, "Device 4")
        XCTAssertEqual(request.headline, "Device 4 wants to start a chat with another agent.")
    }

    /// Real JSON, not hand-built NSNumbers: the device ids arrive as integers
    /// through JSONSerialization, and reading them with `as? Int64` (rather
    /// than via NSNumber) silently fails on that bridge.
    func test_parsesFromRealJSON() throws {
        let json = #"""
        {"kind":"agent_chat","request":"invite","room_id":"r","from_device_id":4,
         "from_name":"dev-2","target_device_id":7,"topic":"","justification":"why"}
        """#
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: payload))
        XCTAssertEqual(request.fromDeviceID, 4)
        XCTAssertEqual(request.targetDeviceID, 7)
        XCTAssertNil(request.topic)
        XCTAssertEqual(request.justification, "why")
    }
}
