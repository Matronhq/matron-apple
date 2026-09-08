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
    /// Per-call error queue, checked before `listError`: `nil` means
    /// "succeed this call" (fall through to `listResponses`), non-nil
    /// means "throw this specific error for this call only". Lets a test
    /// script "page 1 succeeds, page 2 throws" (fix round 1, CRITICAL #1's
    /// mid-pagination-failure test) without `listError`'s blanket
    /// every-call behavior.
    private var _listErrorQueue: [Error?] = []
    /// Per-item override for `commentItem`, so one outbox row can be a
    /// poison rejection while another (different item) in the same drain
    /// pass still succeeds (fix round 1, IMPORTANT #4).
    private var _commentErrorForItemID: [String: Error] = [:]

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
    var listErrorQueue: [Error?] {
        get { lock.withLock { _listErrorQueue } }
        set { lock.withLock { _listErrorQueue = newValue } }
    }
    var commentErrorForItemID: [String: Error] {
        get { lock.withLock { _commentErrorForItemID } }
        set { lock.withLock { _commentErrorForItemID = newValue } }
    }

    func listItems(_ q: ItemsListQuery) async throws -> ItemsPage {
        lock.withLock { _listQueries.append(q) }
        // Two-step lock: first check whether a queued entry exists at all
        // (so an empty queue correctly falls through to the blanket
        // `listError`), THEN pop it. Collapsing this into one `withLock`
        // that returns `Error?` and assigning it to an `Error??` local
        // silently auto-wraps `.none` into `.some(.none)` — which made
        // `if let` on the outer optional always succeed and permanently
        // shadowed the `listError` fallback.
        let hasQueued = lock.withLock { !_listErrorQueue.isEmpty }
        if hasQueued {
            let queuedError = lock.withLock { _listErrorQueue.removeFirst() }
            if let err = queuedError { throw err }
        } else if let err = listError {
            throw err
        }
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
        if let err = commentErrorForItemID[id] { throw err }
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
    private func make(api: FakeItems, retryBase: TimeInterval = 2) throws -> (ItemsSync, JournalStore, AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.Continuation, AsyncStream<SyncConnectionState>.Continuation) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let (markers, mc) = AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.makeStream()
        let (states, sc) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = ItemsSync(api: api, store: store, markers: { markers }, connectionStates: { states }, retryBase: retryBase)
        return (sync, store, mc, sc)
    }
    private func item(_ id: String, num: Int, updated: TimeInterval) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .task, title: "T", originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: updated))
    }

    /// Per-scope persisted watermark (fix round 1, CRITICAL #1/#2): each
    /// scope's `since` comes from its OWN persisted high-water mark, not a
    /// shared `MAX(updated_at)` over the whole local `item` table — a
    /// `.convo` refresh must not inherit `.all`'s watermark (or vice
    /// versa), since either could skip items the other scope never
    /// actually fetched.
    func testRefreshPagesAndUsesWatermark() async throws {
        let api = FakeItems()
        api.listResponses = [ItemsPage(items: [item("a", num: 1, updated: 10)], nextCursor: "n"), ItemsPage(items: [item("b", num: 2, updated: 20)], nextCursor: nil)]
        let (sync, store, _, _) = try make(api: api)
        await sync.refresh(scope: .convo("c1"))
        XCTAssertEqual(try store.items(scope: .all).count, 2)
        XCTAssertEqual(api.listQueries.count, 2); XCTAssertEqual(api.listQueries[1].cursor, "n"); XCTAssertEqual(api.listQueries[0].convoID, "c1")
        XCTAssertNil(api.listQueries[0].since, "no persisted watermark yet for this scope → full fetch")
        XCTAssertEqual(try store.itemsWatermark(scope: .convo("c1")), Date(timeIntervalSince1970: 20), "watermark = newest updated_at seen across every fetched page, persisted only after the pagination loop completes")

        // A second refresh of the SAME scope now uses that persisted watermark.
        api.listResponses = [ItemsPage(items: [], nextCursor: nil)]
        await sync.refresh(scope: .convo("c1"))
        XCTAssertEqual(api.listQueries[2].since, Date(timeIntervalSince1970: 19), "since = watermark − 1s")
        XCTAssertEqual(api.listQueries[2].convoID, "c1")

        // `.all` has never been fetched — its OWN watermark is still unset,
        // independent of convo("c1")'s, so it's still a full fetch.
        api.listResponses = [ItemsPage(items: [], nextCursor: nil)]
        await sync.refresh(scope: .all)
        XCTAssertNil(api.listQueries[3].since, "per-scope watermark: .all is independent of convo(\"c1\")'s")
        XCTAssertNil(api.listQueries[3].convoID)

        let supported = await sync.isSupported
        XCTAssertTrue(supported)
    }

    /// CRITICAL #1: a throw partway through pagination must NOT persist a
    /// watermark for whatever pages happened to land first — that would
    /// permanently convince the next refresh it's already caught up past a
    /// gap it never actually fetched (the journal returns `sort=updated`
    /// DESC, so the pages that DID land are the newest ones; a naive "read
    /// MAX(updated_at) back from the table" watermark would look correct
    /// while silently missing everything after the failure).
    func testMidPaginationFailureLeavesWatermarkUnset() async throws {
        struct BoomError: Error {}
        let api = FakeItems()
        api.listResponses = [ItemsPage(items: [item("a", num: 1, updated: 10)], nextCursor: "n")]
        api.listErrorQueue = [nil, BoomError()] // call 1 succeeds (page 1), call 2 throws
        let (sync, store, _, _) = try make(api: api)
        await sync.refresh(scope: .all)
        XCTAssertNil(try store.itemsWatermark(scope: .all), "mid-pagination failure must not persist a partial watermark")
        XCTAssertEqual(try store.items(scope: .all).count, 1, "page 1's item, upserted before the failure, is still cached")

        // The NEXT refresh is still a full fetch — not poisoned by a
        // watermark that believed it covered the gap.
        api.listErrorQueue = []
        api.listResponses = [ItemsPage(items: [], nextCursor: nil)]
        await sync.refresh(scope: .all)
        XCTAssertNil(api.listQueries.last?.since, "no persisted watermark → next refresh is a full fetch")
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

    /// IMPORTANT #3: a failed drain schedules exactly one delayed retry
    /// (`min(60s, retryBase × 2^attempts)`) instead of waiting solely for
    /// an external trigger. `retryBase` is injected as 0.05s so the test
    /// doesn't wait out a real backoff, and — critically — `.running` is
    /// NEVER yielded here, so the outbox draining is proof the retry timer
    /// (not the reconnect path exercised by the test above) did the work.
    func testFailedDrainSchedulesBackoffRetry() async throws {
        let api = FakeItems(); api.failComments = true
        let (sync, store, _, _) = try make(api: api, retryBase: 0.05)
        await sync.start()
        await sync.enqueueComment(itemID: "it_1", localID: "L1", body: "hello", attachments: [])
        try await waitUntil { try store.itemOutboxRows(itemID: "it_1").first?.attempts == 1 }
        api.failComments = false
        try await waitUntil { try store.itemOutboxPending().isEmpty }
        XCTAssertGreaterThanOrEqual(api.commentCalls.count, 2, "the scheduled backoff retry, not just the original enqueue, must have redrained")
        XCTAssertEqual(try store.item(id: "it_1")?.awaiting, .agent)
    }

    /// IMPORTANT #4: a non-retryable rejection (400) must not block rows
    /// behind it in the same outbox — it's dropped ("poisoned") and the
    /// pass continues.
    func testPoisonRowIsSkippedNotBlockingQueue() async throws {
        let api = FakeItems()
        api.commentErrorForItemID = ["it_bad": JournalAPIError.http(status: 400, message: "bad request")]
        let (sync, store, _, _) = try make(api: api)
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_bad", op: "comment", payloadJSON: #"{"body":"bad","attachments":[]}"#, createdAt: 0, attempts: 0, lastError: nil))
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L2", itemID: "it_good", op: "comment", payloadJSON: #"{"body":"ok","attachments":[]}"#, createdAt: 1, attempts: 0, lastError: nil))
        await sync.drainOutbox()
        try await waitUntil { try store.itemOutboxPending().isEmpty }
        XCTAssertEqual(api.commentCalls.map(\.0), ["it_bad", "it_good"], "the poisoned row is dropped, not retried, and does not block the row behind it")
        XCTAssertEqual(try store.item(id: "it_good")?.awaiting, .agent)
    }

    private func waitUntil(_ cond: @escaping () throws -> Bool, timeout: TimeInterval = 2) async throws {
        struct TimeoutError: Error, CustomStringConvertible { var description: String { "waitUntil timed out" } }
        let start = Date()
        while !(try cond()) {
            if Date().timeIntervalSince(start) > timeout { throw TimeoutError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
