import XCTest
@testable import MatronJournal

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

    /// Only `id` and `summary` are read; a null, empty or whitespace
    /// summary is "no summary", and a row without an id is skipped.
    func testDecodeKeepsOnlyNonEmptySummaries() throws {
        let obj: [String: Any] = ["agents": [], "conversations": [
            ["id": "c1", "title": "Parser", "session_state": "running", "summary": "  Reviewing the parser\n"],
            ["id": "c2", "summary": NSNull()],
            ["id": "c3", "summary": "   "],
            ["summary": "orphan"],
            ["id": "c4"],
        ]]
        XCTAssertEqual(try JournalAPI.decodeRosterSummaries(obj), ["c1": "Reviewing the parser"])
    }

    /// A response with no `conversations` array is malformed, not "nobody
    /// has a summary" — it throws so the dashboard keeps its last map.
    func testDecodeWithoutAConversationsArrayThrows() {
        XCTAssertThrowsError(try JournalAPI.decodeRosterSummaries(["agents": []]))
    }

    func testRosterGetsSlashRoster() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "agents": [], "conversations": [["id": "c1", "summary": "Shipping"]],
        ])
        let summaries = try await api.roster()
        XCTAssertEqual(summaries, ["c1": "Shipping"])
        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/roster")
    }
}
