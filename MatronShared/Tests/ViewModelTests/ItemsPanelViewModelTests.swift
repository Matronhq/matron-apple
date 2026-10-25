import XCTest
import MatronModels
@testable import MatronJournal
@testable import MatronViewModels

private final class FakeItemsStore: ItemsStoreReading, @unchecked Sendable {
    var cont: AsyncStream<[TrackerItem]>.Continuation?
    var createsCont: AsyncStream<[ItemOutboxRecord]>.Continuation?
    /// Every `itemsStream` subscription opened, in order: each one is a
    /// whole-table observation the store re-fetches after every item write.
    var subscribedScopes: [ItemsScope] = []
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> {
        subscribedScopes.append(scope)
        return AsyncStream { self.cont = $0 }
    }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func comments(itemID: String) throws -> [TrackerComment] { [] }
    func item(id: String) throws -> TrackerItem? { nil }
    /// Each item's outbox rows, as `itemOutboxRows` reads them.
    var outbox: [String: [ItemOutboxRecord]] = [:]
    var outboxConts: [String: AsyncStream<[ItemOutboxRecord]>.Continuation] = [:]
    func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { outbox[itemID] ?? [] }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> {
        AsyncStream { c in
            self.outboxConts[itemID] = c
            c.yield(self.outbox[itemID] ?? [])
        }
    }
    func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { self.createsCont = $0 } }
}
/// Main-actor bound: its async methods otherwise run off-main and race the test's reads.
@MainActor
private final class FakeSync: ItemsSyncing {
    var refreshed: [ItemsScope] = []; var created: [NewItem] = []; var refetched: [String] = []
    /// Values `supportedStream()` yields, in order, on each call.
    var supportedValues: [Bool] = [true]
    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { refreshed.append(scope); return .succeeded }
    func refreshItem(id: String) async { refetched.append(id) }
    /// Every `enqueueComment` call, as (item, body, action, replyTo).
    var comments: [(itemID: String, body: String, action: String?, replyTo: String?)] = []
    /// Runs inside `enqueueComment`, with the tap's item and outbox id —
    /// what the drain did with it (left it queued, refused it).
    var onEnqueue: ((_ itemID: String, _ localID: String) -> Void)?
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {
        comments.append((itemID, body, action, replyTo))
        onEnqueue?(itemID, localID)
    }
    func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
    var createSucceeds = true
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { created.append(new); return createSucceeds }
    func supportedStream() async -> AsyncStream<Bool> {
        let values = supportedValues
        return AsyncStream { c in for v in values { c.yield(v) }; c.finish() }
    }
}
@MainActor
private final class FakeAPI: ItemsProviding {
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

