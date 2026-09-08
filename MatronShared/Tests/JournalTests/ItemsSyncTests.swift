import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

private final class FakeItems: ItemsProviding, @unchecked Sendable {
    let lock = NSLock()
    private var _listResponses: [ItemsPage] = []
    private var _listQueries: [ItemsListQuery] = []
    private var _detail: [String: (TrackerItem, [TrackerComment])] = [:]
    private var _commentCalls: [(String, String)] = []
    private var _failComments = false
    private var _listError: Error?

    var listResponses: [ItemsPage] {
        get { lock.withLock { _listResponses } }
        set { lock.withLock { _listResponses = newValue } }
    }
    var listQueries: [ItemsListQuery] { lock.withLock { _listQueries } }
    var detail: [String: (TrackerItem, [TrackerComment])] {
        get { lock.withLock { _detail } }
        set { lock.withLock { _detail = newValue } }
    }
    var commentCalls: [(String, String)] { lock.withLock { _commentCalls } }
    var failComments: Bool {
        get { lock.withLock { _failComments } }
        set { lock.withLock { _failComments = newValue } }
    }
    var listError: Error? {
        get { lock.withLock { _listError } }
        set { lock.withLock { _listError = newValue } }
    }

    func listItems(_ q: ItemsListQuery) async throws -> ItemsPage {
        lock.withLock { _listQueries.append(q) }
        if let err = listError { throw err }
        return lock.withLock { _listResponses.isEmpty ? ItemsPage(items: [], nextCursor: nil) : _listResponses.removeFirst() }
    }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) {
        guard let d = detail[id] else { throw JournalAPIError.notFound }
        return (d.0, d.1)
    }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem {
        TrackerItem(id: "it_new", num: 9, kind: new.kind, title: new.title, originConvoID: new.convoID)
    }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) {
        lock.withLock { _commentCalls.append((id, idempotencyKey ?? "")) }
        if failComments { throw JournalAPIError.transport("offline") }
        let item = TrackerItem(id: id, num: 1, kind: .question, awaiting: .agent, title: "Q", originConvoID: "c1")
        return (item, TrackerComment(id: "ic_srv", itemID: id, author: .user, body: body))
    }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "blob" }
}

final class ItemsSyncTests: XCTestCase {
    private func make(api: FakeItems) throws -> (ItemsSync, JournalStore, AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.Continuation, AsyncStream<SyncConnectionState>.Continuation) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let (markers, mc) = AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.makeStream()
        let (states, sc) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = ItemsSync(api: api, store: store, markers: { markers }, connectionStates: { states })
        return (sync, store, mc, sc)
    }
    private func item(_ id: String, num: Int, updated: TimeInterval) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .task, title: "T", originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: updated))
    }

    func testRefreshPagesAndUsesWatermark() async throws {
        let api = FakeItems()
        api.listResponses = [ItemsPage(items: [item("a", num: 1, updated: 10)], nextCursor: "n"), ItemsPage(items: [item("b", num: 2, updated: 20)], nextCursor: nil)]
        let (sync, store, _, _) = try make(api: api)
        await sync.refresh(scope: .convo("c1"))
        XCTAssertEqual(try store.items(scope: .all).count, 2)
        XCTAssertEqual(api.listQueries.count, 2); XCTAssertEqual(api.listQueries[1].cursor, "n"); XCTAssertEqual(api.listQueries[0].convoID, "c1")
        XCTAssertNil(api.listQueries[0].since, "empty table → full fetch")
        await sync.refresh(scope: .all)
        XCTAssertEqual(api.listQueries[2].since, Date(timeIntervalSince1970: 19), "watermark = max(updated_at) − 1s")
        XCTAssertNil(api.listQueries[2].convoID)
        let supported = await sync.isSupported
        XCTAssertTrue(supported)
    }

    func testNotFoundMarksUnsupported() async throws {
        let api = FakeItems(); api.listError = JournalAPIError.notFound
        let (sync, _, _, _) = try make(api: api)
        await sync.refresh(scope: .all)
        let supported = await sync.isSupported
        XCTAssertFalse(supported)
    }

    func testMarkerRefetchesThatItem() async throws {
        let api = FakeItems()
        api.detail["it_1"] = (item("it_1", num: 1, updated: 5), [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "x")])
        let (sync, store, markers, _) = try make(api: api)
        await sync.start()
        markers.yield((convoID: "c1", marker: ItemMarkerEvent(itemID: "it_1", num: 1, kind: .task, title: "T", action: .commented, by: .user)))
        try await waitUntil { try store.item(id: "it_1") != nil }
        let comments = try await store.dbQueue.read { db in try ItemCommentRecord.fetchCount(db) }
        XCTAssertEqual(comments, 1)
    }

    func testOutboxDrainsOnRunningAndDeletesOnSuccess() async throws {
        let api = FakeItems(); api.failComments = true
        let (sync, store, _, states) = try make(api: api)
        await sync.start()
        await sync.enqueueComment(itemID: "it_1", localID: "L1", body: "hello", attachments: [])
        try await waitUntil { try store.itemOutboxRows(itemID: "it_1").first?.attempts == 1 }
        api.failComments = false
        states.yield(.running)
        try await waitUntil { try store.itemOutboxPending().isEmpty }
        XCTAssertEqual(api.commentCalls.map(\.1), ["L1", "L1"], "idempotency key = local id on every attempt")
        XCTAssertEqual(try store.item(id: "it_1")?.awaiting, .agent)
    }

    private func waitUntil(_ cond: @escaping () throws -> Bool, timeout: TimeInterval = 2) async throws {
        let start = Date()
        while !(try cond()) {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timeout"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
