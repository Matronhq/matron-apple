import XCTest
@testable import MatronEvents

final class ToolCallEventTests: XCTestCase {
    func test_parses_runningEvent() throws {
        let content: [String: Any] = [
            "tool": "Read",
            "args": ["file_path": "/etc/hosts"],
            "status": "running",
            "started_at": 1745000000000.0,
        ]
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        XCTAssertEqual(evt.tool, "Read")
        XCTAssertEqual(evt.status, .running)
        XCTAssertNil(evt.resultText)
        XCTAssertNil(evt.endedAt)
        XCTAssertFalse(evt.resultTruncated)
        XCTAssertEqual(evt.startedAt.timeIntervalSince1970, 1745000000.0)
    }

    func test_parses_integerTimestamps_fromRealJSON() throws {
        // Wire-realistic shape (bugbot PR #6 pass-3 finding, rebutted):
        // the bridge emits integer ms timestamps, and the production
        // path runs them through JSONSerialization → NSNumber, whose
        // `as? Double` bridge succeeds for any losslessly-representable
        // integer (every real timestamp; only ~2^53+ magnitudes fail).
        // Swift-literal dictionaries in the other tests skip that
        // bridge, so this pins the NSNumber path explicitly.
        let json = #"{"tool": "Read", "args": {}, "status": "ok", "result": "x", "started_at": 1745000000000, "ended_at": 1745000001000}"#
        let content = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any]
        )
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        XCTAssertEqual(evt.startedAt.timeIntervalSince1970, 1745000000.0)
        XCTAssertEqual(evt.endedAt?.timeIntervalSince1970, 1745000001.0)
    }

    func test_parses_okWithStringResult() throws {
        let content: [String: Any] = [
            "tool": "Read",
            "args": ["file_path": "/etc/hosts"],
            "status": "ok",
            "result": "127.0.0.1 localhost",
            "started_at": 1745000000000.0,
            "ended_at": 1745000001000.0,
        ]
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        XCTAssertEqual(evt.status, .ok)
        XCTAssertEqual(evt.resultText, "127.0.0.1 localhost")
        XCTAssertEqual(evt.endedAt?.timeIntervalSince1970, 1745000001.0)
    }

    func test_parses_errorWithStructuredObjectResult() throws {
        // Bridge can emit a `result` that's an object, not a string.
        // Parser pretty-prints with sorted keys so the resulting
        // string is stable for snapshot rendering.
        let content: [String: Any] = [
            "tool": "Bash",
            "args": ["command": "ls /nope"],
            "status": "error",
            "result": ["exit_code": 2, "stderr": "no such file"],
            "result_truncated": true,
            "started_at": 1745000000000.0,
            "ended_at": 1745000002000.0,
        ]
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        XCTAssertEqual(evt.status, .error)
        XCTAssertTrue(evt.resultTruncated)
        // Sorted keys → `exit_code` before `stderr` deterministically.
        // No slashes here so the escape behaviour doesn't matter.
        let expected = """
        {
          "exit_code" : 2,
          "stderr" : "no such file"
        }
        """
        XCTAssertEqual(evt.resultText, expected)
    }

    func test_argsJSON_isSortedAndPrettyPrinted() throws {
        // Args dict sorts deterministically so the rendered card
        // doesn't shuffle key order across re-renders. Same
        // .sortedKeys + .prettyPrinted contract the parser uses for
        // structured results. NB: JSONSerialization escapes forward
        // slashes (`/` → `\/`) — that's a Foundation quirk, not a
        // bug, and the rendered `Text` shows the slash unescaped
        // because SwiftUI processes the backslash.
        let content: [String: Any] = [
            "tool": "Edit",
            "args": [
                "new_string": "Y",
                "file_path": "/x",
                "old_string": "X",
            ],
            "status": "running",
            "started_at": 1745000000000.0,
        ]
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        let expected = """
        {
          "file_path" : "\\/x",
          "new_string" : "Y",
          "old_string" : "X"
        }
        """
        XCTAssertEqual(evt.argsJSON, expected)
    }

    func test_argsJSON_emptyDict_whenArgsMissing() throws {
        // `args` missing entirely (e.g. nullary tool) → parser
        // defaults `argsAny = [:]`, JSONSerialization serialises
        // empty dict as `{\n\n}` (two-line literal). Pin that
        // behaviour so a future ToolCallCard renderer either matches
        // it (empty args section) or makes the explicit choice to
        // hide an empty body.
        let content: [String: Any] = [
            "tool": "Now",
            "status": "ok",
            "result": "2026-05-01T12:00:00Z",
            "started_at": 1745000000000.0,
            "ended_at": 1745000001000.0,
        ]
        let evt = try XCTUnwrap(ToolCallEvent.parse(content: content))
        XCTAssertEqual(evt.argsJSON, "{\n\n}")
    }

    func test_returnsNil_whenMissingRequiredFields() {
        // Just a `tool` — every other required field absent.
        XCTAssertNil(ToolCallEvent.parse(content: ["tool": "Read"]))
    }

    func test_returnsNil_whenStatusIsUnknownString() {
        // Unknown status string — parser treats it as malformed
        // rather than coercing. Future bridges shouldn't be able to
        // sneak a new status past the type system silently.
        let content: [String: Any] = [
            "tool": "Read",
            "args": [:],
            "status": "weird",
            "started_at": 1745000000000.0,
        ]
        XCTAssertNil(ToolCallEvent.parse(content: content))
    }

    func test_returnsNil_whenStartedAtIsString() {
        // `started_at` must be a number (milliseconds). A string is
        // a malformed event — graceful-degradation path.
        let content: [String: Any] = [
            "tool": "Read",
            "args": [:],
            "status": "running",
            "started_at": "1745000000000",
        ]
        XCTAssertNil(ToolCallEvent.parse(content: content))
    }

    func test_equatable_pinsAllFields() {
        // Sanity-check the auto-synthesised Equatable — a future
        // refactor that adds a stored property without updating the
        // synthesis would silently break == in surprising ways. Two
        // identical inits compare equal; one differing field doesn't.
        let a = ToolCallEvent(
            tool: "Read", argsJSON: "{}", status: .ok,
            resultText: "x", resultTruncated: false,
            startedAt: Date(timeIntervalSince1970: 1), endedAt: nil
        )
        let b = ToolCallEvent(
            tool: "Read", argsJSON: "{}", status: .ok,
            resultText: "x", resultTruncated: false,
            startedAt: Date(timeIntervalSince1970: 1), endedAt: nil
        )
        let c = ToolCallEvent(
            tool: "Read", argsJSON: "{}", status: .error,  // status differs
            resultText: "x", resultTruncated: false,
            startedAt: Date(timeIntervalSince1970: 1), endedAt: nil
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
