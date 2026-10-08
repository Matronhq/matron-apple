import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

private final class FakeItemsStore: ItemsStoreReading, @unchecked Sendable {
    var cont: AsyncStream<[TrackerItem]>.Continuation?
    var createsCont: AsyncStream<[ItemOutboxRecord]>.Continuation?
    /// The scope-independent stream `awaitingYou` reads — separate from
    /// `cont` so a test can drive the two independently.
    var awaitingCont: AsyncStream<[TrackerItem]>.Continuation?
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { self.cont = $0 } }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func comments(itemID: String) throws -> [TrackerComment] { [] }
    func item(id: String) throws -> TrackerItem? { nil }
    func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { [] }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { self.createsCont = $0 } }
    func needsUserStream() -> AsyncStream<[TrackerItem]> { AsyncStream { self.awaitingCont = $0 } }
}
private final class FakeSync: ItemsSyncing, @unchecked Sendable {
    var refreshed: [ItemsScope] = []; var created: [NewItem] = []; var refetched: [String] = []
    /// Values `supportedStream()` yields, in order, on each call.
    var supportedValues: [Bool] = [true]
    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { refreshed.append(scope); return .succeeded }
    func refreshItem(id: String) async { refetched.append(id) }
    /// Every `enqueueComment` call, as (item, body, action, replyTo).
    var comments: [(itemID: String, body: String, action: String?, replyTo: String?)] = []
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {
        comments.append((itemID, body, action, replyTo))
    }
    func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
    var createSucceeds = true
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { created.append(new); return createSucceeds }
    func supportedStream() async -> AsyncStream<Bool> {
        let values = supportedValues
        return AsyncStream { c in for v in values { c.yield(v) }; c.finish() }
    }
}
private final class FakeAPI: ItemsProviding, @unchecked Sendable {
    var rankCalls: [(String, ItemRankChange)] = []; var failRank = false
    /// Awaited inside `rankItem`, to hold a move in flight.
    var rankHold: (@Sendable () async -> Void)?
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem {
        rankCalls.append((id, change)); await rankHold?(); if failRank { throw JournalAPIError.transport("x") }
        return TrackerItem(id: id, num: 0, kind: .task, title: "", originConvoID: "c1")
    }
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "b" }
}

@MainActor
final class ItemsPanelViewModelTests: XCTestCase {
    private func t(_ id: String, num: Int, kind: ItemKind = .task, awaiting: ItemAwaiting? = .agent, state: ItemState = .open,
                   rank: Double, closed: TimeInterval? = nil, resolution: ItemResolution? = nil, origin: String = "c1") -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: resolution ?? (state == .closed ? .done : nil),
                    awaiting: awaiting, rank: rank, title: "T\(num)", originConvoID: origin,
                    updatedAt: Date(timeIntervalSince1970: Double(num)),
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

    // MARK: - Decided section

    /// `isDecided(_:)` / `sections(from:).decided`: ANY closed question or
    /// decision counts, whatever its resolution — the journal doesn't
    /// enforce kind/resolution pairing, so a question closed `.done` or
    /// `.cancelled` (an agent abandoning it rather than answering it) must
    /// still show up. A task never counts, even closed `.done`. An open
    /// item of any kind never counts. Newest-closed first.
    func testDecidedIncludesAnyClosedNonTaskWhateverItsResolution() {
        let items = [
            t("answered", num: 1, kind: .question, state: .closed, rank: 0, closed: 10, resolution: .answered),
            t("openQuestion", num: 2, kind: .question, rank: 0),
            t("decided", num: 3, kind: .decision, state: .closed, rank: 0, closed: 30, resolution: .decided),
            t("reversed", num: 4, kind: .decision, state: .closed, rank: 0, closed: 20, resolution: .reversed),
            t("cancelledDecision", num: 5, kind: .decision, state: .closed, rank: 0, closed: 40, resolution: .cancelled),
            t("doneTask", num: 6, kind: .task, state: .closed, rank: 0, closed: 50, resolution: .done),
            t("cancelledQuestion", num: 7, kind: .question, state: .closed, rank: 0, closed: 5, resolution: .cancelled),
            t("doneQuestion", num: 8, kind: .question, state: .closed, rank: 0, closed: 45, resolution: .done),
            t("noResolutionDecision", num: 9, kind: .decision, state: .closed, rank: 0, closed: 35, resolution: nil),
        ]
        XCTAssertEqual(ItemsPanelViewModel.sections(from: items).decided.map(\.id),
                       ["doneQuestion", "cancelledDecision", "noResolutionDecision", "decided", "reversed", "answered", "cancelledQuestion"],
                       "every closed question/decision counts regardless of resolution; task never does; newest closedAt first")
        let nonDecided: Set<String> = ["openQuestion", "doneTask"]
        for item in items {
            XCTAssertEqual(ItemsPanelViewModel.isDecided(item), !nonDecided.contains(item.id), item.id)
        }
    }

