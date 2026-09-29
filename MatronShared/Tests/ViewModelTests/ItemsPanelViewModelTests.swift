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
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?) async {}
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
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem {
        rankCalls.append((id, change)); if failRank { throw JournalAPIError.transport("x") }
        return TrackerItem(id: id, num: 0, kind: .task, title: "", originConvoID: "c1")
    }
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
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

    // MARK: - Decided section (Dan, 2026-09-29: answered/decided items stay findable)

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

    /// "The last ~14 days or the latest 20" — whichever is bigger, since
    /// the goal is showing enough to cover both readings, not the
    /// intersection of them.
    func testDefaultDecidedWindowIsTheLargerOfRecencyOrMinimumCount() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Every item well within 14 days: fewer than the 20-item minimum,
        // so the minimum wins (capped at however many actually exist).
        let fewRecent = (0..<5).map { i in
            t("r\(i)", num: i, kind: .question, state: .closed, rank: 0,
              closed: now.timeIntervalSince1970 - Double(i) * 3600, resolution: .answered)
        }
        XCTAssertEqual(ItemsPanelViewModel.defaultDecidedWindow(fewRecent, now: now), 5, "fewer than 20 total — show them all")

        // 30 items, only the first 10 within 14 days: the 20-item minimum
        // still wins over the narrower recency count.
        let mixed = (0..<30).map { i -> TrackerItem in
            let ageDays = i < 10 ? Double(i) : 14.0 + Double(i)
            return t("m\(i)", num: i, kind: .decision, state: .closed, rank: 0,
                     closed: now.timeIntervalSince1970 - ageDays * 86400, resolution: .decided)
        }
        XCTAssertEqual(ItemsPanelViewModel.defaultDecidedWindow(mixed, now: now), 20, "recency count (10) < minimum (20) → minimum wins")

        // 30 items, 25 within the last 14 days: recency now exceeds the
        // 20-item minimum, so recency wins.
        let mostlyRecent = (0..<30).map { i -> TrackerItem in
            let ageDays = i < 25 ? Double(i) * 0.5 : 20.0 + Double(i)
            return t("p\(i)", num: i, kind: .decision, state: .closed, rank: 0,
                     closed: now.timeIntervalSince1970 - ageDays * 86400, resolution: .decided)
        }
        XCTAssertEqual(ItemsPanelViewModel.defaultDecidedWindow(mostlyRecent, now: now), 25, "recency count (25) > minimum (20) → recency wins")
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
        let old: TimeInterval = 20 * 86400   // outside the 14-day window
        let items = (0..<30).map { i in
            t("d\(i)", num: i, kind: .decision, state: .closed, rank: 0, closed: old - Double(i), resolution: .decided)
        }
        store.cont?.yield(items)
        try await waitUntil { vm.decided.count == 30 }
        XCTAssertEqual(vm.decidedVisibleCount, 20, "none within 14 days — the 20-item minimum sets the default window")
        XCTAssertTrue(vm.hasMoreDecided)

        vm.showMoreDecided()
        XCTAssertEqual(vm.decidedVisibleCount, 30, "grew from what's already local")
        XCTAssertFalse(vm.hasMoreDecided, "everything local is now shown")

        store.cont?.yield(items + [t("unrelated", num: 99, rank: 5)])
        try await waitUntil { vm.sections.tasks.contains { $0.id == "unrelated" } }
        XCTAssertEqual(vm.decidedVisibleCount, 30, "the user's own expansion survives an unrelated store emission")
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

    /// `DecidedSectionMemory` persists across VM instances (a relaunch, in
    /// the real app) — mirrors `ItemReadMemory`'s own instance-agnostic
    /// contract test.
    func testToggleDecidedExpandedPersistsViaMemory() {
        let suiteName = "ItemsPanelViewModelTests.decided"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let memory = DecidedSectionMemory(defaults: defaults)

        let vm1 = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: FakeSync(), decidedMemory: memory)
        XCTAssertFalse(vm1.isDecidedExpanded, "collapsed by default")
        vm1.toggleDecidedExpanded()
        XCTAssertTrue(vm1.isDecidedExpanded)

        let vm2 = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: FakeSync(), decidedMemory: memory)
        XCTAssertTrue(vm2.isDecidedExpanded, "a fresh VM (a relaunch) reads the persisted state")
    }
}

/// Polls `condition` until it's true or `timeout` elapses, throwing on
/// timeout instead of failing via a fixed sleep.
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
