import XCTest
import MatronModels
@testable import MatronJournal

/// `GET /search/all`: the Search page's query over everything, and the
/// text helpers its rows use.
final class GlobalSearchAPITests: XCTestCase {
    /// Same stub wiring as `LookupAPITests` — `ItemsStubURLProtocol` lives
    /// in `ItemsAPITests.swift`, same target.
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

    func testSearchAllAsksForEveryKindAndTheChats() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["results": [Any](), "chats": [Any]()])
        let found = try await api.searchAll("proxy timeout", limit: 40)
        XCTAssertEqual(found, GlobalSearchResults(results: [], chats: []))

        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/search/all")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [
            URLQueryItem(name: "q", value: "proxy timeout"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "kinds", value: "item,mission,project,memory"),
            URLQueryItem(name: "chats", value: "1"),
        ])
    }

    func testDecodesEachKnownKindAndDropsTheRest() {
        let decoded = JournalAPI.decodeSearchAll([
            "results": [
                ["kind": "item", "id": "it_1", "num": 12, "name": NSNull(), "title": "Pick the proxy timeout",
                 "state": "open", "mission_num": 20, "why": "exact", "field": "title", "snippet": NSNull()],
                ["kind": "mission", "id": "ms_1", "num": 20, "title": "Proxy hardening", "why": "words",
                 "snippet": "**proxy** reload"],
                ["kind": "memory", "id": "proxy-timeouts", "num": NSNull(), "name": "proxy-timeouts",
                 "title": "Keep it at 120s", "why": "similar"],
                ["kind": "elsewhere", "id": "x", "title": "x"],
                ["kind": "item", "title": "no id"],
                ["kind": "project", "id": "pj_1"],
                "not a row",
            ] as [Any],
            "semantic": "ready",
        ])
        XCTAssertEqual(decoded.results, [
            GlobalSearchResult(kind: .item, id: "it_1", num: 12, title: "Pick the proxy timeout", state: "open",
                               missionNum: 20, why: "exact", field: "title"),
            GlobalSearchResult(kind: .mission, id: "ms_1", num: 20, title: "Proxy hardening", why: "words",
                               snippet: "**proxy** reload"),
            GlobalSearchResult(kind: .memory, id: "proxy-timeouts", name: "proxy-timeouts", title: "Keep it at 120s",
                               why: "similar"),
        ])
        XCTAssertEqual(decoded.chats, [])
    }

    func testDecodesTheChats() {
        let decoded = JournalAPI.decodeSearchAll([
            "chats": [
                ["convo_id": "c1", "title": "Proxy work", "count": 3, "exact": true, "live": false,
                 "top": ["seq": 41, "ts": 1_790_000_000_000, "sender": "agent:box-a", "excerpt": "the **proxy** timeout"]],
                ["convo_id": "c2", "title": "No top"],
                ["title": "No id", "top": ["seq": 1]],
            ] as [Any],
        ])
        XCTAssertEqual(decoded.results, [])
        XCTAssertEqual(decoded.chats, [
            GlobalSearchChat(convoID: "c1", title: "Proxy work", count: 3, isExact: true, isLive: false,
                             top: .init(seq: 41, ts: Date(timeIntervalSince1970: 1_790_000_000),
                                        sender: "agent:box-a", excerpt: "the **proxy** timeout")),
        ])
        XCTAssertEqual(decoded.chats.first?.label, "Proxy work · 3 messages")
    }

    func testAMissingArrayIsNoRows() {
        XCTAssertEqual(JournalAPI.decodeSearchAll(["error": "x"]), GlobalSearchResults(results: [], chats: []))
    }

    // MARK: - Row text

    func testTheSnippetLosesTheTitleItRepeats() {
        XCTAssertEqual(
            GlobalSearchText.snippetBeyondTitle("**Postgres** 16 **Postgres** 16 migration Move the app to **Postgres** 16.",
                                                heads: ["Postgres 16", "Postgres 16 migration"]),
            "Move the app to **Postgres** 16.")
        XCTAssertEqual(GlobalSearchText.snippetBeyondTitle("…restarted **proxy**", heads: [nil, "Proxy"]),
                       "…restarted **proxy**", "a snippet that does not lead with the title keeps everything")
        XCTAssertNil(GlobalSearchText.snippetBeyondTitle("**Proxy** hardening", heads: [nil, "Proxy hardening"]))
        XCTAssertNil(GlobalSearchText.snippetBeyondTitle("Proxy hardening …", heads: ["Proxy hardening"]))
    }

    func testOnlyTheLooseTiersAreLabelled() {
        XCTAssertNil(GlobalSearchText.whyLabel("exact"))
        XCTAssertNil(GlobalSearchText.whyLabel("number"))
        XCTAssertNil(GlobalSearchText.whyLabel("words"))
        XCTAssertEqual(GlobalSearchText.whyLabel("stemmed"), "similar words")
        XCTAssertEqual(GlobalSearchText.whyLabel("similar"), "similar meaning")
        XCTAssertEqual(GlobalSearchText.whyLabel("some_words"), "some words")
    }

    func testRowsSayWhatTheyAreAndWhereTheyLead() {
        let item = GlobalSearchResult(kind: .item, id: "it_1", num: 12, title: "Proxy timeout", state: "open",
                                      snippet: "**Proxy** timeout")
        XCTAssertEqual(item.label, "#12 Proxy timeout")
        XCTAssertEqual(item.detail, "open", "the snippet only repeated the title")
        XCTAssertEqual(item.target, .number(12))

        let memory = GlobalSearchResult(kind: .memory, id: "proxy-timeouts", name: "proxy-timeouts",
                                        title: "Keep it at 120s", why: "similar")
        XCTAssertEqual(memory.label, "proxy-timeouts")
        XCTAssertEqual(memory.detail, "Keep it at 120s")
        XCTAssertEqual(memory.whyLabel, "similar meaning")
        XCTAssertEqual(memory.target, .memory(name: "proxy-timeouts"))

        XCTAssertNil(GlobalSearchResult(kind: .project, id: "pj_1", title: "No number").target)
    }

    func testMarkedRunsSplitAtTheMarkers() {
        let runs = GlobalSearchText.markedRuns("the **proxy** timeout")
        XCTAssertEqual(runs.map { $0.text }, ["the ", "proxy", " timeout"])
        XCTAssertEqual(runs.map { $0.isMatch }, [false, true, false])
    }
}
