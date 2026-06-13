import XCTest
@testable import MatronEvents

final class SessionMetaEventTests: XCTestCase {
    func test_parses_full() throws {
        let evt = try XCTUnwrap(SessionMetaEvent.parse(content: [
            "session_id": "abc",
            "model": "claude-sonnet-4-7",
            "workdir": "~/my-app",
            "started_at": 1745000000000.0,
        ]))
        XCTAssertEqual(evt.sessionID, "abc")
        XCTAssertEqual(evt.model, "claude-sonnet-4-7")
        XCTAssertEqual(evt.workdir, "~/my-app")
        XCTAssertEqual(evt.startedAt.timeIntervalSince1970, 1745000000.0)
    }

    func test_parses_integerStartedAt_fromRealJSON() throws {
        // See ToolCallEventTests.test_parses_integerTimestamps_fromRealJSON
        // — pins the JSONSerialization NSNumber → `as? Double` bridge for
        // integer ms timestamps (the bridge's wire shape).
        let json = #"{"session_id": "abc", "started_at": 1745000000000}"#
        let content = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(json.data(using: .utf8))) as? [String: Any]
        )
        let evt = try XCTUnwrap(SessionMetaEvent.parse(content: content))
        XCTAssertEqual(evt.startedAt.timeIntervalSince1970, 1745000000.0)
    }

    func test_parses_partial() throws {
        // Older bots emit only the required fields; newer fields
        // gracefully default to nil rather than failing the event.
        let evt = try XCTUnwrap(SessionMetaEvent.parse(content: [
            "session_id": "abc",
            "started_at": 1745000000000.0,
        ]))
        XCTAssertEqual(evt.sessionID, "abc")
        XCTAssertNil(evt.model)
        XCTAssertNil(evt.workdir)
    }

    func test_returnsNil_whenSessionIDMissing() {
        XCTAssertNil(SessionMetaEvent.parse(content: [
            "started_at": 1745000000000.0,
        ]))
    }

    func test_returnsNil_whenStartedAtMissing() {
        XCTAssertNil(SessionMetaEvent.parse(content: [
            "session_id": "abc",
        ]))
    }

    func test_returnsNil_whenStartedAtIsNotANumber() {
        // String form of a valid timestamp is still malformed —
        // bridge bug, surface as a parse failure not a coerce.
        XCTAssertNil(SessionMetaEvent.parse(content: [
            "session_id": "abc",
            "started_at": "1745000000000",
        ]))
    }

    func test_ignoresUnknownFields() throws {
        // A bot adding an unknown key shouldn't break the parse —
        // forward-compat is important since session_meta is a state
        // event that rooms can hold for a long time.
        let evt = try XCTUnwrap(SessionMetaEvent.parse(content: [
            "session_id": "abc",
            "started_at": 1745000000000.0,
            "future_field": "ignored",
        ]))
        XCTAssertEqual(evt.sessionID, "abc")
    }
}
