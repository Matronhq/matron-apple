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
    /// Fix wave, item G: when set, the NEXT `commentItem` call suspends on
    /// `_gate` instead of returning immediately, so a test can call
    /// `sync.stop()` while a drain is genuinely in flight (rather than
    /// racing a real network call) and then release it to observe what
    /// resumes.
    private var _blockNextComment = false
    private var _gate: CheckedContinuation<Void, Never>?
    /// Fix wave, item I2: the sibling gate for `createItem`, so a test can
    /// prove `ItemsSync.enqueueCreate` returns before its background
    /// drain's network call completes — hold this open, call
    /// `enqueueCreate`, observe it already returned, THEN release.
    private var _blockNextCreate = false
    private var _createGate: CheckedContinuation<Void, Never>?

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
    var blockNextComment: Bool {
        get { lock.withLock { _blockNextComment } }
        set { lock.withLock { _blockNextComment = newValue } }
    }
    /// True once a `commentItem` call is actually suspended on the gate —
    /// lets a test wait for the in-flight call to truly be in-flight
    /// before calling `stop()`, instead of racing a fixed sleep against
    /// the actor hop.
    var isGated: Bool { lock.withLock { _gate != nil } }
    /// Resumes a `commentItem` call currently suspended on the gate, if
    /// any. A no-op if nothing is waiting (e.g. called before the drain
    /// actually reached the gated call).
    func releaseGate() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = _gate; _gate = nil; return c
        }
        cont?.resume()
    }
    var blockNextCreate: Bool {
        get { lock.withLock { _blockNextCreate } }
        set { lock.withLock { _blockNextCreate = newValue } }
    }
    /// True once a `createItem` call is actually suspended on its gate.
    var isCreateGated: Bool { lock.withLock { _createGate != nil } }
    func releaseCreateGate() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = _createGate; _createGate = nil; return c
        }
        cont?.resume()
    }

    func listItems(_ q: ItemsListQuery) async throws -> ItemsPage {
        // Fix round 2, CRITICAL #1: a cancelled drain Task must actually
        // throw here, the way a cancelled `URLSession.data(for:)` would in
        // production — otherwise a test can't tell a self-cancelling retry
        // apart from a working one (nothing else in this fake blocks on
        // real I/O that the runtime would cancel for us).
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        guard let d = detail[id] else { throw JournalAPIError.notFound }
        return (d.0, d.1)
    }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem {
        let shouldGate = lock.withLock { () -> Bool in
            guard _blockNextCreate else { return false }
            _blockNextCreate = false
            return true
        }
        if shouldGate {
            await withCheckedContinuation { cont in lock.withLock { _createGate = cont } }
        }
        return TrackerItem(id: "it_new", num: 9, kind: new.kind, title: new.title, originConvoID: new.convoID)
    }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) {
        try Task.checkCancellation()
        let shouldGate = lock.withLock { () -> Bool in
            guard _blockNextComment else { return false }
            _blockNextComment = false
            return true
        }
        if shouldGate {
            await withCheckedContinuation { cont in lock.withLock { _gate = cont } }
        }
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

    /// IMPORTANT #3 (fix round 1) / CRITICAL #1 (fix round 2): a failed
    /// drain schedules exactly one delayed retry (`min(60s, retryBase ×
    /// 2^attempts)`) instead of waiting solely for an external trigger.
    /// `retryBase` is injected as 0.05s so the test doesn't wait out a real
    /// backoff, and — critically — `.running` is NEVER yielded here, so
    /// the outbox draining is proof the retry timer (not the reconnect
    /// path exercised by the test above) did the work.
    ///
    /// The exact-count assertion (not `>=`) is the regression test for fix
    /// round 2, CRITICAL #1: the retry Task used to call `drainOutbox()`
    /// directly on itself, which cancelled its own currently-running
    /// `Task` (`drainOutbox()` unconditionally cancels whatever
    /// `retryTask` holds), so — now that `FakeItems`'s methods `try
    /// Task.checkCancellation()` first, the way a real cancelled
    /// `URLSession` call would throw — every retry attempt threw
    /// `CancellationError` immediately, was classified retryable, bumped
    /// `attempts`, and scheduled ANOTHER self-cancelling retry, forever.
    /// With that bug, `failComments = false` becoming true again would
    /// never actually get observed, and this test would time out.
    func testFailedDrainSchedulesBackoffRetry() async throws {
        let api = FakeItems(); api.failComments = true
        let (sync, store, _, _) = try make(api: api, retryBase: 0.05)
        await sync.start()
        await sync.enqueueComment(itemID: "it_1", localID: "L1", body: "hello", attachments: [])
        try await waitUntil { try store.itemOutboxRows(itemID: "it_1").first?.attempts == 1 }
        api.failComments = false
        try await waitUntil { try store.itemOutboxPending().isEmpty }
        XCTAssertEqual(api.commentCalls.count, 2, "exactly one original attempt + one retry-delivered attempt — no self-cancel retry storm")
        XCTAssertEqual(try store.item(id: "it_1")?.awaiting, .agent)
    }

    /// Fix round 2, IMPORTANT #2: a truncated pagination run (repeated
    /// `nextCursor`, or the 50-page cap — same code path) must not persist
    /// a watermark for the pages that DID land. The journal returns
    /// `sort=updated` DESC, so bailing out early always leaves an older,
    /// unfetched tail — persisting a watermark here would make the NEXT
    /// refresh believe that tail was already covered and skip it forever.
    func testRepeatedCursorTruncatesPaginationAndLeavesWatermarkUnset() async throws {
        let api = FakeItems()
        let loopingPage = ItemsPage(items: [item("a", num: 1, updated: 10)], nextCursor: "loop")
        api.listResponses = [loopingPage, loopingPage, loopingPage]
        let (sync, store, _, _) = try make(api: api)
        await sync.refresh(scope: .all)
        XCTAssertNil(try store.itemsWatermark(scope: .all), "a truncated pagination run must not persist a watermark")
        XCTAssertEqual(api.listQueries.count, 2, "stops as soon as the SAME cursor repeats a second time")
    }

    /// Fix round 2, IMPORTANT #3a: the drain must not attempt outbox rows
    /// before a `refresh` has proven the tracker routes exist on this
    /// journal — attempting (and thus mark-attempting or poisoning) rows
    /// against an unproven journal is exactly the kind of misclassification
    /// #3b guards against for `.notFound` specifically.
    func testDrainWaitsForSupportBeforeAttemptingRows() async throws {
        let api = FakeItems(); api.listError = JournalAPIError.notFound
        let (sync, store, _, _) = try make(api: api)
        await sync.refresh(scope: .all) // proves unsupported
        let supported = await sync.isSupported
        XCTAssertFalse(supported)

        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: #"{"body":"x","attachments":[]}"#, createdAt: 0, attempts: 0, lastError: nil))
        await sync.drainOutbox()
        XCTAssertEqual(try store.itemOutboxRows(itemID: "it_1").first?.attempts, 0, "no attempt is made while unsupported")
        XCTAssertEqual(api.commentCalls.count, 0, "commentItem is never called while isSupported is false")
        XCTAssertEqual(try store.itemOutboxPending().count, 1)
    }

    /// Fix round 3 (Bugbot finding on PR #185, ~ItemsSync.swift:156): a
    /// successful `refresh` — the thing that flips `isSupported` true — must
    /// itself resume a paused drain, not just publish the flag. Before this
    /// fix, `drainOnce`'s support gate (added in fix round 2) meant a
    /// 404-probe-then-recovery (or an auth pause that later clears) left
    /// rows queued forever unless SOMETHING ELSE happened to also trigger a
    /// drain — a reconnect (`.running`) or a fresh enqueue. A refresh that
    /// proves support with no reconnect and no further enqueue must not
    /// strand rows that were already sitting in the outbox.
    func testRefreshDrainsOutboxOnceSupportIsProven() async throws {
        let api = FakeItems(); api.listError = JournalAPIError.notFound
        let (sync, store, _, _) = try make(api: api)
        await sync.refresh(scope: .all)
        let supportedBefore = await sync.isSupported
        XCTAssertFalse(supportedBefore)

        // Enqueueing while unsupported inserts the row, but `drainOnce`'s
        // support gate skips actually attempting it.
        await sync.enqueueComment(itemID: "it_1", localID: "L1", body: "hello", attachments: [])
        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"])
        XCTAssertEqual(api.commentCalls.count, 0, "the drain never attempted the row while unsupported")

        // The routes now exist. `refresh` succeeding must itself drain the
        // outbox — no `.running` state is ever yielded in this test, so
        // `.running`'s own `drainOutbox()` call cannot be what did this.
        api.listError = nil
        await sync.refresh(scope: .all)
        try await waitUntil { try store.itemOutboxPending().isEmpty }
        XCTAssertEqual(api.commentCalls.count, 1)
        XCTAssertEqual(try store.item(id: "it_1")?.awaiting, .agent)
    }

    /// Fix round 2, IMPORTANT #3b: a 404 on a WRITE (comment/create) is
    /// retryable, not poison — the journal never deletes items
    /// server-side, so a 404 here is far likelier "this journal doesn't
    /// have the tracker routes yet" than "the item is really gone". The
    /// row must survive with its attempt count bumped, not get silently
    /// dropped the way a genuinely-poisoned 400/409 does.
    func testNotFoundOnOutboxWriteIsRetryableNotPoison() async throws {
        let api = FakeItems()
        api.commentErrorForItemID = ["it_1": JournalAPIError.notFound]
        let (sync, store, _, _) = try make(api: api)
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: #"{"body":"x","attachments":[]}"#, createdAt: 0, attempts: 0, lastError: nil))
        await sync.drainOutbox()
        XCTAssertEqual(try store.itemOutboxRows(itemID: "it_1").first?.attempts, 1, "404 is retryable: the row survives with a bumped attempt count, not poisoned")
        XCTAssertEqual(api.commentCalls.count, 1)
    }

    /// Fix round 2, IMPORTANT #3c: a rejected session/credentials pauses
    /// the queue rather than poisoning the row (deleting it) or treating
    /// it as an ordinary retryable failure (counting an attempt and
    /// scheduling a timed backoff retry) — sign-out's `wipeOutbox()`
    /// clears these rows, and a fresh sign-in's `.running` drains them if
    /// they're still queued.
    func testAuthRejectionPausesWithoutDeletingCountingOrRetrying() async throws {
        let api = FakeItems()
        api.commentErrorForItemID = ["it_1": JournalAPIError.unauthenticated]
        let (sync, store, _, _) = try make(api: api, retryBase: 0.05)
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: #"{"body":"x","attachments":[]}"#, createdAt: 0, attempts: 0, lastError: nil))
        await sync.drainOutbox()
        XCTAssertEqual(try store.itemOutboxRows(itemID: "it_1").first?.attempts, 0, "an auth rejection must not count as an attempt")
        XCTAssertEqual(api.commentCalls.count, 1)

        // No backoff retry gets scheduled — wait well past what the retry
        // delay would have been and confirm nothing more happened.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(api.commentCalls.count, 1, "no backoff retry is scheduled on a pause")
        XCTAssertEqual(try store.itemOutboxPending().count, 1, "the row is left queued, not deleted")
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

    /// Fix wave, item A: `commentItem`'s response is kept locally
    /// (`insertComments`) BEFORE the outbox row is deleted and before the
    /// coalesced `refreshItem` GET that follows — so a reply is never
    /// invisible just because that follow-up GET happened to fail.
    /// `FakeItems.item(id:)` throws `.notFound` by default (no `detail`
    /// entry populated for "it_1"), standing in for that failure.
    func testCommentSurvivesEvenWhenFollowUpRefreshItemFails() async throws {
        let api = FakeItems()
        let (sync, store, _, _) = try make(api: api)
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: #"{"body":"hello","attachments":[]}"#, createdAt: 0, attempts: 0, lastError: nil))
        await sync.drainOutbox()
        XCTAssertTrue(try store.itemOutboxPending().isEmpty, "the write itself succeeded, so the outbox row is gone")
        let comments = try await store.dbQueue.read { db in try ItemCommentRecord.fetchAll(db) }.map(\.comment)
        XCTAssertEqual(comments.map(\.id), ["ic_srv"], "the server-returned comment is kept locally even though the follow-up refreshItem GET failed")
        XCTAssertEqual(try store.item(id: "it_1")?.title, "Q", "the item snapshot from commentItem's response is also upserted")
    }

    /// Fix wave, item G: a `stop()` that lands while a drain is genuinely
    /// suspended mid-network-call must prevent that call's result from
    /// ever reaching the store, and must not leave a retry scheduled
    /// behind it.
    func testStopAbortsInFlightDrainWithoutWriting() async throws {
        let api = FakeItems()
        let (sync, store, _, _) = try make(api: api, retryBase: 0.05)
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: #"{"body":"x","attachments":[]}"#, createdAt: 0, attempts: 0, lastError: nil))
        api.blockNextComment = true
        let drainTask = Task { await sync.drainOutbox() }
        try await waitUntil { api.isGated }
        await sync.stop()
        api.releaseGate()
        _ = await drainTask.value

        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"], "the row is untouched — neither deleted nor attempt-bumped")
        XCTAssertNil(try store.item(id: "it_1"), "no store write happened after stop()")
        let comments = try await store.dbQueue.read { db in try ItemCommentRecord.fetchCount(db) }
        XCTAssertEqual(comments, 0)

        // No retry task exists: wait past what the (fast, 0.05s-based)
        // backoff would have been and confirm no second attempt fires.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(api.commentCalls.count, 1, "no retry task exists after a stop() aborts the in-flight call")
    }

    /// Fix wave, item I3: the sibling case to the test above — a resumed
    /// call that THROWS after `stop()` flipped `stopped` must hit the same
    /// guard as a successful resume, at the top of the per-row `catch`
    /// block. Without it, the catch would still mark the attempt (a write
    /// racing whatever `stop()`'s caller does next) and, for a retryable
    /// disposition, the OUTER `drainOutbox()` would schedule a fresh
    /// `retryTask` after `stop()` already awaited the old one to nil.
    func testStopAbortsInFlightDrainOnThrowWithoutWritingOrRetrying() async throws {
        let api = FakeItems()
        let (sync, store, _, _) = try make(api: api, retryBase: 0.05)
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: #"{"body":"x","attachments":[]}"#, createdAt: 0, attempts: 0, lastError: nil))
        api.blockNextComment = true
        api.commentErrorForItemID = ["it_1": JournalAPIError.transport("offline")]
        let drainTask = Task { await sync.drainOutbox() }
        try await waitUntil { api.isGated }
        await sync.stop()
        api.releaseGate()
        _ = await drainTask.value

        let pending = try store.itemOutboxPending()
        XCTAssertEqual(pending.map(\.localID), ["L1"], "the row is untouched — neither deleted nor attempt-bumped")
        XCTAssertEqual(pending.first?.attempts, 0, "no attempt marked for a throw that resumes after stop()")
        XCTAssertNil(pending.first?.lastError)

        // No retry task exists: wait past what the (fast, 0.05s-based)
        // backoff would have been and confirm no second attempt fires.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(api.commentCalls.count, 1, "no retry task exists after a post-stop throw")
    }

    /// Fix wave, item I3: an enqueue racing sign-out must not insert after
    /// `wipeOutbox()` — both hosts' teardown calls `stop()` before wiping,
    /// so `stopped` being set is the signal a late-arriving enqueue must
    /// respect.
    func testEnqueueAfterStopDoesNotInsertIntoOutbox() async throws {
        let api = FakeItems()
        let (sync, store, _, _) = try make(api: api)
        await sync.stop()
        await sync.enqueueComment(itemID: "it_1", localID: "L1", body: "x", attachments: [])
        let created = await sync.enqueueCreate(localID: "L2", NewItem(kind: .task, title: "T", convoID: "c1"))
        XCTAssertFalse(created, "fix wave, item I3: enqueueCreate must report failure when stopped")
        XCTAssertTrue(try store.itemOutboxPending().isEmpty, "an enqueue racing sign-out must not insert after stop()")
    }

    /// Fix wave, item I3: the insert succeeding is what `enqueueCreate`
    /// reports — callers use this to know their task is durably queued.
    func testEnqueueCreateReturnsTrueOnSuccessfulInsert() async throws {
        let api = FakeItems()
        let (sync, store, _, _) = try make(api: api)
        let created = await sync.enqueueCreate(localID: "L1", NewItem(kind: .task, title: "T", convoID: "c1"))
        XCTAssertTrue(created)
        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"])
    }

    /// Fix wave, item I2: `enqueueCreate` must return once the row is
    /// durably inserted, WITHOUT waiting for the drain's network
    /// round-trip — the composer used to hold `isSending` (and thus block
    /// the UI) across that whole round-trip for a write that's already
    /// safe once queued. Proven by gating `createItem` open: if
    /// `enqueueCreate` awaited the drain (the pre-fix-wave shape), this
    /// test would hang until the gate was released, never reaching the
    /// `waitUntil` below.
    func testEnqueueCreateReturnsBeforeTheBackgroundDrainCompletes() async throws {
        let api = FakeItems()
        let (sync, store, _, _) = try make(api: api)
        api.blockNextCreate = true
        let created = await sync.enqueueCreate(localID: "L1", NewItem(kind: .task, title: "T", convoID: "c1"))
        XCTAssertTrue(created, "the insert itself must succeed and return promptly")
        try await waitUntil { api.isCreateGated }
        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"],
                       "still pending — the background drain's network call hasn't resolved yet")
        api.releaseCreateGate()
        try await waitUntil { try store.itemOutboxPending().isEmpty }
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
