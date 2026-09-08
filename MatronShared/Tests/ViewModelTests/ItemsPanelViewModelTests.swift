import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

private final class FakeItemsStore: ItemsStoreReading, @unchecked Sendable {
    var cont: AsyncStream<[TrackerItem]>.Continuation?
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { self.cont = $0 } }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
}
private final class FakeSync: ItemsSyncing, @unchecked Sendable {
    var refreshed: [ItemsScope] = []; var created: [NewItem] = []; var refetched: [String] = []
    func refresh(scope: ItemsScope) async { refreshed.append(scope) }
    func refreshItem(id: String) async { refetched.append(id) }
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {}
    func enqueueCreate(localID: String, _ new: NewItem) async { created.append(new) }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
}
private final class FakeAPI: ItemsProviding, @unchecked Sendable {
    var rankCalls: [(String, ItemRankChange)] = []; var failRank = false
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem {
        rankCalls.append((id, change)); if failRank { throw JournalAPIError.transport("x") }
        return TrackerItem(id: id, num: 0, kind: .task, title: "", originConvoID: "c1")
    }
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "b" }
}

@MainActor
final class ItemsPanelViewModelTests: XCTestCase {
    private func t(_ id: String, num: Int, kind: ItemKind = .task, awaiting: ItemAwaiting? = .agent, state: ItemState = .open,
                   rank: Double, closed: TimeInterval? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: state == .closed ? .done : nil, awaiting: awaiting,
                    rank: rank, title: "T\(num)", originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: Double(num)),
                    closedAt: closed.map { Date(timeIntervalSince1970: $0) })
    }

    func testSectionsRule() {
        let items = [t("q", num: 1, kind: .question, awaiting: .user, rank: 5), t("a", num: 2, rank: 2), t("b", num: 3, rank: 1),
                     t("d", num: 4, kind: .decision, awaiting: nil, rank: 9), t("x", num: 5, state: .closed, rank: 0, closed: 50),
                     t("y", num: 6, state: .closed, rank: 0, closed: 60), t("ut", num: 7, awaiting: .user, rank: 3)]
        let s = ItemsPanelViewModel.sections(from: items)
        XCTAssertEqual(s.needsYou.map(\.id), ["ut", "q"])
        XCTAssertEqual(s.tasks.map(\.id), ["b", "a", "ut"])
        XCTAssertEqual(s.decisions.map(\.id), ["d"])
        XCTAssertEqual(s.done.map(\.id), ["y", "x"])
    }

    func testStartSubscribesAndRefreshes() async {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.cont?.yield([t("a", num: 1, rank: 1)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a"])
        XCTAssertEqual(sync.refreshed, [.convo("c1")])
        vm.scope = .all
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.refreshed.last, .all)
    }

    func testMoveIsOptimisticAndRevertsOnFailure() async {
        let store = FakeItemsStore(); let api = FakeAPI(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: api, sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.cont?.yield([t("a", num: 1, rank: 1), t("b", num: 2, rank: 2), t("c", num: 3, rank: 3)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        await vm.move(itemID: "c", toIndex: 0)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(api.rankCalls.first?.1, ItemRankChange(position: "top"))
        XCTAssertEqual(sync.refetched, ["c"])
        api.failRank = true
        await vm.move(itemID: "a", toIndex: 2)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "a", "b"], "reverted")
        XCTAssertNotNil(vm.error)
        api.failRank = false
        await vm.move(itemID: "b", toIndex: 1)   // [c, a, b] -> [c, b, a]
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(api.rankCalls.last?.1, ItemRankChange(after: "c", before: "a"))
        let callsBeforeNoOp = api.rankCalls.count
        await vm.move(itemID: "c", toIndex: 0)   // already first: a genuine no-op
        XCTAssertEqual(api.rankCalls.count, callsBeforeNoOp, "no-op move must not hit the network")
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "b", "a"])
    }

    func testCreateEnqueues() async {
        let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: FakeItemsStore(), api: FakeAPI(), sync: sync)
        await vm.create(kind: .task, title: "  Do X ", body: "why")
        XCTAssertEqual(sync.created.first?.title, "Do X"); XCTAssertEqual(sync.created.first?.convoID, "c1")
        await vm.create(kind: .task, title: "   ", body: "")
        XCTAssertEqual(sync.created.count, 1); XCTAssertNotNil(vm.error)
    }
}
