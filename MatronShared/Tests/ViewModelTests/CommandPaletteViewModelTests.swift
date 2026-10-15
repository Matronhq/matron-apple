import XCTest
@testable import MatronViewModels
import MatronSearch
import MatronChat
import MatronModels

/// Fake `SearchService`: one fixed answer for every grouped query.
private actor FixedSearchService: SearchService {
    let groups: [SearchChatHit]
    init(groups: [SearchChatHit] = []) { self.groups = groups }

    func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] { groups }
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
final class CommandPaletteViewModelTests: XCTestCase {
    private let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)

    private func chat(_ id: String, _ title: String, active: TimeInterval = 0) -> ChatSummary {
        ChatSummary(id: id, title: title, bot: bot, lastActivity: Date(timeIntervalSince1970: active), unreadCount: 0)
    }

    private func item(_ num: Int, _ title: String, state: ItemState = .open, body: String = "",
                      updated: TimeInterval = 0) -> TrackerItem {
        TrackerItem(id: "it-\(num)", num: num, kind: .task, state: state, title: title, body: body,
                    originConvoID: "c", updatedAt: Date(timeIntervalSince1970: updated))
    }

    private func group(_ room: String) -> SearchChatHit {
        SearchChatHit(roomID: room, count: 2,
                      topHit: SearchHit(id: "e-\(room)", roomID: room, sender: "agent:box-a",
                                        timestamp: Date(timeIntervalSince1970: 1), snippet: room))
    }

    private let catalog = CommandPaletteCatalog(
        items: [TrackerItem(id: "it-7", num: 7, kind: .question, title: "Pick a cover colour", originConvoID: "c")],
        missions: [Mission(id: "m-20", num: 20, title: "Cover redesign", originConvoID: "c")],
        projects: [Project(id: "p-30", num: 30, title: "Spring covers")])

    private func makeVM(chats: [ChatSummary] = [], groups: [SearchChatHit] = [],
                        pins: [String: String] = [:], catalog: CommandPaletteCatalog? = nil,
                        lookup: SearchViewModel.NumberLookupClosure? = nil) -> CommandPaletteViewModel {
        let search = SearchViewModel(search: FixedSearchService(groups: groups), allChats: chats,
                                     debounce: .zero, lookupNumber: lookup)
        let loaded = catalog ?? self.catalog
        return CommandPaletteViewModel(search: search, pinLabels: pins, loadCatalog: { loaded })
    }

    /// One query finds a conversation, an item, a mission, a project and
    /// message text, each in its own section, in that order.
    func test_query_groupsEveryKind() async {
        let vm = makeVM(chats: [chat("c1", "Cover review")], groups: [group("c9")])
        await vm.load()
        vm.query = "cover"
        await vm.runSearch()
        XCTAssertEqual(vm.sections.map(\.kind), [.chats, .items, .missions, .projects, .messages])
        XCTAssertEqual(vm.results.map(\.id),
                       ["chat:c1", "item:it-7", "mission:m-20", "project:p-30", "message:c9"])
    }

    /// Every word must match, in any order, ignoring case and accents.
    func test_trackerMatch_everyWordAnyOrderIgnoringAccents() async {
        let vm = makeVM(catalog: CommandPaletteCatalog(items: [item(1, "Café menu"), item(2, "Menu bar")]))
        await vm.load()
        vm.query = "MENU cafe"
        XCTAssertEqual(vm.results.map(\.id), ["item:it-1"])
    }

    /// Title matches before body-only matches; open before closed; newest
    /// first within each.
    func test_trackerMatch_ranksTitleThenOpenThenNewest() async {
        let items = [
            item(1, "Other", body: "the parser again", updated: 50),
            item(2, "Parser crash", state: .closed, updated: 40),
            item(3, "Parser docs", updated: 10),
            item(4, "Fix the parser", updated: 30),
        ]
        let vm = makeVM(catalog: CommandPaletteCatalog(items: items))
        await vm.load()
        vm.query = "parser"
        XCTAssertEqual(vm.results.map(\.id), ["item:it-4", "item:it-3", "item:it-2", "item:it-1"])
    }

    /// A number finds its row by number, shown once as the "Go to" row
    /// rather than again in its own section.
    func test_number_showsGoToRowOnce() async {
        let vm = makeVM(lookup: { num in GoToNumberHit(kind: .mission, num: num, title: "Cover redesign") })
        await vm.load()
        vm.query = "#20"
        await vm.runSearch()
        XCTAssertEqual(vm.sections.map(\.kind), [.number])
        XCTAssertEqual(vm.selectedResult?.id, "number:20")
    }

    /// A pinned conversation is found by its pin name too.
    func test_chats_matchPinLabels() async {
        let vm = makeVM(chats: [chat("c1", "Long session title"), chat("c2", "Unrelated")],
                        pins: ["c1": "Help desk"])
        vm.query = "help"
        XCTAssertEqual(vm.results.map(\.id), ["chat:c1"])
    }

    /// Empty, the palette offers the most recent conversations.
    func test_emptyQuery_listsRecentConversations() {
        let vm = makeVM(chats: [chat("old", "Old", active: 1), chat("new", "New", active: 9)])
        XCTAssertEqual(vm.sections.map(\.kind), [.recent])
        XCTAssertEqual(vm.results.map(\.id), ["chat:new", "chat:old"])
    }

    /// The arrow keys step through every row across sections and stop at
    /// either end; a new query starts again at the top.
    func test_selection_movesAcrossSectionsAndClamps() async {
        let vm = makeVM(chats: [chat("c1", "Cover review")])
        await vm.load()
        vm.query = "cover"
        XCTAssertEqual(vm.selectedResult?.id, "chat:c1")
        vm.moveSelection(by: 1)
        XCTAssertEqual(vm.selectedResult?.id, "item:it-7")
        vm.moveSelection(by: 10)
        XCTAssertEqual(vm.selectedResult?.id, "project:p-30")
        vm.moveSelection(by: -10)
        XCTAssertEqual(vm.selectedResult?.id, "chat:c1")
        vm.moveSelection(by: 2)
        vm.query = "spring"
        XCTAssertEqual(vm.selectedResult?.id, "project:p-30")
    }

    /// Message results arriving later keep the highlight where it was.
    func test_selection_keptWhenMessagesArrive() async {
        let vm = makeVM(groups: [group("c9")])
        await vm.load()
        vm.query = "cover"
        vm.moveSelection(by: 1)
        XCTAssertEqual(vm.selectedResult?.id, "mission:m-20")
        await vm.runSearch()
        XCTAssertEqual(vm.selectedResult?.id, "mission:m-20")
        XCTAssertEqual(vm.results.last?.id, "message:c9")
    }

    func test_noMatches_saysSo() async {
        let vm = makeVM()
        await vm.load()
        vm.query = "zebra"
        await vm.runSearch()
        XCTAssertTrue(vm.showsNoResults)
        XCTAssertEqual(vm.emptyMessage, "No results.")
    }
}
