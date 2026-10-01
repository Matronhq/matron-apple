import XCTest
@testable import MatronJournal
import MatronModels

final class RosterAPITests: XCTestCase {
    /// Same stub wiring as `MissionsAPITests.makeStubbedAPI` —
    /// `ItemsStubURLProtocol` lives in `ItemsAPITests.swift`, same target.
    private func makeStubbedAPI(status: Int, body: [String: Any]) -> (JournalAPI, ItemsStubURLProtocol.Type) {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")
        return (api, ItemsStubURLProtocol.self)
    }

    /// A null, empty or whitespace
    /// summary is "no summary", and a row without an id is skipped.
    func testDecodeKeepsOnlyNonEmptySummaries() throws {
        let obj: [String: Any] = ["agents": [], "conversations": [
            ["id": "c1", "title": "Parser", "session_state": "running", "summary": "  Reviewing the parser\n"],
            ["id": "c2", "summary": NSNull()],
            ["id": "c3", "summary": "   "],
            ["summary": "orphan"],
            ["id": "c4"],
        ]]
        XCTAssertEqual(try JournalAPI.decodeRoster(obj).summaries, ["c1": "Reviewing the parser"])
    }

    /// `status` is the persisted session header: model, context gauge and
    /// stall each parse on their own; a malformed part is dropped, not the
    /// row; a block with nothing usable is no header at all.
    func testDecodeReadsTheSessionHeader() throws {
        let obj: [String: Any] = ["agents": [], "conversations": [
            ["id": "c1", "status": ["reported_at": 1, "model": "opus",
                                    "context": ["tokens": 265_000, "window": 1_000_000, "pct": 27]]],
            ["id": "c2", "status": ["model": "sonnet", "context": ["tokens": 5, "window": 0, "pct": 1],
                                    "stall": ["kind": "usage_limit", "resets_at": "2026-10-01T15:00:00.000Z"]]],
            ["id": "c3", "status": ["reported_at": 1, "limits": ["as_of": 1, "lines": []]]],
            ["id": "c4", "summary": "no header"],
        ]]
        let headers = try JournalAPI.decodeRoster(obj).headers
        XCTAssertEqual(headers["c1"], SessionHeader(model: "opus",
                                                    context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)))
        XCTAssertEqual(headers["c2"]?.model, "sonnet")
        XCTAssertNil(headers["c2"]?.context, "a zero window is malformed")
        XCTAssertEqual(headers["c2"]?.isStalled, true)
        XCTAssertEqual(headers["c2"]?.stallResetsAt, Date(timeIntervalSince1970: 1_790_866_800))
        XCTAssertNil(headers["c3"], "meters alone are not a session header")
        XCTAssertNil(headers["c4"])
    }

    /// A stall is the session's state only until its reset passes.
    func testStallEndsAtItsReset() {
        let reset = Date(timeIntervalSince1970: 1_000)
        let header = SessionHeader(isStalled: true, stallResetsAt: reset)
        XCTAssertTrue(header.isStalled(at: reset.addingTimeInterval(-1)))
        XCTAssertFalse(header.isStalled(at: reset))
        XCTAssertTrue(SessionHeader(isStalled: true).isStalled(at: .distantFuture), "no known reset: stalled")
        XCTAssertFalse(SessionHeader(model: "opus").isStalled(at: .distantPast))
    }

    /// A response with no `conversations` array is malformed, not "nobody
    /// has a summary" — it throws so the dashboard keeps its last map.
    func testDecodeWithoutAConversationsArrayThrows() {
        XCTAssertThrowsError(try JournalAPI.decodeRoster(["agents": []]))
    }

    func testRosterGetsSlashRoster() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "agents": [], "conversations": [["id": "c1", "summary": "Shipping"]],
        ])
        let roster = try await api.roster()
        XCTAssertEqual(roster.summaries, ["c1": "Shipping"])
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/roster")
    }
}
