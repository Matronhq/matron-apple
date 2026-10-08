import XCTest
@testable import MatronJournal

/// Per-box defaults for new sessions (journal "Box defaults"): the two wire
/// shapes they arrive in, the live frame, and the agent-clears-model rule.
final class BoxDefaultsTests: XCTestCase {
    func test_decodesTheRosterShape() {
        XCTAssertEqual(BoxDefaults.decodeRoster(["agent": "codex", "model": "gpt-5.1-codex", "effort": "high"]),
                       BoxDefaults(agent: "codex", model: "gpt-5.1-codex", effort: "high"))
        XCTAssertEqual(BoxDefaults.decodeRoster(["agent": NSNull(), "model": NSNull(), "effort": NSNull()]),
                       BoxDefaults())
        // Missing and empty are "not set", like `/defaults`.
        XCTAssertEqual(BoxDefaults.decodeRoster(["agent": "claude", "model": ""]), BoxDefaults(agent: "claude"))
        // A non-string rejects the whole block, so a malformed row never
        // half-applies.
        XCTAssertNil(BoxDefaults.decodeRoster(["agent": 1, "model": "opus"]))
    }

    func test_decodesTheStateShape() {
        let state: [String: Any] = ["device_id": NSNumber(value: 9), "default_agent": "claude",
                                    "default_model": "opus", "default_effort": NSNull()]
        XCTAssertEqual(BoxDefaults.decodeState(state), BoxDefaults(agent: "claude", model: "opus"))
        XCTAssertNil(BoxDefaults.decodeState(["default_agent": true]))
    }

    func test_changingTheAgentClearsTheModelButKeepsTheEffort() {
        let claude = BoxDefaults(agent: "claude", model: "opus", effort: "high")
        // Mirrors the journal: an `opus` default means nothing on a Codex box.
        XCTAssertEqual(claude.applying(.agent, "codex"), BoxDefaults(agent: "codex", model: nil, effort: "high"))
        XCTAssertEqual(claude.applying(.agent, "claude"), claude, "the same agent is not a change")
        XCTAssertEqual(claude.applying(.model, "sonnet"), BoxDefaults(agent: "claude", model: "sonnet", effort: "high"))
        XCTAssertEqual(claude.applying(.effort, nil), BoxDefaults(agent: "claude", model: "opus", effort: nil))
    }

    func test_picksApplyInOrder() {
        let claude = BoxDefaults(agent: "claude", model: "opus", effort: "high")
        // One PUT with a new agent and its model: the model survives.
        XCTAssertEqual(claude.applying([.init(.agent, "codex"), .init(.model, "gpt-5.1-codex")]),
                       BoxDefaults(agent: "codex", model: "gpt-5.1-codex", effort: "high"))
        XCTAssertEqual(claude.applying([]), claude)
    }

    func test_liveFrame() {
        XCTAssertEqual(
            ServerFrame.decode(#"{"kind":"box_defaults","device_id":9,"default_agent":"codex","default_model":null,"default_effort":"xhigh"}"#),
            .boxDefaults(BoxDefaultsUpdate(deviceID: 9, defaults: BoxDefaults(agent: "codex", effort: "xhigh"))))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"box_defaults","default_agent":"codex"}"#),
                     "a frame naming no box has nowhere to land")
        XCTAssertNil(ServerFrame.decode(#"{"kind":"box_defaults","device_id":9,"default_agent":5}"#))
    }
}
