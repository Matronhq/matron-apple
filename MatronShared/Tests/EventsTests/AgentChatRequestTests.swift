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
        XCTAssertEqual(request.headline, "dev-2 wants to start a chat with Device 7.",
                       "no to_name in this fixture, so the far end degrades to its id — never \"another agent\"")
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
        XCTAssertEqual(request.headline, "Device 4 wants to start a chat with Device 7.")
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

    // MARK: - Who is asking whom

    private var namedPayload: [String: Any] {
        var p = invitePayload
        p["to_name"] = "dev-9"
        p["from_convo_id"] = "68385da9-615e-4894-812c-fc73ee02947d"
        p["from_convo_title"] = "Syncing bridge services"
        p["to_convo_id"] = "69d925ab-58ce-49f9-a1a0-f5137d14487b"
        p["to_convo_title"] = "2:69 text carry and fitting parity"
        return p
    }

    func test_namesBothEnds() throws {
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: namedPayload))
        XCTAssertEqual(request.headline, "dev-2 wants to start a chat with dev-9.")
        XCTAssertEqual(request.fromLabel, "dev-2 — 68 · Syncing bridge services")
        XCTAssertEqual(request.toLabel, "dev-9 — 2:69 text carry and fitting parity")
    }

    /// The bridge seeds session titles as "<box>:<first two of the id> words",
    /// which is exactly what the conversation list shows. Prefixing our own
    /// short id there would print the same two characters twice.
    func test_sessionLabelDoesNotRepeatAShortIDTheTitleAlreadyCarries() {
        XCTAssertEqual(
            AgentChatRequest.sessionLabel(id: "69d925ab-58ce", title: "2:69 text carry and fitting parity"),
            "2:69 text carry and fitting parity")
        XCTAssertEqual(
            AgentChatRequest.sessionLabel(id: "830cd6e4-f709", title: "3:83 There’s a chat on your box"),
            "3:83 There’s a chat on your box")
        // A bare short id with no box prefix counts as carrying it too.
        XCTAssertEqual(AgentChatRequest.sessionLabel(id: "abcdef", title: "ab already prefixed"),
                       "ab already prefixed")
    }

    /// Rooms and sub-chats are titled by hand and carry no prefix — this is
    /// the case the id is sent for.
    func test_sessionLabelPrefixesATitleThatLacksTheShortID() {
        XCTAssertEqual(
            AgentChatRequest.sessionLabel(id: "e8e4b719-1809", title: "dan-mac ↔ dev-2 — routing check"),
            "e8 · dan-mac ↔ dev-2 — routing check")
        // A near-miss must NOT count as carrying it: "e8x" is a different id.
        XCTAssertEqual(AgentChatRequest.sessionLabel(id: "e8e4b719", title: "e8x nearly"),
                       "e8 · e8x nearly")
    }

    func test_sessionLabelHandlesMissingHalves() {
        XCTAssertNil(AgentChatRequest.sessionLabel(id: "", title: ""))
        XCTAssertEqual(AgentChatRequest.sessionLabel(id: "", title: "titled but unidentified"),
                       "titled but unidentified")
        XCTAssertEqual(AgentChatRequest.sessionLabel(id: "abcdef", title: "   "), "ab",
                       "an untitled session still identifies itself")
    }

    /// A journal that predates these fields must still produce an answerable,
    /// non-anonymous card — the far end falls back to its device id.
    func test_degradesWithoutTheDisplayFields() throws {
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: invitePayload))
        XCTAssertEqual(request.fromLabel, "dev-2")
        XCTAssertEqual(request.toLabel, "Device 7")
    }

    /// On a join the target IS the joiner, so `to_name` names the room's
    /// owner instead. Labelling the far end from targetDeviceID would say the
    /// requester is asking themselves.
    func test_joinNamesTheOwnerNotTheSelfTarget() throws {
        var payload = namedPayload
        payload["request"] = "join"
        payload["target_device_id"] = NSNumber(value: 4)
        payload["to_name"] = "dev-a"
        payload["to_convo_id"] = ""
        payload["to_convo_title"] = ""
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: payload))
        XCTAssertEqual(request.targetLabel, "dev-a")
        XCTAssertEqual(request.toLabel, "dev-a")
    }

    func test_joinWithoutAnOwnerNameSaysSoRatherThanNamingTheJoiner() throws {
        var payload = invitePayload
        payload["request"] = "join"
        payload["target_device_id"] = NSNumber(value: 4)
        let request = try XCTUnwrap(AgentChatRequest.parse(payload: payload))
        XCTAssertEqual(request.targetLabel, "the room's owner",
                       "never \"Device 4\" — that is the joiner, not who is being asked")
    }
}
