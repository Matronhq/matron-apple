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
    func backfillOldestEventID(roomID: String) async throws -> String? { nil }
    func resetBackfill() async throws {}
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

    /// The session short is VISIBLE in the row (`b5` rendered as `Y:b5`), so
    /// it must find its chat even though `SessionTag.splitTitle` peeled it
    /// out of the stored title (ported from matron-android#46).
    @MainActor
    func test_chatHits_matchTheVisibleSessionTag() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let tagged = ChatSummary(id: "!1:s", title: "Auth bug", bot: claude,
                                 lastActivity: nil, unreadCount: 0,
                                 boxName: "dev-y", sessionShort: "b5", boxShort: "Y")
        let other = ChatSummary(id: "!2:s", title: "Refactor", bot: claude,
                                lastActivity: nil, unreadCount: 0,
                                boxName: "dev-z", sessionShort: "c7", boxShort: "Z")
        let room = ChatSummary(id: "!3:s", title: "mac ↔ dev-z", bot: claude,
                               lastActivity: nil, unreadCount: 0,
                               sessionShort: "ab",
                               roomBoxNames: ["dev-y", "dev-z"], roomBoxShorts: ["Y", "Z"])
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [tagged, other, room])

        vm.query = "b5"
        XCTAssertEqual(vm.chatHits.map(\.id), ["!1:s"], "the bare short finds its chat")

        vm.query = "y:b5"
        XCTAssertEqual(vm.chatHits.map(\.id), ["!1:s"], "the displayed letter:short form matches too")

        vm.query = "Y:B5"
        XCTAssertEqual(vm.chatHits.map(\.id), ["!1:s"], "tag matching is case-insensitive")

        vm.query = "y↔z:ab"
        XCTAssertEqual(vm.chatHits.map(\.id), ["!3:s"], "the displayed room tag matches too")

        vm.query = "y"
        XCTAssertEqual(vm.chatHits.map(\.id), [],
                       "a bare box letter matches nothing — it would light up every chat on the box")

        vm.query = "d4"
        XCTAssertEqual(vm.chatHits.map(\.id), [], "an unrelated short matches nothing")
    }

    /// Per-box letter overrides (Settings → Devices → Tag Character, #154)
    /// change what the row renders, and `ChatSummary.boxShort` carries the
    /// overridden letter — so search matches the letter the user actually
    /// sees, not the derived default.
    @MainActor
    func test_chatHits_matchTheOverriddenBoxLetter() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        // dev-y would derive `Y`; the user overrode it to `Q`.
        let letters = SessionTag.boxLetters(for: [1: "dev-y", 2: "dev-z"], overrides: [1: "Q"])
        let chat = ChatSummary(id: "!1:s", title: "Auth bug", bot: claude,
                               lastActivity: nil, unreadCount: 0,
                               boxName: "dev-y", sessionShort: "b5", boxShort: letters[1])
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [chat])

        vm.query = "q:b5"
        XCTAssertEqual(vm.chatHits.map(\.id), ["!1:s"], "the overridden letter matches")

        vm.query = "y:b5"
        XCTAssertEqual(vm.chatHits.map(\.id), [], "the shadowed default letter does not")
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
    func test_updateChats_refreshesChatHitsAndTitles() {
        // bugbot "Mac chat search snapshot stale": the long-lived Mac search VM
        // must reflect later chat-list updates (new rooms, renamed titles)
        // instead of clinging to the snapshot it was built with.
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let vm = SearchViewModel(
            search: FakeSearchService(),
            allChats: [ChatSummary(id: "!1:s", title: "Auth bug", bot: claude, lastActivity: nil, unreadCount: 0)]
        )
        vm.query = "refactor"
        XCTAssertEqual(vm.chatHits.map(\.id), [], "no match in the original snapshot")

        // A new room arrives and the existing room is renamed.
        vm.updateChats([
            ChatSummary(id: "!1:s", title: "Auth fix", bot: claude, lastActivity: nil, unreadCount: 0),
            ChatSummary(id: "!2:s", title: "Refactor search", bot: claude, lastActivity: nil, unreadCount: 0),
        ])
        XCTAssertEqual(vm.chatHits.map(\.id), ["!2:s"], "new room is now searchable")
        XCTAssertEqual(vm.chatTitle(for: "!1:s"), "Auth fix", "renamed title resolves to the new value")
    }

    /// The search rows carry the same colored tag as the chat list — the
    /// resolver hands the row the tag halves plus a title with the room
    /// marker dropped exactly when a room tag will render in its place.
    @MainActor
    func test_hitTitle_carriesTagHalvesAndDropsRoomMarkerBesideTag() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let solo = ChatSummary(id: "!1:s", title: "Auth bug", bot: claude,
                               lastActivity: nil, unreadCount: 0,
                               boxName: "dev-y", sessionShort: "b5", boxShort: "Y")
        let room = ChatSummary(id: "!2:s", title: "↔️ mac ↔ dev-z", bot: claude,
                               lastActivity: nil, unreadCount: 0,
                               sessionShort: "ab",
                               roomBoxNames: ["dev-y", "dev-z"], roomBoxShorts: ["Y", "Z"])
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [solo, room])

        let tagged = vm.hitTitle(for: "!1:s")
        XCTAssertEqual(tagged.title, "Auth bug")
        XCTAssertEqual(tagged.sessionShort, "b5")
        XCTAssertEqual(tagged.boxLetter, "Y")
        XCTAssertEqual(tagged.boxName, "dev-y")

        let roomLine = vm.hitTitle(for: "!2:s")
        XCTAssertEqual(roomLine.title, "mac ↔ dev-z", "marker drops beside a rendered room tag")
        XCTAssertEqual(roomLine.roomBoxShorts, ["Y", "Z"])

        let unknown = vm.hitTitle(for: "!gone:s")
        XCTAssertEqual(unknown.title, "!gone:s")
        XCTAssertNil(unknown.boxLetter)
    }

    /// Task 11 (journal rewire): `SearchViewModel` no longer tracks backfill
    /// progress (`applyBackfillProgress`/`observeBackfill` were dropped
    /// along with the Matrix-SDK-only backfill machinery), so the empty
    /// state is always the plain "No results." message.
    @MainActor
    func test_emptyState_showsNoResults() async {
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [])
        vm.query = "anything"
        await vm.search()
        XCTAssertEqual(vm.emptyResultsMessage, "No results.")
    }
}
