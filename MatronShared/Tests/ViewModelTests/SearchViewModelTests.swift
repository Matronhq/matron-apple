import XCTest
@testable import MatronViewModels
import MatronSearch
import MatronChat
import MatronModels

/// Fake `SearchService` for view-model tests. `hits` is set via init / `setHits`
/// rather than direct property assignment — an actor's isolated stored property
/// can't be mutated from outside, even with `await`.
actor FakeSearchService: SearchService {
    private var hits: [SearchHit]

    init(hits: [SearchHit] = []) { self.hits = hits }
    func setHits(_ newHits: [SearchHit]) { hits = newHits }

    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
    func remove(eventID: String) async throws {}
    func query(_ text: String, limit: Int) async throws -> [SearchHit] { hits }
    func wipe() async throws {}
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
    func backfillComplete(roomID: String) async throws -> Bool { true }
    func eventCount(roomID: String) async throws -> Int { 0 }
    func contains(eventID: String) async throws -> Bool { false }
}

final class SearchViewModelTests: XCTestCase {
    @MainActor
    func test_query_populatesResults() async {
        let fakeSearch = FakeSearchService(hits: [
            SearchHit(id: "$1", roomID: "!r:s", sender: "@a:s", timestamp: Date(), snippet: "<mark>hello</mark> world")
        ])
        let vm = SearchViewModel(search: fakeSearch, allChats: [])
        vm.query = "hello"
        await vm.search()
        XCTAssertEqual(vm.messageHits.count, 1)
    }

    @MainActor
    func test_chatHits_filterByTitleOrBotName() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let chats = [
            ChatSummary(id: "!1:s", title: "Auth bug", bot: claude, lastActivity: nil, unreadCount: 0),
            ChatSummary(id: "!2:s", title: "Refactor", bot: claude, lastActivity: nil, unreadCount: 0),
        ]
        let vm = SearchViewModel(search: FakeSearchService(), allChats: chats)
        vm.query = "auth"
        XCTAssertEqual(vm.chatHits.map(\.id), ["!1:s"])
    }

    @MainActor
    func test_chatTitle_resolvesViaAllChats() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let chats = [
            ChatSummary(id: "!a:s", title: "Auth bug", bot: claude, lastActivity: nil, unreadCount: 0),
            ChatSummary(id: "!b:s", title: "Refactor", bot: claude, lastActivity: nil, unreadCount: 0),
        ]
        let vm = SearchViewModel(search: FakeSearchService(), allChats: chats)
        XCTAssertEqual(vm.chatTitle(for: "!a:s"), "Auth bug")
        XCTAssertEqual(vm.chatTitle(for: "!b:s"), "Refactor")
        XCTAssertEqual(vm.chatTitle(for: "!unknown:s"), "!unknown:s", "falls back to room ID when not found")
    }

    @MainActor
    func test_emptyState_whenBackfillInProgress_showsIndexingMessage() async {
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [])
        vm.query = "anything"
        vm.applyBackfillProgress(AggregateBackfillProgress(roomsCompleted: 3, roomsTotal: 10))
        await vm.search()
        XCTAssertEqual(vm.emptyResultsMessage, "Indexing chats… (3 of 10 rooms)")
    }

    @MainActor
    func test_emptyState_whenBackfillComplete_showsNoResults() async {
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [])
        vm.query = "anything"
        vm.applyBackfillProgress(AggregateBackfillProgress(roomsCompleted: 10, roomsTotal: 10))
        await vm.search()
        XCTAssertEqual(vm.emptyResultsMessage, "No results.")
    }
}