    /// An item the user has just answered is done for them while its agent
    /// has yet to close it: it is on the Done tab at once, at the top. One
    /// waiting on the user again, or one only agents have touched, is not.
    func testAnAnsweredOpenItemIsDoneAtOnceAndOnTop() {
        func item(_ id: String, num: Int, state: ItemState = .open, awaiting: ItemAwaiting?,
                  closed: TimeInterval? = nil, input: TimeInterval?) -> TrackerItem {
            TrackerItem(id: id, num: num, kind: .question, state: state, resolution: state == .closed ? .answered : nil,
                        awaiting: awaiting, title: id, originConvoID: "c1",
                        updatedAt: Date(timeIntervalSince1970: closed ?? input ?? 1),
                        closedAt: closed.map { Date(timeIntervalSince1970: $0) },
                        lastUserInputAt: input.map { Date(timeIntervalSince1970: $0) })
        }
        let items = [
            item("closedEarlier", num: 1, state: .closed, awaiting: nil, closed: 800, input: 700),
            item("tappedJustNow", num: 2, awaiting: .agent, input: 900),
            item("askedAgain", num: 3, awaiting: .user, input: 950),
            item("agentsOnly", num: 4, awaiting: .agent, input: nil),
            TrackerItem(id: "filedByUser", num: 5, kind: .question, awaiting: .agent, title: "filedByUser",
                        originConvoID: "c1", createdBy: .user, lastUserInputAt: Date(timeIntervalSince1970: 990)),
        ]
        XCTAssertEqual(ItemsPanelViewModel.sections(from: items).decided.map(\.id), ["tappedJustNow", "closedEarlier"])
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

    /// Every item write re-fetches each open item observation, and an
    /// `.all` one reads every item ever synced. A conversation's own items
    /// pane observes its conversation and nothing else.
    func testAPerConversationPanelOpensOneScopedItemsObservation() async throws {
        let store = FakeItemsStore()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: FakeSync())
        vm.start()
        try await waitUntil { store.cont != nil }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.subscribedScopes, [.convo("c1")])
    }

    /// The app-wide instance derives `awaitingYou` from the one `.all`
    /// observation that also feeds its sections.
    func testTheAppWideInstanceOpensOneAllObservation() async throws {
        let store = FakeItemsStore()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: FakeSync())
        vm.start()
        try await waitUntil { store.cont != nil }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.subscribedScopes, [.all])
    }

    func testNilConvoStartsInAllScope() {
        let vm = ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: FakeSync())
        XCTAssertNil(vm.convoID)
        XCTAssertEqual(vm.scope, .all)
        XCTAssertEqual(vm.needsYouCount, 0)
    }

    func testAwaitingYouIsCrossConversationNewestFirst() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        let mine = t("q", num: 1, kind: .question, awaiting: .user, rank: 1)   // updatedAt = 1
        let withAgent = t("a", num: 2, rank: 2)                                // awaiting .agent → excluded
        let foreign = TrackerItem(id: "f", num: 9, kind: .decision, awaiting: .user, rank: 1, title: "F",
                                  originConvoID: "c2", updatedAt: Date(timeIntervalSince1970: 9))
        store.cont?.yield([mine, withAgent, foreign])
        try await waitUntil { vm.awaitingYouCount == 2 }
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["f", "q"], "needsUser only, newest updatedAt first, every conversation")
        XCTAssertEqual(vm.needsYouCount, 0, "the app-wide instance has no conversation badge")
    }

    /// Only the app-wide instance backs the For you list and the shells'
    /// badge; a conversation's own pane leaves `awaitingYou` empty, even
    /// with its scope picker on All.
    func testAPerConversationPanelLeavesAwaitingYouEmpty() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        vm.scope = .all
        try await waitUntil { store.cont != nil && store.subscribedScopes.last == .all }
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
        try await waitUntil { vm.sections.needsYou.count == 1 }
        XCTAssertEqual(vm.needsYouCount, 1)
        XCTAssertTrue(vm.awaitingYou.isEmpty)
        XCTAssertEqual(vm.awaitingYouCount, 0)
    }

    // MARK: - Spare allowance

    private func labelled(_ item: TrackerItem, _ labels: [String]) -> TrackerItem {
        TrackerItem(id: item.id, num: item.num, kind: item.kind, state: item.state, resolution: item.resolution,
                    awaiting: item.awaiting, rank: item.rank, title: item.title, labels: labels,
                    originConvoID: item.originConvoID, updatedAt: item.updatedAt, closedAt: item.closedAt)
    }

    /// Open tasks labelled spare-allowance, in task order; closed ones,
    /// other kinds and unlabelled tasks stay out.
    func testSpareAllowanceBacklogIsOpenLabelledTasksInRankOrder() {
        let items = [
            labelled(t("later", num: 1, rank: 3), ["spare-allowance"]),
            labelled(t("next", num: 2, rank: 1), ["spare-allowance", "dispatched"]),
            t("plain", num: 3, rank: 2),
            labelled(t("done", num: 4, state: .closed, rank: 0, closed: 10), ["spare-allowance"]),
            labelled(t("question", num: 5, kind: .question, awaiting: .user, rank: 0), ["spare-allowance"]),
        ]
        XCTAssertEqual(ItemsPanelViewModel.spareAllowanceBacklog(items).map(\.id), ["next", "later"])
    }

    func testTheAppWideInstanceFillsTheSpareAllowanceTab() async throws {
        let store = FakeItemsStore()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: FakeSync())
        vm.start()
        try await waitUntil { store.cont != nil }
        store.cont?.yield([labelled(t("b", num: 2, rank: 2), ["spare-allowance"]),
                           labelled(t("a", num: 1, rank: 1), ["spare-allowance"]),
                           t("c", num: 3, rank: 0)])
        try await waitUntil { vm.spareAllowance.count == 2 }
        XCTAssertEqual(vm.spareAllowance.map(\.id), ["a", "b"])
        XCTAssertEqual(ForYouTab.spare.title, "Spare allowance")
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
        try await waitUntil { store.cont != nil }
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), notice("n", num: 2)])
        try await waitUntil { vm.awaitingYouCount == 2 }
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["n", "q"])
    }

    /// A notice closed by its "Seen" tap stays findable in the Done tab,
    /// in the same newest-first order as closed questions and decisions.
    func testDecidedIncludesClosedNotices() {
        let items = [
            notice("seen", num: 1, state: .closed, closed: 50),
            t("answered", num: 2, kind: .question, state: .closed, rank: 0, closed: 40, resolution: .answered),
            notice("open", num: 3),
            notice("older", num: 4, state: .closed, closed: 30),
        ]
        XCTAssertEqual(ItemsPanelViewModel.sections(from: items).decided.map(\.id), ["seen", "answered", "older"])
        XCTAssertTrue(ItemsPanelViewModel.isDecided(items[0]))
        XCTAssertFalse(ItemsPanelViewModel.isDecided(items[2]), "an open notice still belongs to Needs you")
    }

    /// The row's Seen button posts the item's own action — body and action
    /// both "Seen", no reply_to — and the row leaves at once, before the
    /// journal has closed it.
    func testMarkSeenPostsTheSeenActionAndHidesTheRow() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        let n = notice("n", num: 2)
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), n])
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
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1), n])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["q"])
        await vm.markSeen("n")
        XCTAssertEqual(sync.comments.count, 1)
    }

    private func consentAsk(_ id: String, num: Int, actions: [String] = ["Approve", "Decline"],
                            labels: [String] = ["consent"]) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .question, awaiting: .user, title: "box-b asks to chat with box-a",
                    labels: labels, originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: Double(num)),
                    actions: actions)
    }

    private func outboxRow(_ localID: String, itemID: String, action: String, refused reason: String? = nil) -> ItemOutboxRecord {
        ItemOutboxRecord(localID: localID, itemID: itemID, op: "comment",
                         payloadJSON: #"{"body":"\#(action)","action":"\#(action)","attachments":[]}"#,
                         createdAt: 1, attempts: reason == nil ? 0 : 1, lastError: reason,
                         rejectedAt: reason == nil ? nil : 2)
    }

    /// A consent ask's Approve under its row posts the item's action, as the
    /// card's answer would, and the row leaves at once.
    func testAnswerPostsTheConsentActionAndHidesTheRow() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        store.cont?.yield([consentAsk("a", num: 2), t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
        try await waitUntil { vm.awaitingYouCount == 2 }

        await vm.answer("a", label: "Approve")
        XCTAssertEqual(sync.comments.count, 1)
        XCTAssertEqual(sync.comments.first?.itemID, "a")
        XCTAssertEqual(sync.comments.first?.body, "Approve")
        XCTAssertEqual(sync.comments.first?.action, "Approve")
        XCTAssertNil(sync.comments.first?.replyTo)
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["q"], "hidden at once")
        XCTAssertNil(vm.error)

        // A second tap while the first is on its way sends nothing more.
        await vm.answer("a", label: "Decline")
        XCTAssertEqual(sync.comments.count, 1)
    }

    /// Only an open consent ask whose every button is a one-tap answer is
    /// answered from its row, and only with one of its own labels.
    func testAnswerIgnoresRowsWithoutOneTapConsentAnswers() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        store.cont?.yield([
            consentAsk("a", num: 1),
            consentAsk("h", num: 2, actions: ["Accept", "Pick a box", "Decline"]),
            consentAsk("p", num: 3, labels: []),
        ])
        try await waitUntil { vm.awaitingYouCount == 3 }
        await vm.answer("a", label: "Accept")
        await vm.answer("h", label: "Accept")
        await vm.answer("p", label: "Approve")
        await vm.answer("missing", label: "Approve")
        XCTAssertTrue(sync.comments.isEmpty)
        XCTAssertEqual(vm.awaitingYouCount, 3)
    }

    /// A tap the journal refuses (the ask was already answered elsewhere)
    /// refetches the item, brings the row back and says why in the
    /// journal's own words.
    func testRefusedAnswerBringsTheRowBackWithTheJournalsReason() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        sync.onEnqueue = { itemID, localID in
            store.outbox[itemID] = [self.outboxRow(localID, itemID: itemID, action: "Approve",
                                                   refused: "Already answered: this request was approved.")]
        }
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        store.cont?.yield([consentAsk("a", num: 2)])
        try await waitUntil { vm.awaitingYouCount == 1 }

        await vm.answer("a", label: "Approve")
        XCTAssertEqual(sync.refetched, ["a"])
        XCTAssertEqual(vm.awaitingYou.map(\.id), ["a"], "back on the list")
        XCTAssertEqual(vm.error, "Already answered: this request was approved.")
    }

    /// A Seen tap that waited in the outbox and is refused later brings
    /// its row back too, rather than leaving it hidden for good.
    func testSeenRefusedAfterWaitingBringsTheRowBack() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        var queuedID: String?
        sync.onEnqueue = { itemID, localID in
            queuedID = localID
            store.outbox[itemID] = [self.outboxRow(localID, itemID: itemID, action: "Seen")]
        }
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        store.cont?.yield([notice("n", num: 2)])
        try await waitUntil { vm.awaitingYouCount == 1 }

        await vm.markSeen("n")
        XCTAssertEqual(vm.awaitingYouCount, 0, "hidden while it waits")
        try await waitUntil { store.outboxConts["n"] != nil }
        let localID = try XCTUnwrap(queuedID)
        store.outboxConts["n"]?.yield([outboxRow(localID, itemID: "n", action: "Seen", refused: "The journal refused this reply (error 400).")])
        try await waitUntil { vm.awaitingYouCount == 1 }
        XCTAssertEqual(vm.error, "The journal refused this reply (error 400).")
    }

    func testRowConsentAnswersRule() {
        XCTAssertEqual(consentAsk("a", num: 1).rowConsentAnswers, ["Approve", "Decline"])
        XCTAssertEqual(consentAsk("a", num: 1, actions: ["Accept", "Decline"]).rowConsentAnswers, ["Accept", "Decline"])
        XCTAssertEqual(consentAsk("a", num: 1, actions: ["Accept", "Pick a box", "Decline"]).rowConsentAnswers, [])
        XCTAssertEqual(consentAsk("a", num: 1, actions: []).rowConsentAnswers, [])
        XCTAssertEqual(consentAsk("a", num: 1, labels: []).rowConsentAnswers, [])
        let withAgent = TrackerItem(id: "a", num: 1, kind: .question, awaiting: .agent, title: "x", labels: ["consent"],
                                    originConvoID: "c1", actions: ["Approve", "Decline"])
        XCTAssertEqual(withAgent.rowConsentAnswers, [])
        let closed = TrackerItem(id: "a", num: 1, kind: .question, state: .closed, resolution: .decided, title: "x",
                                 labels: ["consent"], originConvoID: "c1", actions: ["Approve", "Decline"])
        XCTAssertEqual(closed.rowConsentAnswers, [])
    }

    /// Only an open notice offering "Seen" takes the one-tap answer.
    func testMarkSeenIgnoresAnythingButANotice() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil }
        let question = TrackerItem(id: "q", num: 1, kind: .question, awaiting: .user, title: "Q", originConvoID: "c1",
                                   actions: ["Seen"])
        store.cont?.yield([question])
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
        try await waitUntil { store.cont != nil }
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
        try await waitUntil { vm.awaitingYouCount == 1 }
        store.cont?.yield([])
        try await waitUntil { vm.awaitingYouCount == 0 }
        vm.stop()
        store.cont?.yield([t("q", num: 1, kind: .question, awaiting: .user, rank: 1)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.awaitingYouCount, 0, "stop() cancels the subscription awaitingYou follows")
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
        try await waitUntil { store.cont != nil }
        store.cont?.yield([t("q", num: 2, kind: .question, awaiting: .user, rank: 1, origin: "c1")])
        try await waitUntil { vm.awaitingYou.count == 1 }
        XCTAssertEqual(vm.awaitingYouCount, 1)
        XCTAssertEqual(vm.awaitingOriginConvoIDs, ["c1"])

        let changed = ChangeFlag()
        withObservationTracking { _ = vm.awaitingOriginConvoIDs; _ = vm.awaitingYouCount } onChange: { changed.set() }
        store.cont?.yield([t("q", num: 2, kind: .question, awaiting: .user, rank: 9, origin: "c1")])
        try await waitUntil { vm.awaitingYou.first?.rank == 9 }
        XCTAssertFalse(changed.value, "same count, same origins: nothing the shells read moved")

        store.cont?.yield([t("q", num: 2, kind: .question, awaiting: .user, rank: 9, origin: "c1"),
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

/// What the window's lists read changes only when its content does, and
/// lands through the live-update gate when one is given.
@MainActor
final class ItemsPanelLiveUpdateTests: XCTestCase {
    private func q(_ id: String, num: Int, awaiting: ItemAwaiting? = .user, state: ItemState = .open) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .question, state: state, resolution: state == .closed ? .answered : nil,
                    awaiting: awaiting, rank: Double(num), title: "Q\(num)", originConvoID: "c1",
                    updatedAt: Date(timeIntervalSince1970: Double(num)),
                    closedAt: state == .closed ? Date(timeIntervalSince1970: Double(num)) : nil)
    }

    func testAnIdenticalEmissionNotifiesNothing() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        sync.supportedValues = [true, true]
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try await waitUntil { store.cont != nil && store.createsCont != nil }
        let items = [q("a", num: 1), q("b", num: 2, awaiting: nil, state: .closed)]
        store.cont?.yield(items)
        store.createsCont?.yield([])
        try await waitUntil { vm.awaitingYou.count == 1 && vm.decided.count == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)

        let changed = ChangeFlag()
        withObservationTracking {
            _ = vm.sections; _ = vm.awaitingYou; _ = vm.decided; _ = vm.needsYouCount
            _ = vm.pendingCreates; _ = vm.isSupported
        } onChange: { changed.set() }
        store.cont?.yield(items)
        store.createsCont?.yield([])
        store.cont?.yield(items)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(changed.value, "identical emissions publish nothing")

        store.cont?.yield(items + [q("c", num: 3)])
        try await waitUntil { vm.awaitingYou.count == 2 }
        XCTAssertTrue(changed.value, "a real change still publishes")
    }

    func testAHeldGateParksTheListsUntilItOpens() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let gate = LiveUpdateGate(interval: .zero)
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: sync, gate: gate)
        vm.start()
        try await waitUntil { store.cont != nil }
        store.cont?.yield([q("a", num: 1)])
        try await waitUntil { vm.awaitingYouCount == 1 }

        gate.beginHold()
        store.cont?.yield([q("a", num: 1), q("b", num: 2)])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.awaitingYouCount, 1, "held while the user scrolls")
        XCTAssertEqual(vm.sections.needsYou.map(\.id), ["a"])
        gate.endHold()
        XCTAssertEqual(vm.awaitingYouCount, 2)
        XCTAssertEqual(vm.sections.needsYou.map(\.id), ["b", "a"])
    }

    /// A parked publish from before a scope change never lands after it.
    func testAParkedPublishFromAnOldScopeIsDropped() async throws {
        let store = FakeItemsStore(); let sync = FakeSync()
        let gate = LiveUpdateGate(interval: .zero)
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync, gate: gate)
        vm.start()
        try await waitUntil { store.cont != nil }
        gate.beginHold()
        let old = store.cont
        old?.yield([q("a", num: 1)])
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.scope = .all
        gate.endHold()
        XCTAssertTrue(vm.sections.needsYou.isEmpty, "the old scope's emission is stale")
    }
}

