import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

/// A journal for the reconcile: the user's own list and the shared list are
/// served separately (by `query.shared`), each as scripted pages, and
/// `item(id:)` answers from `visible` or 404s.
private final class ReconcileFakeItems: ItemsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _ownPages: [ItemsPage] = []
    private var _sharedPages: [ItemsPage] = []
    private var _ownError: Error?
    private var _sharedError: Error?
    private var _itemError: Error?
    private var _visible: [String: TrackerItem] = [:]
    private var _queries: [ItemsListQuery] = []
    private var _itemCalls: [String] = []

    var ownPages: [ItemsPage] { get { lock.withLock { _ownPages } } set { lock.withLock { _ownPages = newValue } } }
    var sharedPages: [ItemsPage] { get { lock.withLock { _sharedPages } } set { lock.withLock { _sharedPages = newValue } } }
    var ownError: Error? { get { lock.withLock { _ownError } } set { lock.withLock { _ownError = newValue } } }
    var sharedError: Error? { get { lock.withLock { _sharedError } } set { lock.withLock { _sharedError = newValue } } }
    var itemError: Error? { get { lock.withLock { _itemError } } set { lock.withLock { _itemError = newValue } } }
    var visible: [String: TrackerItem] { get { lock.withLock { _visible } } set { lock.withLock { _visible = newValue } } }
    var queries: [ItemsListQuery] { lock.withLock { _queries } }
    var itemCalls: [String] { lock.withLock { _itemCalls } }

    func listItems(_ q: ItemsListQuery) async throws -> ItemsPage {
        lock.withLock { _queries.append(q) }
        if q.shared {
            if let e = sharedError { throw e }
            return lock.withLock { _sharedPages.isEmpty ? ItemsPage(items: [], nextCursor: nil) : _sharedPages.removeFirst() }
        }
        if let e = ownError { throw e }
        return lock.withLock { _ownPages.isEmpty ? ItemsPage(items: [], nextCursor: nil) : _ownPages.removeFirst() }
    }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) {
        lock.withLock { _itemCalls.append(id) }
        if let e = itemError { throw e }
        guard let item = visible[id] else { throw JournalAPIError.notFound }
        return (item, [])
    }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment?) { fatalError() }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "blob" }
}

final class ItemsReconcileTests: XCTestCase {
    private let old = Date(timeIntervalSince1970: 1_000)

