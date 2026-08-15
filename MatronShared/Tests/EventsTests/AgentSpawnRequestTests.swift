import XCTest
@testable import MatronEvents

final class AgentSpawnRequestTests: XCTestCase {
    /// The exact payload the journal mints (matron-journal src/ws.js, the
    /// spawn_request park path). Like the agent-chat card it carries no
    /// `description`/`options`, so the generic permission-request rendering
    /// produced an anonymous "Permission request" whose Allow/Deny answered
    /// over `prompt_reply` — the wrong channel — and the ask expired 24h
    /// later. This fixture existing is the regression pin for that bug.
    private let spawnPayload: [String: Any] = [
        "kind": "agent_spawn",
        "request_id": "spawn-1",
        "from_device_id": NSNumber(value: 4),
        "from_name": "dan-mac",
        "from_convo_id": "69abc",
        "from_convo_title": "69 text carry and fitting parity",
        "target_device_id": NSNumber(value: 9),
        "target_name": "dev-2",
        "workdir": "~/yearbook-app",
        "task": "run the failing spec and report",
        "topic": "ci triage",
    ]

    func test_parsesSpawnAsk() throws {
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: spawnPayload))
        XCTAssertEqual(request.requestID, "spawn-1")
        XCTAssertEqual(request.fromDeviceID, 4)
        XCTAssertEqual(request.fromName, "dan-mac")
        XCTAssertEqual(request.targetDeviceID, 9)
        XCTAssertEqual(request.targetName, "dev-2")
        XCTAssertEqual(request.workdir, "~/yearbook-app")
        XCTAssertEqual(request.task, "run the failing spec and report")
        XCTAssertEqual(request.topic, "ci triage")
        XCTAssertEqual(request.headline, "dan-mac wants to start a new session on dev-2.")
        XCTAssertEqual(request.fromLabel, "dan-mac — 69 text carry and fitting parity",
                       "the session title already opens with the convo id's short form, so no stutter")
    }

    func test_labelsDegradeToDeviceIDs_neverToAnonymous() throws {
        var payload = spawnPayload
        payload.removeValue(forKey: "from_name")
        payload.removeValue(forKey: "target_name")
        payload.removeValue(forKey: "from_convo_id")
        payload.removeValue(forKey: "from_convo_title")
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: payload))
        XCTAssertEqual(request.headline, "Device 4 wants to start a new session on Device 9.")
        XCTAssertEqual(request.fromLabel, "Device 4")
    }

    func test_emptyTopicCollapsesToNil() throws {
        var payload = spawnPayload
        payload["topic"] = "  "
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: payload))
        XCTAssertNil(request.topic, "the journal defaults an absent topic to \"\" — the card must not draw an empty row")
    }

    func test_rejectsAnyOtherPermissionRequest() {
        XCTAssertNil(AgentSpawnRequest.parse(payload: [
            "description": "Allow writing to /etc?", "options": ["Allow", "Deny"],
        ]), "a non-spawn permission request must fall through to the other renderings")
        XCTAssertNil(AgentSpawnRequest.parse(payload: [
            "kind": "agent_chat", "request": "invite", "room_id": "r",
            "from_device_id": NSNumber(value: 1), "target_device_id": NSNumber(value: 2),
        ]), "a chat consent card is the chat parser's, not this one's")
    }

    /// `request_id` is the answer key; the rest are what the user is
    /// actually consenting to. A card missing any of them must not draw
    /// buttons that would 400 — or approve something the user couldn't see.
    func test_rejectsPayloadsItCouldNotAnswer() {
        for missing in ["request_id", "from_device_id", "target_device_id", "workdir", "task"] {
            var payload = spawnPayload
            payload.removeValue(forKey: missing)
            XCTAssertNil(AgentSpawnRequest.parse(payload: payload), "missing \(missing)")
        }
        var emptyID = spawnPayload
        emptyID["request_id"] = ""
        XCTAssertNil(AgentSpawnRequest.parse(payload: emptyID), "empty request_id")
    }

    /// Whitespace-only required fields are as unanswerable as missing ones —
    /// the card must fall back, not render blank rows over live buttons.
    func test_rejectsWhitespaceOnlyRequiredFields() {
        for field in ["request_id", "workdir", "task"] {
            var payload = spawnPayload
            payload[field] = "  \n "
            XCTAssertNil(AgentSpawnRequest.parse(payload: payload), "whitespace-only \(field)")
        }
    }

    /// JSON booleans and fractionals bridge to NSNumber too — `true` must
    /// not become device id 1, and 9.5 must not truncate to device 9.
    func test_rejectsNonIntegralDeviceIDs() {
        for field in ["from_device_id", "target_device_id"] {
            var boolPayload = spawnPayload
            boolPayload[field] = true
            XCTAssertNil(AgentSpawnRequest.parse(payload: boolPayload), "boolean \(field)")
            var fractionalPayload = spawnPayload
            fractionalPayload[field] = 9.5
            XCTAssertNil(AgentSpawnRequest.parse(payload: fractionalPayload), "fractional \(field)")
        }
    }
}
