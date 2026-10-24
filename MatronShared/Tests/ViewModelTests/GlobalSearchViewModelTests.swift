import XCTest
@testable import MatronViewModels
import MatronChat
import MatronJournal
import MatronModels

/// The journal's `GET /search/all`, scripted per query.
private actor ScriptedGlobalSearch: GlobalSearching {
    struct Unavailable: Error {}

    private var answers: [String: GlobalSearchResults] = [:]
    private var failing: Set<String> = []
    private(set) var queries: [String] = []

    func answer(_ query: String, _ results: GlobalSearchResults) { answers[query] = results }
    func fail(_ query: String) { failing.insert(query) }

    func searchAll(_ query: String, limit: Int) async throws -> GlobalSearchResults {
        queries.append(query)
        if failing.contains(query) { throw Unavailable() }
        return answers[query] ?? GlobalSearchResults(results: [], chats: [])
    }
}

@MainActor
final class GlobalSearchViewModelTests: XCTestCase {

    /// What each number is, and what opened.
    @MainActor
    private final class Numbers: Sendable {
        var findings: [Int: GoToNumberResolver.Finding] = [:]
        var opened: [GoToNumberTarget] = []

        func find(_ num: Int) async -> GoToNumberResolver.Finding { findings[num] ?? .none }

        func locate(_ hit: GoToNumberHit) async -> GoToNumberResolver.Resolution {
            .open(.item(id: "it_\(hit.num)"), hit)
        }
    }

