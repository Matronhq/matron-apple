import XCTest
@testable import MatronViewModels
import MatronSearch
import MatronChat
import MatronModels

/// Fake `SearchService` scripted with grouped results per query, each
/// optionally slow or failing — for the ordering, latest-wins and failure
/// behaviour of `SearchViewModel.search()`.
private actor ScriptedSearchService: SearchService {
    struct Script {
        var groups: [SearchChatHit] = []
        var delay: Duration = .zero
        var fails = false
    }
    struct Unavailable: Error {}

    private var scripts: [String: Script] = [:]
    private(set) var queries: [String] = []

    func script(_ query: String, _ script: Script) { scripts[query] = script }

    func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] {
        queries.append(text)
        let script = scripts[text] ?? Script()
        if script.delay > .zero { try? await Task.sleep(for: script.delay) }
        if script.fails { throw Unavailable() }
        return script.groups
    }

    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
    func remove(eventID: String) async throws {}
    func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func wipe() async throws {}
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
    func backfillComplete(roomID: String) async throws -> Bool { true }
    func backfillOldestEventID(roomID: String) async throws -> String? { nil }
    func resetBackfill() async throws {}
    func eventCount(roomID: String) async throws -> Int { 0 }
    func contains(eventID: String) async throws -> Bool { false }
}

@MainActor
final class SearchViewModelRankingTests: XCTestCase {
    private let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)

    private func chat(_ id: String, _ title: String) -> ChatSummary {
        ChatSummary(id: id, title: title, bot: bot, lastActivity: nil, unreadCount: 0)
    }

    private func group(_ room: String, exact: Bool = false, sender: String = "agent:gene") -> SearchChatHit {
        SearchChatHit(roomID: room, count: 1,
                      topHit: SearchHit(id: "e-\(room)", roomID: room, sender: sender,
                                        timestamp: Date(timeIntervalSince1970: 1), snippet: room),
                      isExact: exact)
    }

    /// Exact-phrase chats first; within that, chats from the chat list
    /// ahead of subagent chats; the service's order otherwise.
    func test_search_ranksExactThenListedChats() async {
        let service = ScriptedSearchService()
        await service.script("time crisis", .init(groups: [
            group("main:sub:a1"), group("main"), group("other:sub:b2", exact: true),
            group("treadmill", exact: true), group("later"),
        ]))
        let vm = SearchViewModel(search: service,
                                 allChats: [chat("main", "Main"), chat("treadmill", "Treadmill"), chat("later", "Later")],
                                 debounce: .zero)
        vm.query = "time crisis"
        await vm.search()
        XCTAssertEqual(vm.messageHits.map(\.roomID),
                       ["treadmill", "other:sub:b2", "main", "later", "main:sub:a1"])
    }

    /// A slow answer for an earlier, shorter query must not replace the
    /// results of the query now in the field.
    func test_search_latestQueryWins() async {
        let service = ScriptedSearchService()
        await service.script("ti", .init(groups: [group("stale")], delay: .milliseconds(150)))
        await service.script("time", .init(groups: [group("fresh")]))
        let vm = SearchViewModel(search: service, allChats: [], debounce: .zero)
        vm.query = "ti"
        let slow = Task { await vm.search() }
        try? await Task.sleep(for: .milliseconds(30))
        vm.query = "time"
        await vm.search()
        await slow.value
        XCTAssertEqual(vm.messageHits.map(\.roomID), ["fresh"])
        XCTAssertFalse(vm.isSearching)
    }

    /// Typing pauses before the index is asked, and a run cancelled while
    /// it waits never asks at all.
    func test_search_cancelledWhileDebouncing_neverQueries() async {
        let service = ScriptedSearchService()
        let vm = SearchViewModel(search: service, allChats: [], debounce: .seconds(5))
        vm.query = "time"
        let run = Task { await vm.search() }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(vm.isSearching)
        run.cancel()
        await run.value
        let asked = await service.queries
        XCTAssertEqual(asked, [])
        XCTAssertFalse(vm.isSearching)
    }

    func test_search_tooShort_skipsTheIndex() async {
        let service = ScriptedSearchService()
        await service.script("t", .init(groups: [group("noise")]))
        let vm = SearchViewModel(search: service, allChats: [], debounce: .zero)
        vm.query = "t"
        await vm.search()
        let asked = await service.queries
        XCTAssertEqual(asked, [])
        XCTAssertEqual(vm.messageHits, [])
        XCTAssertEqual(vm.emptyResultsMessage, "Type at least 2 characters to search messages.")
    }

    /// An index that can't be read says so; "No results" would claim the
    /// words were never said.
    func test_search_failure_isReportedNotShownAsNoResults() async {
        let service = ScriptedSearchService()
        await service.script("time", .init(fails: true))
        await service.script("times", .init(groups: [group("ok")]))
        let vm = SearchViewModel(search: service, allChats: [], debounce: .zero)
        vm.query = "time"
        await vm.search()
        XCTAssertTrue(vm.searchFailed)
        XCTAssertEqual(vm.emptyResultsMessage, "Search isn't available right now. Try again in a moment.")
        vm.query = "times"
        await vm.search()
        XCTAssertFalse(vm.searchFailed)
        XCTAssertEqual(vm.messageHits.map(\.roomID), ["ok"])
    }

    /// The untrimmed text reaches the service: the trailing space is what
    /// finishes the last word.
    func test_search_passesTheTrailingSpaceThrough() async {
        let service = ScriptedSearchService()
        let vm = SearchViewModel(search: service, allChats: [], debounce: .zero)
        vm.query = "time "
        await vm.search()
        let asked = await service.queries
        XCTAssertEqual(asked, ["time "])
    }

    /// A subagent chat is named by its parent chat and its own title, never
    /// by its `<uuid>:sub:<agent>` id.
    func test_hitTitle_namesSubagentChatsByParentAndTask() async {
        let service = ScriptedSearchService()
        await service.script("refund", .init(groups: [group("main:sub:a1"), group("gone:sub:b2"), group("lost")]))
        let lookup: SearchViewModel.ConversationLookup = { id in
            switch id {
            case "main:sub:a1": return .init(title: "Build partial refund feature", parentID: "main")
            case "gone:sub:b2": return .init(title: "Review refund PR", parentID: "gone")
            case "gone": return .init(title: "Old parent", parentID: nil)
            default: return nil
            }
        }
        let vm = SearchViewModel(search: service, allChats: [chat("main", "Refund tool")],
                                 debounce: .zero, lookupConversation: lookup)
        vm.query = "refund"
        await vm.search()

        let listedParent = vm.hitTitle(for: "main:sub:a1")
        XCTAssertEqual(listedParent.title, "Refund tool")
        XCTAssertEqual(listedParent.subChatTitle, "Build partial refund feature")

        let unlistedParent = vm.hitTitle(for: "gone:sub:b2")
        XCTAssertEqual(unlistedParent.title, "Old parent")
        XCTAssertEqual(unlistedParent.subChatTitle, "Review refund PR")

        let unknown = vm.hitTitle(for: "lost")
        XCTAssertEqual(unknown.title, "Unknown conversation")
        XCTAssertNil(unknown.subChatTitle)
    }

    func test_senderLabel() {
        let vm = SearchViewModel(search: ScriptedSearchService(), allChats: [], ownSender: "user:dan")
        func label(_ sender: String) -> String? { vm.senderLabel(for: group("r", sender: sender).topHit) }
        XCTAssertEqual(label("user:dan"), "You")
        XCTAssertEqual(label("user:sam"), "sam")
        XCTAssertEqual(label("agent:gene"), "gene")
        XCTAssertNil(label("journal"))
    }
}