/// The app-wide instance with the store's `store.changeFeed` flag on: it
/// reads its sections from the store's items index instead of sorting every
/// item after every item write, and shows exactly what the flag-off path
/// shows.
@MainActor
final class ItemsPanelItemsIndexTests: XCTestCase {
    private func store(changeFeed: Bool) throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: StoreMetrics(), usesChangeFeed: changeFeed)
    }

    private func item(_ id: String, num: Int, kind: ItemKind = .task, state: ItemState = .open,
                      awaiting: ItemAwaiting? = .agent, rank: Double = 1024, title: String? = nil,
                      origin: String = "c1", updated: TimeInterval = 1, input: TimeInterval? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: state == .closed ? .answered : nil,
                    awaiting: awaiting, rank: rank, title: title ?? "Item \(num)", originConvoID: origin,
                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: updated),
                    closedAt: state == .closed ? Date(timeIntervalSince1970: updated) : nil,
                    lastUserInputAt: input.map { Date(timeIntervalSince1970: $0) })
    }

    /// The same writes to two stores, one with the flag on and one with it
    /// off, and an app-wide instance on each: after every write both show
    /// the same sections, awaiting list, Done tab and counts, and those are
    /// `sections(from:)` over the store's items.
    func testTheIndexPathShowsExactlyWhatTheObservationPathShows() async throws {
        let indexed = try store(changeFeed: true), observed = try store(changeFeed: false)
        let onIndex = ItemsPanelViewModel(convoID: nil, store: indexed, api: FakeAPI(), sync: FakeSync())
        let onObservation = ItemsPanelViewModel(convoID: nil, store: observed, api: FakeAPI(), sync: FakeSync())
        XCTAssertTrue(onIndex.readsItemsIndex)
        XCTAssertFalse(onObservation.readsItemsIndex)
        onIndex.start(); onObservation.start()
        defer { onIndex.stop(); onObservation.stop() }

        let writes: [(String, (JournalStore) throws -> Void)] = [
            ("file", { try $0.upsertItems([
                self.item("t1", num: 1, rank: 2), self.item("t2", num: 2, rank: 1, origin: "c2"),
                self.item("q3", num: 3, kind: .question, awaiting: .user, updated: 3),
                self.item("q4", num: 4, kind: .question, awaiting: .user, origin: "c2", updated: 3),
                self.item("d5", num: 5, kind: .decision, awaiting: nil),
                self.item("n6", num: 6, kind: .notice, awaiting: .user, updated: 2),
            ]) }),
            ("answer", { try $0.upsertItems([self.item("q3", num: 3, kind: .question, updated: 4, input: 4)]) }),
            ("close", { try $0.upsertItems([self.item("q3", num: 3, kind: .question, state: .closed, awaiting: nil,
                                                      updated: 5, input: 4)]) }),
            ("rerank", { try $0.upsertItems([self.item("t1", num: 1, rank: 0, updated: 6)]) }),
            ("close task", { try $0.upsertItems([self.item("t2", num: 2, state: .closed, awaiting: nil, origin: "c2",
                                                           updated: 7)]) }),
            ("delete", { try $0.db.write { db in try db.execute(sql: "DELETE FROM item WHERE id = 'n6'") } }),
            ("wipe", { try $0.wipeItems() }),
            ("refill", { try $0.upsertItems([self.item("q9", num: 9, kind: .question, awaiting: .user, updated: 9)]) }),
        ]
        for (what, write) in writes {
            try write(indexed); try write(observed)
            let expected = ItemsPanelViewModel.sections(from: try observed.items(scope: .all))
            try await waitUntil {
                onIndex.sections == expected && onObservation.sections == expected
                    && onIndex.awaitingYou == onObservation.awaitingYou && onIndex.decided == onObservation.decided
            }
            XCTAssertEqual(onIndex.awaitingYou, expected.needsYou, what)
            XCTAssertEqual(onIndex.awaitingYouCount, onObservation.awaitingYouCount, what)
            XCTAssertEqual(onIndex.awaitingOriginConvoIDs, onObservation.awaitingOriginConvoIDs, what)
            XCTAssertEqual(onIndex.decidedOriginConvoIDs, onObservation.decidedOriginConvoIDs, what)
            XCTAssertEqual(onIndex.decidedVisibleCount, onObservation.decidedVisibleCount, what)
        }
        XCTAssertEqual(onIndex.awaitingYou.map(\.id), ["q9"], "the wipe reloaded the index, and it went on from there")
        XCTAssertNil(observed.startedItemsIndex, "the flag off runs no index")
        XCTAssertEqual(observed.changeFeed.subscriberCount, 0)
    }

    /// A drag staged on the index path still wins over item writes that
    /// land while the journal has not confirmed it.
    func testStagedRanksStillOverlayTheIndexSections() async throws {
        let store = try store(changeFeed: true)
        try store.upsertItems([item("a", num: 1, rank: 1), item("b", num: 2, rank: 2), item("c", num: 3, rank: 3)])
        let api = FakeAPI()
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: api, sync: FakeSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.sections.tasks.map(\.id) == ["a", "b", "c"] }

        let (gate, open) = AsyncStream<Void>.makeStream()
        api.rankHold = { for await _ in gate { return } }
        let move = Task { await vm.move(itemID: "c", toIndex: 0) }
        try await waitUntil { vm.sections.tasks.map(\.id) == ["c", "a", "b"] }

        // An unrelated write mid-flight: the index re-delivers the tasks
        // with "c" still at its stored rank.
        try store.upsertItems([item("b", num: 2, rank: 2, title: "Renamed", updated: 2)])
        try await waitUntil { vm.sections.tasks.first { $0.id == "b" }?.title == "Renamed" }
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "a", "b"], "an unconfirmed move survives an index delivery")

        open.yield(); await move.value
        try store.upsertItems([item("b", num: 2, rank: 2, title: "Again", updated: 3)])
        try await waitUntil { vm.sections.tasks.first { $0.id == "b" }?.title == "Again" }
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a", "b", "c"], "confirmed: the store's ranks rule again")
    }

    /// A write to one task publishes the task list, and leaves the
    /// awaiting list and the Done tab, which the shells and For you read,
    /// unnotified.
    func testATaskWriteLeavesTheAwaitingListAndDoneTabAlone() async throws {
        let store = try store(changeFeed: true)
        try store.upsertItems([item("t", num: 1), item("q", num: 2, kind: .question, awaiting: .user),
                               item("x", num: 3, kind: .question, state: .closed, awaiting: nil)])
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: FakeAPI(), sync: FakeSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.awaitingYouCount == 1 && vm.decided.count == 1 && vm.sections.tasks.count == 1 }

        let listsChanged = ChangeFlag(), tasksChanged = ChangeFlag()
        withObservationTracking {
            _ = vm.awaitingYou; _ = vm.awaitingYouCount; _ = vm.awaitingOriginConvoIDs
            _ = vm.decided; _ = vm.decidedOriginConvoIDs; _ = vm.decidedVisibleCount
        } onChange: { listsChanged.set() }
        withObservationTracking { _ = vm.sections } onChange: { tasksChanged.set() }

        try store.upsertItems([item("t", num: 1, title: "Renamed", updated: 2)])
        try await waitUntil { vm.sections.tasks.first?.title == "Renamed" }
        XCTAssertTrue(tasksChanged.value)
        XCTAssertFalse(listsChanged.value, "nothing the shells or For you read was written")
    }

    /// A chat's pane on two stores, flag on and off, through the same
    /// writes: the same sections, badge and pending rows after every write,
    /// in its own scope and then with its picker on All.
    func testAChatsPaneShowsExactlyWhatTheObservationPathShows() async throws {
        let indexed = try store(changeFeed: true), observed = try store(changeFeed: false)
        let onIndex = ItemsPanelViewModel(convoID: "c1", store: indexed, api: FakeAPI(), sync: FakeSync())
        let onObservation = ItemsPanelViewModel(convoID: "c1", store: observed, api: FakeAPI(), sync: FakeSync())
        onIndex.start(); onObservation.start()
        defer { onIndex.stop(); onObservation.stop() }

        let writes: [(String, (JournalStore) throws -> Void)] = [
            ("file", { try $0.upsertItems([
                self.item("t1", num: 1, rank: 2), self.item("t2", num: 2, rank: 1, origin: "c2"),
                self.item("q3", num: 3, kind: .question, awaiting: .user, updated: 3),
                self.item("q4", num: 4, kind: .question, awaiting: .user, origin: "c2", updated: 3),
                self.item("d5", num: 5, kind: .decision, awaiting: nil),
            ]) }),
            ("elsewhere", { try $0.upsertItems([self.item("t2", num: 2, rank: 0, title: "Moved", origin: "c2", updated: 4)]) }),
            ("answer", { try $0.upsertItems([self.item("q3", num: 3, kind: .question, updated: 5, input: 5)]) }),
            ("move here", { try $0.upsertItems([self.item("q4", num: 4, kind: .question, awaiting: .user, updated: 6)]) }),
            ("close", { try $0.upsertItems([self.item("t1", num: 1, state: .closed, awaiting: nil, updated: 7)]) }),
            ("delete", { try $0.db.write { db in try db.execute(sql: "DELETE FROM item WHERE id = 'd5'") } }),
        ]
        for scope in [ItemsScope.convo("c1"), .all] {
            onIndex.scope = scope; onObservation.scope = scope
            for (what, write) in writes {
                try write(indexed); try write(observed)
                let expected = ItemsPanelViewModel.sections(from: try observed.items(scope: scope))
                try await waitUntil { onIndex.sections == expected && onObservation.sections == expected }
                XCTAssertEqual(onIndex.needsYouCount, onObservation.needsYouCount, "\(scope) \(what)")
                XCTAssertEqual(onIndex.pendingCreates, onObservation.pendingCreates, "\(scope) \(what)")
            }
        }
        XCTAssertNil(observed.startedItemsIndex)
    }

    /// A write in another conversation leaves a chat's pane unnotified.
    func testAWriteInAnotherConversationLeavesAChatsPaneAlone() async throws {
        let store = try store(changeFeed: true)
        try store.upsertItems([item("a", num: 1), item("b", num: 2, origin: "c2")])
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: FakeSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.sections.tasks.map(\.id) == ["a"] }

        let changed = ChangeFlag()
        withObservationTracking { _ = vm.sections; _ = vm.needsYouCount } onChange: { changed.set() }
        try store.upsertItems([item("b", num: 2, kind: .question, awaiting: .user, origin: "c2", updated: 2)])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(changed.value, "c2's write did not reach c1's pane")

        try store.upsertItems([item("a", num: 1, title: "Renamed", updated: 3)])
        try await waitUntil { vm.sections.tasks.first?.title == "Renamed" }
        XCTAssertTrue(changed.value)
    }

    /// With the flag on every panel reads the index, a conversation's pane
    /// included; with it off, none does.
    func testEveryPanelReadsTheIndexWithTheFlagOnAndNoneWithItOff() throws {
        let on = try store(changeFeed: true), off = try store(changeFeed: false)
        XCTAssertTrue(ItemsPanelViewModel(convoID: "c1", store: on, api: FakeAPI(), sync: FakeSync()).readsItemsIndex)
        XCTAssertTrue(ItemsPanelViewModel(convoID: nil, store: on, api: FakeAPI(), sync: FakeSync()).readsItemsIndex)
        XCTAssertFalse(ItemsPanelViewModel(convoID: "c1", store: off, api: FakeAPI(), sync: FakeSync()).readsItemsIndex)
        XCTAssertFalse(ItemsPanelViewModel(convoID: nil, store: off, api: FakeAPI(), sync: FakeSync()).readsItemsIndex)
        XCTAssertFalse(ItemsPanelViewModel(convoID: nil, store: FakeItemsStore(), api: FakeAPI(), sync: FakeSync()).readsItemsIndex)
    }
}