    /// One of the user's own items.
    private func own(_ id: String, num: Int) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .task, title: "Mine", originConvoID: "c1", updatedAt: old)
    }
    /// An item of a mission another person shares with the user: no origin.
    private func granted(_ id: String, num: Int, updatedAt: Date? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .task, title: "Theirs", originConvoID: "", updatedAt: updatedAt ?? old,
                    missionID: "ms_bob", missionNum: 3)
    }

    private func make(_ api: ReconcileFakeItems,
                      shared: AsyncStream<SharedMissionSignal>? = nil) throws -> (ItemsSync, JournalStore) {
        let store = try makeTestStore(.queue)
        let sync = ItemsSync(api: api, store: store,
                             markers: { AsyncStream { _ in } }, connectionStates: { AsyncStream { _ in } },
                             sharedMissions: shared.map { s in { s } })
        return (sync, store)
    }

    // MARK: store

    func testDeleteItemsRemovesRowsAndCommentsButKeepsItemsWithOutboxRows() throws {
        let store = try makeTestStore(.queue)
        try store.upsertItems([granted("it_a", num: 1), granted("it_b", num: 2), own("it_c", num: 3)])
        try store.replaceComments(itemID: "it_a", [TrackerComment(id: "ic_1", itemID: "it_a", author: .agent, body: "x")])
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_b", op: "comment", payloadJSON: "{}",
                                                    createdAt: 1, attempts: 0, lastError: nil))

        let removed = try store.deleteItems(ids: ["it_a", "it_b", "it_missing"])

        XCTAssertEqual(removed, ["it_a"])
        XCTAssertNil(try store.item(id: "it_a"))
        XCTAssertEqual(try store.comments(itemID: "it_a"), [])
        XCTAssertNotNil(try store.item(id: "it_b"), "an item with an outbox row is kept")
        XCTAssertNotNil(try store.item(id: "it_c"))
        XCTAssertEqual(try store.itemOutboxItemIDs(), ["it_b"])
        XCTAssertEqual(Set(try store.itemUpdatedAts().keys), ["it_b", "it_c"])
    }

    func testDeleteItemsDropsTheRowFromTheItemsList() async throws {
        let store = try makeTestStore(.queue)
        try store.upsertItems([granted("it_a", num: 1), own("it_c", num: 3)])
        try store.deleteItems(ids: ["it_a"])
        XCTAssertEqual(try store.items(scope: .all).map(\.id), ["it_c"])
    }

    // MARK: sync

    func testReconcileRemovesAnItemNoLongerServed() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        try store.upsertItems([own("it_own", num: 1), granted("it_gone", num: 7), granted("it_kept", num: 8)])
        try store.replaceComments(itemID: "it_gone", [TrackerComment(id: "ic_1", itemID: "it_gone", author: .agent, body: "x")])
        api.ownPages = [ItemsPage(items: [own("it_own", num: 1)], nextCursor: nil)]
        api.sharedPages = [ItemsPage(items: [granted("it_kept", num: 8)], nextCursor: nil)]

        let outcome = await sync.reconcile()

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertNil(try store.item(id: "it_gone"))
        XCTAssertEqual(try store.comments(itemID: "it_gone"), [])
        XCTAssertNotNil(try store.item(id: "it_own"))
        XCTAssertNotNil(try store.item(id: "it_kept"))
        XCTAssertEqual(api.itemCalls, ["it_gone"], "only the row missing from both lists is checked")
        let shared = api.queries.filter(\.shared)
        XCTAssertEqual(shared.count, 1)
        XCTAssertNil(api.queries.first { !$0.shared }?.since, "the reconcile reads the whole list, not since a watermark")
    }

    func testReconcileReadsEveryPageOfBothLists() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        try store.upsertItems([own("it_1", num: 1), own("it_2", num: 2), granted("it_3", num: 3), granted("it_4", num: 4)])
        api.ownPages = [ItemsPage(items: [own("it_1", num: 1)], nextCursor: "o2"),
                        ItemsPage(items: [own("it_2", num: 2)], nextCursor: nil)]
        api.sharedPages = [ItemsPage(items: [granted("it_3", num: 3)], nextCursor: "s2"),
                           ItemsPage(items: [granted("it_4", num: 4)], nextCursor: nil)]

        let outcome = await sync.reconcile()
        XCTAssertEqual(outcome, .succeeded)

        XCTAssertEqual(Set(try store.itemUpdatedAts().keys), ["it_1", "it_2", "it_3", "it_4"])
        XCTAssertEqual(api.itemCalls, [])
        XCTAssertEqual(api.queries.map(\.cursor), [nil, "o2", nil, "s2"])
    }

    func testReconcileKeepsARowTheJournalStillServesOnItsOwn() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        // Updated while the list was being paged, so it slipped past the
        // cursor: absent from the list, but the journal still serves it.
        try store.upsertItems([own("it_moved", num: 5)])
        api.visible = ["it_moved": own("it_moved", num: 5)]

        let outcome = await sync.reconcile()
        XCTAssertEqual(outcome, .succeeded)

        XCTAssertNotNil(try store.item(id: "it_moved"))
    }

    func testAFailedListRemovesNothing() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        try store.upsertItems([own("it_own", num: 1), granted("it_g", num: 2)])
        api.ownError = JournalAPIError.transport("offline")

        guard case .failed = await sync.reconcile() else { return XCTFail("expected a failure") }
        XCTAssertEqual(Set(try store.itemUpdatedAts().keys), ["it_own", "it_g"])
        XCTAssertEqual(api.itemCalls, [])

        api.ownError = nil
        api.sharedError = JournalAPIError.http(status: 400, message: "bad_request")
        guard case .failed = await sync.reconcile() else { return XCTFail("expected a failure") }
        XCTAssertEqual(Set(try store.itemUpdatedAts().keys), ["it_own", "it_g"],
                       "a journal that cannot list shared items removes nothing")
    }

    func testATruncatedListRemovesNothing() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        try store.upsertItems([granted("it_g", num: 2)])
        // A cursor that repeats: the list never completes.
        api.ownPages = [ItemsPage(items: [], nextCursor: "x"), ItemsPage(items: [], nextCursor: "x")]

        guard case .failed = await sync.reconcile() else { return XCTFail("expected a failure") }
        XCTAssertNotNil(try store.item(id: "it_g"))
        XCTAssertEqual(api.itemCalls, [])
    }

    func testAnEmptyListRemovesOnlyWhatTheJournalConfirmsGone() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        try store.upsertItems([own("it_own", num: 1), granted("it_g", num: 2)])
        // Both lists empty, but the user's own item is still served.
        api.visible = ["it_own": own("it_own", num: 1)]

        let outcome = await sync.reconcile()
        XCTAssertEqual(outcome, .succeeded)

        XCTAssertNotNil(try store.item(id: "it_own"))
        XCTAssertNil(try store.item(id: "it_g"))
    }

    func testAFailedCheckKeepsTheRow() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        try store.upsertItems([granted("it_g", num: 2)])
        api.itemError = JournalAPIError.transport("offline")

        guard case .failed = await sync.reconcile() else { return XCTFail("expected a failure") }
        XCTAssertNotNil(try store.item(id: "it_g"))
    }

    func testAnItemWithAQueuedCommentIsKept() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        try store.upsertItems([granted("it_g", num: 2)])
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_g", op: "comment", payloadJSON: "{}",
                                                    createdAt: 1, attempts: 0, lastError: nil))

        let outcome = await sync.reconcile()
        XCTAssertEqual(outcome, .succeeded)

        XCTAssertNotNil(try store.item(id: "it_g"))
        XCTAssertEqual(api.itemCalls, [], "an item with an outbox row is not even a candidate")
    }

    func testARecentlyWrittenRowIsKept() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        // Written by something racing the pass (a mission page's fetch):
        // the lists may predate it.
        try store.upsertItems([granted("it_new", num: 9, updatedAt: Date())])

        let outcome = await sync.reconcile()
        XCTAssertEqual(outcome, .succeeded)

        XCTAssertNotNil(try store.item(id: "it_new"))
        XCTAssertEqual(api.itemCalls, [])
    }

    func testTheReconcileDoesNotAddOtherPeoplesItems() async throws {
        let api = ReconcileFakeItems()
        let (sync, store) = try make(api)
        api.ownPages = [ItemsPage(items: [own("it_own", num: 1)], nextCursor: nil)]
        api.sharedPages = [ItemsPage(items: [granted("it_theirs", num: 2)], nextCursor: nil)]

        let outcome = await sync.reconcile()
        XCTAssertEqual(outcome, .succeeded)

        XCTAssertEqual(Set(try store.itemUpdatedAts().keys), ["it_own"])
    }

    func testReconcileIsDueOncePerSessionThenPerInterval() async throws {
        let api = ReconcileFakeItems()
        let (sync, _) = try make(api)
        await sync.start()
        var due = await sync.reconcileDue()
        XCTAssertTrue(due, "the first connect of a session reconciles")
        let outcome = await sync.reconcile()
        XCTAssertEqual(outcome, .succeeded)
        due = await sync.reconcileDue()
        XCTAssertFalse(due)
        due = await sync.reconcileDue(now: Date().addingTimeInterval(7 * 60 * 60))
        XCTAssertTrue(due)
        await sync.stop()
        await sync.start()
        due = await sync.reconcileDue()
        XCTAssertTrue(due, "a new session reconciles again")
        await sync.stop()
    }

    func testAMissionRemovedFrameRemovesItsItemsAtOnce() async throws {
        let api = ReconcileFakeItems()
        let (frames, continuation) = AsyncStream<SharedMissionSignal>.makeStream()
        let (sync, store) = try make(api, shared: frames)
        try store.upsertItems([own("it_own", num: 1), granted("it_g", num: 2)])
        api.ownPages = [ItemsPage(items: [own("it_own", num: 1)], nextCursor: nil)]
        await sync.start()

        continuation.yield(SharedMissionSignal(event: SharedMissionSignal.missionChanged, missionID: "ms_bob"))
        continuation.yield(SharedMissionSignal(event: SharedMissionSignal.missionRemoved, missionID: "ms_bob"))

        let deadline = Date().addingTimeInterval(5)
        while try store.item(id: "it_g") != nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(try store.item(id: "it_g"))
        XCTAssertNotNil(try store.item(id: "it_own"))
        XCTAssertEqual(api.queries.filter(\.shared).count, 1, "only the removal triggers a reconcile")
        await sync.stop()
    }

    // MARK: wire

    func testSharedFrameDecodes() {
        let frame = ServerFrame.decode(#"{"kind":"shared","event":"mission_removed","mission_id":"ms_1","grant_id":"gr_1"}"#)
        guard case .sharedMission(let signal)? = frame else { return XCTFail("expected a shared frame") }
        XCTAssertEqual(signal, SharedMissionSignal(event: "mission_removed", missionID: "ms_1"))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"shared","event":"mission_removed"}"#))
    }

    func testSharedListQueryLeavesOutOwnListFilters() {
        var q = ItemsListQuery()
        q.shared = true
        q.limit = 500
        q.sort = .updated
        q.since = Date(timeIntervalSince1970: 5)
        q.convoID = "c1"
        q.cursor = "k"
        let names = q.queryItems.map(\.name)
        XCTAssertEqual(names, ["scope", "limit", "cursor"])
        XCTAssertEqual(q.queryItems.first?.value, "shared")
        XCTAssertFalse(ItemsListQuery().queryItems.contains { $0.name == "scope" })
    }
}