    private let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)

    private func chat(_ id: String, _ title: String, snippet: String = "") -> ChatSummary {
        ChatSummary(id: id, title: title, bot: bot, lastActivity: nil, unreadCount: 0, snippet: snippet)
    }

    private func makeVM(_ search: ScriptedGlobalSearch, numbers: Numbers? = nil,
                        chats: [ChatSummary] = []) -> GlobalSearchViewModel {
        let numbers = numbers ?? Numbers()
        return GlobalSearchViewModel(
            searcher: search, chats: { chats }, debounce: .zero,
            number: GoToNumberViewModel(debounce: .zero, find: { await numbers.find($0) },
                                        locate: { await numbers.locate($0) },
                                        open: { numbers.opened.append($0) }))
    }

    private let parserItem = GlobalSearchResult(kind: .item, id: "it_412", num: 412, title: "Fix the parser",
                                                state: "open", why: "number")
    private let proxyMission = GlobalSearchResult(kind: .mission, id: "ms_9", num: 9, title: "Proxy hardening",
                                                  why: "stemmed", snippet: "**Proxy** hardening Ticket 412 is next")

    // MARK: - Numbers

    func test_aNumber_showsWhatCarriesItFirst_markedGoTo_andNotListedTwice() async {
        let search = ScriptedGlobalSearch()
        await search.answer("412", GlobalSearchResults(results: [parserItem, proxyMission], chats: []))
        let numbers = Numbers()
        numbers.findings[412] = .found(GoToNumberHit(kind: .item, num: 412, title: "Fix the parser"))
        let vm = makeVM(search, numbers: numbers)

        vm.query = "412"
        await vm.search()

        let page = vm.page
        XCTAssertEqual(page.number, GlobalSearchPage.NumberRow(label: "#412 · Item — Fix the parser", canOpen: true))
        XCTAssertEqual(page.results.map(\.rowID), ["mission:ms_9"], "the number's own row is the Go to row")
        XCTAssertEqual(numbers.opened, [], "nothing opens before Return")
    }

    func test_return_opensTheNumber_asGoToDid() async {
        let search = ScriptedGlobalSearch()
        let numbers = Numbers()
        numbers.findings[412] = .found(GoToNumberHit(kind: .item, num: 412))
        let vm = makeVM(search, numbers: numbers)

        vm.query = " #412 "
        await vm.search()
        let opened = await vm.submit()

        XCTAssertTrue(opened)
        XCTAssertEqual(numbers.opened, [.item(id: "it_412")])
    }

    func test_return_onWords_opensNothing() async {
        let search = ScriptedGlobalSearch()
        let numbers = Numbers()
        let vm = makeVM(search, numbers: numbers)

        vm.query = "parser"
        await vm.search()
        let opened = await vm.submit()

        XCTAssertFalse(opened)
        XCTAssertNil(vm.page.number, "words have no Go to row")
        XCTAssertEqual(numbers.opened, [])
    }

    func test_aNumberNothingCarries_saysSo_andCannotOpen() async {
        let vm = makeVM(ScriptedGlobalSearch())

        vm.query = "5"
        await vm.search()

        XCTAssertEqual(vm.page.number, GlobalSearchPage.NumberRow(label: "Nothing is numbered 5.", canOpen: false))
    }

    // MARK: - Results

    func test_aStaleAnswer_neverShowsUnderNewText() async {
        let search = ScriptedGlobalSearch()
        await search.answer("proxy", GlobalSearchResults(results: [proxyMission], chats: []))
        let vm = makeVM(search)

        vm.query = "proxy"
        await vm.search()
        XCTAssertEqual(vm.page.status, .done)
        XCTAssertEqual(vm.page.results, [proxyMission])

        vm.query = "proxy timeout"
        XCTAssertEqual(vm.page.status, .searching)
        XCTAssertEqual(vm.page.results, [], "the answer for \"proxy\" is not shown under new text")

        await vm.search()
        XCTAssertEqual(vm.page.status, .done)
        XCTAssertTrue(vm.page.isEmptyResult)
        let asked = await search.queries
        XCTAssertEqual(asked, ["proxy", "proxy timeout"])
    }

    func test_aFailedSearch_isReported_andAskedAgain() async {
        let search = ScriptedGlobalSearch()
        await search.fail("proxy")
        let vm = makeVM(search)

        vm.query = "proxy"
        await vm.search()
        XCTAssertEqual(vm.page.status, .failed)

        await vm.search()
        let asked = await search.queries
        XCTAssertEqual(asked, ["proxy", "proxy"], "a failure is not kept as the answer")
    }

    func test_emptyText_isTheEmptyPage_andAsksNothing() async {
        let search = ScriptedGlobalSearch()
        let vm = makeVM(search)

        vm.query = "   "
        await vm.search()

        XCTAssertEqual(vm.page.status, .empty)
        let asked = await search.queries
        XCTAssertEqual(asked, [])
    }

    func test_textTooLongToSend_endsAsNothingFound_notSearching() async {
        let search = ScriptedGlobalSearch()
        let vm = makeVM(search)

        vm.query = String(repeating: "a", count: GlobalSearchViewModel.maxQueryLength + 1)
        await vm.search()

        XCTAssertEqual(vm.page.status, .done)
        XCTAssertEqual(vm.page.results, [])
        let asked = await search.queries
        XCTAssertEqual(asked, [], "the journal is not asked")
    }

    func test_conversations_matchEveryWordOfTitleOrLatestMessage() async {
        let chats = [
            chat("c1", "Fix deploy script"),
            chat("c2", "Release notes", snippet: "the deploy needs a fix"),
            chat("c3", "Deploy dashboard"),
        ]
        let vm = makeVM(ScriptedGlobalSearch(), chats: chats)

        vm.query = "deploy FIX"

        XCTAssertEqual(vm.page.conversations.map(\.id), ["c1", "c2"])
        XCTAssertEqual(vm.page.conversations[1].subtitle, "the deploy needs a fix")
    }

    func test_conversations_areCapped() {
        let chats = (1...12).map { chat("c\($0)", "Deploy \($0)") }
        XCTAssertEqual(GlobalSearchViewModel.matchingConversations(chats, query: "deploy").count,
                       GlobalSearchViewModel.conversationLimit)
    }
}