    /// Two items closed at the exact same instant tie-break on `num` desc
    /// (newest-created first) rather than falling back to whatever order
    /// the store happened to hand them in.
    func testDecidedTieBreaksOnNumDescendingWhenClosedAtMatches() {
        let items = [
            t("low", num: 1, kind: .decision, state: .closed, rank: 0, closed: 100, resolution: .decided),
            t("high", num: 5, kind: .decision, state: .closed, rank: 0, closed: 100, resolution: .decided),
            t("mid", num: 3, kind: .decision, state: .closed, rank: 0, closed: 100, resolution: .decided),
        ]
        XCTAssertEqual(ItemsPanelViewModel.sections(from: items).decided.map(\.id), ["high", "mid", "low"])
    }

    /// The Closed tab is ordered by the user's own last input, not by when
    /// the item was closed: an agent closing an old answer late must not
    /// lift it above a decision the user has just made. An item with no
    /// recorded input falls back to its close time.
    func testDecidedOrdersByTheUsersLastInputThenCloseTime() {
        func closed(_ id: String, num: Int, closed: TimeInterval, input: TimeInterval?) -> TrackerItem {
            TrackerItem(id: id, num: num, kind: .question, state: .closed, resolution: .answered, title: id,
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: closed),
                        closedAt: Date(timeIntervalSince1970: closed),
                        lastUserInputAt: input.map { Date(timeIntervalSince1970: $0) })
        }
        let items = [
            closed("answeredLongAgoClosedJustNow", num: 1, closed: 900, input: 100),
            closed("answeredRecently", num: 2, closed: 500, input: 450),
            closed("noInputRecorded", num: 3, closed: 300, input: nil),
        ]
        XCTAssertEqual(ItemsPanelViewModel.sections(from: items).decided.map(\.id),
                       ["answeredRecently", "noInputRecorded", "answeredLongAgoClosedJustNow"])
    }

    /// The latest 50 by default, whatever their age:
    /// the 14-day window had grown to about 3,000 rows.
    func testDefaultDecidedWindowIsTheLatestFifty() {
        let closed = { (n: Int) in (0..<n).map { i in
            self.t("d\(i)", num: i, kind: .decision, state: .closed, rank: 0, closed: Double(1_000_000 - i), resolution: .decided)
        } }
        XCTAssertEqual(ItemsPanelViewModel.defaultDecidedWindow(closed(5)), 5, "fewer than 50 — show them all")
        XCTAssertEqual(ItemsPanelViewModel.defaultDecidedWindow(closed(3000)), 50)
    }

    func testNeedsYouCountIsScopedToThisConversation() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        vm.scope = .all
        try await waitUntil { store.cont != nil }
        let foreign = TrackerItem(id: "f", num: 9, kind: .question, awaiting: .user, rank: 1, title: "F", originConvoID: "c2")
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), foreign])
        try await waitUntil { vm.sections.needsYou.count == 2 }
        XCTAssertEqual(vm.needsYouCount, 1, "badge counts only this conversation even in All scope")
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
        // Optimistic rank, not just optimistic order: a store emission for
        // an unrelated row mid-flight must recompute sections into the
        // same order, which only works if the moved item's rank is
        // actually ahead of its new neighbour's.
        XCTAssertLessThan(vm.sections.tasks[0].rank, vm.sections.tasks[1].rank)
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

    /// The store keeps the pre-move rank until the journal answers, so an
    /// emission in that window (or a sort that started before the drag)
    /// must not put the dragged task back where it was.
    func testAStoreEmissionWhileAMoveIsInFlightKeepsTheOptimisticOrder() async {
        let store = FakeItemsStore(); let api = FakeAPI(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: api, sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let preMove = [t("a", num: 1, rank: 1), t("b", num: 2, rank: 2), t("c", num: 3, rank: 3)]
        store.cont?.yield(preMove)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let (gate, open) = AsyncStream<Void>.makeStream()
        api.rankHold = { for await _ in gate { return } }
        let move = Task { await vm.move(itemID: "c", toIndex: 0) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "a", "b"])
        store.cont?.yield(preMove)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "a", "b"], "an unconfirmed move survives a store emission")
        open.yield(); await move.value
        // Confirmed: the store's ranks rule again, including a later reorder from elsewhere.
        store.cont?.yield(preMove)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a", "b", "c"])
    }

    func testCreateEnqueues() async {
        let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: FakeItemsStore(), api: FakeAPI(), sync: sync)
        await vm.create(kind: .task, title: "  Do X ", body: "why")
        XCTAssertEqual(sync.created.first?.title, "Do X"); XCTAssertEqual(sync.created.first?.convoID, "c1")
        await vm.create(kind: .task, title: "   ", body: "")
        XCTAssertEqual(sync.created.count, 1); XCTAssertNotNil(vm.error)
        vm.error = nil
        sync.createSucceeds = false
        await vm.create(kind: .task, title: "Y", body: "")
        XCTAssertNotNil(vm.error, "a failed enqueue is surfaced, not swallowed")
    }

    func testStopCancelsStream() async {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.cont?.yield([t("a", num: 1, rank: 1)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a"])
        vm.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.cont?.yield([t("a", num: 1, rank: 1), t("b", num: 2, rank: 2)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a"], "stop() must cancel the store subscription")
    }

    /// Fix wave, item C: an outbox "create" row emission surfaces as a
    /// `pendingCreates` entry, filtered to this VM's `convoID` when in
    /// `.convo` scope.
    func testPendingCreatesTrackOutboxCreateStream() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.createsCont != nil }
        let mine = ItemOutboxRecord(localID: "L1", itemID: nil, op: "create",
                                    payloadJSON: #"{"kind":"task","title":"Do X","body":"","convoID":"c1","attachments":[]}"#,
                                    createdAt: 0, attempts: 0, lastError: nil)
        let foreign = ItemOutboxRecord(localID: "L2", itemID: nil, op: "create",
                                       payloadJSON: #"{"kind":"question","title":"Other chat","body":"","convoID":"c2","attachments":[]}"#,
                                       createdAt: 1, attempts: 2, lastError: "offline")
        store.createsCont?.yield([mine, foreign])
        try await waitUntil { !vm.pendingCreates.isEmpty }
        XCTAssertEqual(vm.pendingCreates.map(\.id), ["L1"], "convo scope filters to this VM's convoID")
        XCTAssertEqual(vm.pendingCreates.first?.kind, .task)
        XCTAssertEqual(vm.pendingCreates.first?.title, "Do X")
        XCTAssertEqual(vm.pendingCreates.first?.attempts, 0)

        // Switching scope resubscribes onto a fresh `itemOutboxCreatesStream()`
        // call (a new AsyncStream, a new continuation) — re-yield onto it
        // once the resubscription has actually happened.
        vm.scope = .all
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.createsCont?.yield([mine, foreign])
        try await waitUntil { vm.pendingCreates.count == 2 }
        XCTAssertEqual(Set(vm.pendingCreates.map(\.id)), ["L1", "L2"], "all scope surfaces every pending create")
        XCTAssertEqual(vm.pendingCreates.first { $0.id == "L2" }?.lastError, "offline")
    }

    /// I4 (Mac fix wave, part 2): `ItemsPanelViewModel` now owns its own
    /// `observationGeneration`/`stop(ifGeneration:)` counter (mirrors
    /// `SubChatStripViewModel`) — a stale host's `onDisappear` (a
    /// same-identity remount racing a newer `.task`, e.g. the Mac items
    /// pane's outer `.task`, see that file's `itemsVMStartedGeneration`)
    /// must not cancel the stream a successor `start()` just began.
    func testStopIfGenerationGuardsAgainstStaleTeardown() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)

        vm.start()
        let firstGeneration = vm.observationGeneration
        try await waitUntil { store.cont != nil }

        store.cont = nil
        vm.start()
        let secondGeneration = vm.observationGeneration
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        try await waitUntil { store.cont != nil }

        // A stale surface's teardown (still holding the FIRST generation)
        // must not cancel the stream the second start() just began.
        vm.stop(ifGeneration: firstGeneration)
        store.cont?.yield([t("a", num: 1, rank: 1)])
        try await waitUntil { !vm.sections.tasks.isEmpty }
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a"],
                       "a stale stop(ifGeneration:) must not cancel the successor's stream")

        // The CURRENT generation's stop still cancels it.
        vm.stop(ifGeneration: secondGeneration)
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.cont?.yield([t("a", num: 1, rank: 1), t("b", num: 2, rank: 2)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a"], "a matching-generation stop cancels the observation")
    }

    func testIsSupportedFollowsSupportedStream() async throws {
        let sync = FakeSync()
        sync.supportedValues = [true, false]
        let vm = ItemsPanelViewModel(convoID: "c1", store: FakeItemsStore(), api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { vm.isSupported == false }
    }

    // MARK: - App shell: all-conversations mode (spec §1)

    func testNilConvoStartsInAllScope() {
        let vm = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: FakeSync())
        XCTAssertNil(vm.convoID)
        XCTAssertEqual(vm.scope, .all)
        XCTAssertEqual(vm.needsYouCount, 0)
    }

    func testAwaitingYouIsCrossConversationNewestFirstRegardlessOfScope() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.awaitingCont != nil }
        XCTAssertEqual(vm.scope, .convo("c1"), "the panel's own scope is untouched by the awaiting stream")
        let mine = t("q", num: 1, kind: .question, awaiting: .user, rank: 1)   // updatedAt = 1
        let withAgent = t("a", num: 2, rank: 2)                                // awaiting .agent → excluded
        let foreign = TrackerItem(id: "f", num: 9, kind: .decision, awaiting: .user, rank: 1, title: "F",
                                  originConvoID: "c2", updatedAt: Date(timeIntervalSince1970: 9))
        store.awaitingCont?.yield([mine, withAgent, foreign])
        try await waitUntil { vm.awaitingYouCount == 2 }
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["f", "q"], "needsUser only, newest updatedAt first, every conversation")
        XCTAssertEqual(vm.needsYouCount, 0, "the per-conversation badge only follows the scoped stream")
    }

    // MARK: - Notices

    private func notice(_ id: String, num: Int, state: ItemState = .open, closed: TimeInterval? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .notice, state: state, resolution: state == .closed ? .done : nil,
                    awaiting: state == .open ? .user : nil, title: "N\(num)", originConvoID: "c1",
                    updatedAt: Date(timeIntervalSince1970: Double(num)),
                    closedAt: closed.map { Date(timeIntervalSince1970: $0) }, actions: ["Seen"])
    }

    /// A notice awaits the user like a question does: it is in For you and
    /// counts towards the badge.
    func testAwaitingYouIncludesNotices() async throws {
        let store = FakeItemsStore()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: FakeSync())
        vm.start()
        try await waitUntil { store.awaitingCont != nil }
        store.awaitingCont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), notice("n", num: 2)])
        try await waitUntil { vm.awaitingYouCount == 2 }
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["n", "q"])
    }

    /// Nothing about a notice was decided: once seen it leaves For you
    /// rather than moving to the Decided section.
    func testDecidedExcludesNotices() {
        let items = [
            notice("seen", num: 1, state: .closed, closed: 50),
            t("answered", num: 2, kind: .question, state: .closed, rank: 0, closed: 40, resolution: .answered),
        ]
        XCTAssertEqual(ItemsPanelViewModel.sections(from: items).decided.map(\.id), ["answered"])
        XCTAssertFalse(ItemsPanelViewModel.isDecided(items[0]))
    }

    /// The row's Seen button posts the item's own action — body and action
    /// both "Seen", no reply_to — and the row leaves at once, before the
    /// journal has closed it.
    func testMarkSeenPostsTheSeenActionAndHidesTheRow() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.awaitingCont != nil }
        let n = notice("n", num: 2)
        store.awaitingCont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), n])
        try await waitUntil { vm.awaitingYouCount == 2 }

        await vm.markSeen("n")
        XCTAssertEqual(sync.comments.count, 1)
        XCTAssertEqual(sync.comments.first?.itemID, "n")
        XCTAssertEqual(sync.comments.first?.body, "Seen")
        XCTAssertEqual(sync.comments.first?.action, "Seen")
        XCTAssertNil(sync.comments.first?.replyTo)
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["q"], "hidden at once")

        // The store still has it open (offline, say): it stays hidden, and
        // a second tap sends nothing more.
        store.awaitingCont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), n])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["q"])
        await vm.markSeen("n")
        XCTAssertEqual(sync.comments.count, 1)
    }

    /// Only an open notice offering "Seen" takes the one-tap answer.
    func testMarkSeenIgnoresAnythingButANotice() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.awaitingCont != nil }
        let question = TrackerItem(id: "q", num: 1, kind: .question, awaiting: .user, title: "Q", originConvoID: "c1",
                                   actions: ["Seen"])
        store.awaitingCont?.yield([question])
        try await waitUntil { vm.awaitingYouCount == 1 }
        await vm.markSeen("q")
        await vm.markSeen("missing")
        XCTAssertTrue(sync.comments.isEmpty)
        XCTAssertEqual(vm.awaitingYouCount, 1)
    }

    func testAwaitingYouCountTracksStoreEmits() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.awaitingCont != nil }
        store.awaitingCont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
        try await waitUntil { vm.awaitingYouCount == 1 }
        store.awaitingCont?.yield([])
        try await waitUntil { vm.awaitingYouCount == 0 }
        vm.stop()
        store.awaitingCont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.awaitingYouCount, 0, "stop() cancels the awaiting subscription too")
    }

    func testNeedsYouCountStillPerConversationWhenConvoIDSet() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        let foreign = TrackerItem(id: "f", num: 9, kind: .question, awaiting: .user, rank: 1, title: "F", originConvoID: "c2")
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), foreign])
        try await waitUntil { vm.sections.needsYou.count == 2 }
        XCTAssertEqual(vm.needsYouCount, 1)
    }

    func testCreateWithoutConversationSurfacesAnError() async {
        let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: sync)
        await vm.create(kind: .task, title: "Do X", body: "")
        XCTAssertTrue(sync.created.isEmpty)
        XCTAssertNotNil(vm.error)
    }

    // MARK: - Decided section: VM behaviour

    /// A closed item arriving via a fresh store emission — the same shape
    /// an `item` marker → `ItemsSync.refreshItem` → `store.upsertItems`
    /// produces — moves the item from `sections.needsYou` into `decided`,
    /// with no separate "marker" plumbing needed at the VM layer: it just
    /// reacts to `itemsStream(scope:)`'s next emission like everything
    /// else in `sections`.
    func testDecidedMovesItemFromOpenToDecidedOnAFreshStoreEmission() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        let open = t("q1", num: 1, kind: .question, awaiting: .user, rank: 1)
        store.cont?.yield([open])
        try await waitUntil { vm.sections.needsYou.contains { $0.id == "q1" } }
        XCTAssertTrue(vm.decided.isEmpty)

        let closed = t("q1", num: 1, kind: .question, awaiting: nil, state: .closed, rank: 1, closed: 5, resolution: .answered)
        store.cont?.yield([closed])
        try await waitUntil { !vm.decided.isEmpty }
        XCTAssertFalse(vm.sections.needsYou.contains { $0.id == "q1" }, "closed — no longer needs the user")
        XCTAssertEqual(vm.decided.map(\.id), ["q1"])
        XCTAssertEqual(vm.decidedVisibleCount, 1)
    }

    /// `showMoreDecided()` grows the window purely from what's already
    /// local (no server backfill — review, 2026-09-29), and a later
    /// unrelated store emission (some other item changing, re-firing the
    /// same stream) must not reset a window the user has already
    /// expanded. `hasMoreDecided` tracks whether there's still more to
    /// reveal, purely from the visible-vs-total counts.
    func testShowMoreDecidedGrowsLocalWindowAndPersistsAcrossUnrelatedEmissions() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        let old: TimeInterval = 20 * 86400
        let items = (0..<80).map { i in
            t("d\(i)", num: i, kind: .decision, state: .closed, rank: 0, closed: old - Double(i), resolution: .decided)
        }
        store.cont?.yield(items)
        try await waitUntil { vm.decided.count == 80 }
        XCTAssertEqual(vm.decidedVisibleCount, 50, "the latest 50 by default")
        XCTAssertTrue(vm.hasMoreDecided)

        vm.showMoreDecided()
        XCTAssertEqual(vm.decidedVisibleCount, 80, "grew from what's already local")
        XCTAssertFalse(vm.hasMoreDecided, "everything local is now shown")

        store.cont?.yield(items + [t("unrelated", num: 99, rank: 5)])
        try await waitUntil { vm.sections.tasks.contains { $0.id == "unrelated" } }
        XCTAssertEqual(vm.decidedVisibleCount, 80, "the user's own expansion survives an unrelated store emission")
    }

    /// `decidedOriginConvoIDs` is the DISTINCT set of origin conversations
    /// across every decided item, recomputed once per store emission — the
    /// host shells fold this into their `originConvoIDs` `.task(id:)` key
    /// instead of handing it every individual decided item (review,
    /// 2026-09-29).
    func testDecidedOriginConvoIDsIsTheDistinctSetOfOrigins() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        let a = t("a", num: 1, kind: .decision, state: .closed, rank: 0, closed: 10, resolution: .decided, origin: "c1")
        let b = t("b", num: 2, kind: .decision, state: .closed, rank: 0, closed: 20, resolution: .decided, origin: "c1")
        let c = t("c", num: 3, kind: .question, state: .closed, rank: 0, closed: 30, resolution: .answered, origin: "c2")
        store.cont?.yield([a, b, c])
        try await waitUntil { vm.decided.count == 3 }
        XCTAssertEqual(vm.decidedOriginConvoIDs, ["c1", "c2"], "deduplicated across items sharing an origin")
    }

    /// Both shells read the awaiting count (the nav badge) and the
    /// awaiting items' origins (the origin-label fetch key) in their root
    /// body. `awaitingYou` itself changes whenever any awaiting item is
    /// touched, which with many live agents is several times a minute, so
    /// those two are separate properties that only move when their values
    /// do (Mac live sample, 2026-10-08).
    func testTheShellsBadgeAndOriginKeyIgnoreATouchedAwaitingItem() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.awaitingCont != nil }
        store.awaitingCont?.yield([t("q", num: 2, kind: .question, awaiting: .user, rank: 1, origin: "c1")])
        try await waitUntil { vm.awaitingYou.count == 1 }
        XCTAssertEqual(vm.awaitingYouCount, 1)
        XCTAssertEqual(vm.awaitingOriginConvoIDs, ["c1"])

        let changed = ChangeFlag()
        withObservationTracking { _ = vm.awaitingOriginConvoIDs; _ = vm.awaitingYouCount } onChange: { changed.set() }
        store.awaitingCont?.yield([t("q", num: 2, kind: .question, awaiting: .user, rank: 9, origin: "c1")])
        try await waitUntil { vm.awaitingYou.first?.rank == 9 }
        XCTAssertFalse(changed.value, "same count, same origins: nothing the shells read moved")

        store.awaitingCont?.yield([t("q", num: 2, kind: .question, awaiting: .user, rank: 9, origin: "c1"),
                                   t("s", num: 4, kind: .question, awaiting: .user, rank: 3, origin: "c2")])
        try await waitUntil { vm.awaitingOriginConvoIDs == ["c1", "c2"] }
        XCTAssertEqual(vm.awaitingYouCount, 2)
        XCTAssertTrue(changed.value)
    }

    /// The per-conversation items pane's own `ItemsPanelViewModel`
    /// (`convoID != nil`) never populates `decided` — nothing reads it
    /// there, and computing it on every emission of that VM's own
    /// (potentially much more frequent) stream would be wasted work
    /// (review, 2026-09-29).
    func testDecidedIsNeverPopulatedForAPerConversationPanel() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        store.cont?.yield([t("d1", num: 1, kind: .decision, state: .closed, rank: 0, closed: 10, resolution: .decided)])
        try await waitUntil { vm.sections.decided.count == 1 }
        // `sections.decided` (the pure static derivation) DOES see it —
        // only the VM's own published `decided`/window state stays empty.
        XCTAssertTrue(vm.decided.isEmpty)
        XCTAssertEqual(vm.decidedVisibleCount, 0)
        XCTAssertTrue(vm.decidedOriginConvoIDs.isEmpty)
    }

    /// The For you list opens on Open, and the tab is the host's to set.
    func testForYouTabStartsOnOpen() {
        let vm = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: FakeSync())
        XCTAssertEqual(vm.forYouTab, .open)
        vm.forYouTab = .closed
        XCTAssertEqual(vm.forYouTab, .closed)
    }
}

/// Polls `condition` until it's true or `timeout` elapses, throwing on
/// timeout instead of failing via a fixed sleep.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private struct WaitTimeoutError: Error, CustomStringConvertible {
    var description: String { "condition not met before timeout" }
}
@MainActor
private func waitUntil(timeout: TimeInterval = 2.0, pollInterval: UInt64 = 5_000_000,
                       _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw WaitTimeoutError() }
        try await Task.sleep(nanoseconds: pollInterval)
    }
}
