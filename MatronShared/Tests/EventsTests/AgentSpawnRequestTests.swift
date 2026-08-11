import XCTest
@testable import MatronEvents

final class AgentSpawnRequestTests: XCTestCase {
    /// The exact payload the journal mints (matron-journal src/ws.js, the
    /// spawn_request park path). Note what it does NOT carry: `description`
    /// and `options`, the two keys the generic permission-request rendering
    /// reads — same trap the agent-chat card fell into.
    private let payload: [String: Any] = [
        "kind": "agent_spawn",
        "request_id": "spawn-1",
        "from_device_id": NSNumber(value: 4),
        "from_name": "dev-2",
        "from_convo_id": "68385da9-615e-4894-812c-fc73ee02947d",
        "from_convo_title": "Syncing bridge services",
        "target_device_id": NSNumber(value: 7),
        "target_name": "dev-6",
        "workdir": "/home/danbarker/matron-apple",
        "task": "Rebase the spawn branch and push",
        "topic": "spawn card wiring",
    ]

    func test_parsesTheCard() throws {
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: payload))
        XCTAssertEqual(request.requestID, "spawn-1")
        XCTAssertEqual(request.fromDeviceID, 4)
        XCTAssertEqual(request.fromName, "dev-2")
        XCTAssertEqual(request.targetDeviceID, 7)
        XCTAssertEqual(request.targetName, "dev-6")
        XCTAssertEqual(request.workdir, "/home/danbarker/matron-apple")
        XCTAssertEqual(request.task, "Rebase the spawn branch and push")
        XCTAssertEqual(request.topic, "spawn card wiring")
        XCTAssertEqual(request.headline, "spawn card wiring")
        XCTAssertEqual(request.fromLabel, "dev-2 — 68 · Syncing bridge services")
        XCTAssertEqual(request.targetLabel, "dev-6")
    }

    func test_rejectsAnyOtherPermissionRequest() {
        XCTAssertNil(AgentSpawnRequest.parse(payload: [
            "description": "Allow writing to /etc?", "options": ["Allow", "Deny"],
        ]), "a non-spawn permission request must fall through to the generic rendering")
        var chatCard = payload
        chatCard["kind"] = "agent_chat"
        XCTAssertNil(AgentSpawnRequest.parse(payload: chatCard),
                     "the agent-chat card has its own type — this parser must not claim it")
    }

    /// `request_id` is the whole answer key for `POST /agent-spawn/answer`,
    /// and the task is what the user is being asked to consent to. A card
    /// missing either cannot be answered (or cannot be described), so it must
    /// not draw buttons that would 400 — it falls back instead.
    func test_rejectsPayloadsItCouldNotAnswer() {
        for missing in ["request_id", "task"] {
            var incomplete = payload
            incomplete.removeValue(forKey: missing)
            XCTAssertNil(AgentSpawnRequest.parse(payload: incomplete), "missing \(missing)")
        }
        var blankID = payload
        blankID["request_id"] = ""
        XCTAssertNil(AgentSpawnRequest.parse(payload: blankID))
        var blankTask = payload
        blankTask["task"] = "   \n "
        XCTAssertNil(AgentSpawnRequest.parse(payload: blankTask),
                     "a whitespace-only task describes nothing to consent to")
    }

    /// The device ids are display-only here (unlike agent-chat, where they
    /// are half the answer key), so a journal that omits them still yields an
    /// answerable card.
    func test_stillAnswerableWithoutTheDisplayFields() throws {
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: [
            "kind": "agent_spawn", "request_id": "spawn-2",
            "task": "Run the suite",
        ]))
        XCTAssertEqual(request.requestID, "spawn-2")
        XCTAssertEqual(request.requesterLabel, "Device 0")
        XCTAssertEqual(request.fromLabel, "Device 0",
                       "no session named — the row degrades to the device alone")
        XCTAssertEqual(request.workdir, "")
    }

    /// The journal defaults an absent topic to `""` rather than omitting the
    /// key, so "absent" and "empty" arrive identically — both must collapse
    /// to nil or the headline renders blank.
    func test_emptyTopicBecomesNil_andTheTaskSuppliesTheHeadline() throws {
        var noTopic = payload
        noTopic["topic"] = ""
        noTopic["task"] = "Rebase the spawn branch\nthen push it\nand open a PR"
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: noTopic))
        XCTAssertNil(request.topic)
        XCTAssertEqual(request.headline, "Rebase the spawn branch",
                       "the first line of the task, not the whole prompt")
    }

    func test_emptyFromConvoTitleDoesNotProduceAnEmptySessionRow() throws {
        var unnamed = payload
        unnamed["from_convo_id"] = ""
        unnamed["from_convo_title"] = ""
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: unnamed))
        XCTAssertEqual(request.fromLabel, "dev-2")
    }

    func test_headlineElidesARunawayTask() throws {
        var runaway = payload
        runaway.removeValue(forKey: "topic")
        runaway["task"] = String(repeating: "a", count: 400)
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: runaway))
        XCTAssertEqual(request.headline.count, AgentSpawnRequest.headlineMaxChars + 1,
                       "capped, plus the ellipsis")
        XCTAssertTrue(request.headline.hasSuffix("…"))
        XCTAssertEqual(request.task.count, 400, "the task itself is never elided")
    }

    func test_fallsBackToDeviceIDsWhenTheJournalHasNoNames() throws {
        var unnamed = payload
        unnamed["from_name"] = ""
        unnamed["target_name"] = ""
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: unnamed))
        XCTAssertEqual(request.requesterLabel, "Device 4")
        XCTAssertEqual(request.targetLabel, "Device 7")
    }

    /// Real JSON, not hand-built NSNumbers: the device ids arrive as integers
    /// through JSONSerialization, and reading them with `as? Int64` (rather
    /// than via NSNumber) silently fails on that bridge.
    func test_parsesFromRealJSON() throws {
        let json = #"""
        {"kind":"agent_spawn","request_id":"spawn-3","from_device_id":4,
         "from_name":"dev-2","target_device_id":7,"target_name":"dev-6",
         "workdir":"/srv/app","task":"ship it","topic":""}
        """#
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let request = try XCTUnwrap(AgentSpawnRequest.parse(payload: decoded))
        XCTAssertEqual(request.fromDeviceID, 4)
        XCTAssertEqual(request.targetDeviceID, 7)
        XCTAssertNil(request.topic)
        XCTAssertEqual(request.headline, "ship it")
    }
}
