import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

private final class FakeItemsStore: ItemsStoreReading, @unchecked Sendable {
    var cont: AsyncStream<[TrackerItem]>.Continuation?
    var createsCont: AsyncStream<[ItemOutboxRecord]>.Continuation?
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { self.cont = $0 } }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { self.createsCont = $0 } }
}
private final class FakeSync: ItemsSyncing, @unchecked Sendable {
    var refreshed: [ItemsScope] = []; var created: [NewItem] = []; var refetched: [String] = []
    /// Values `supportedStream()` yields, in order, on each call.
    var supportedValues: [Bool] = [true]
    func refresh(scope: ItemsScope) async { refreshed.append(scope) }
    func refreshItem(id: String) async { refetched.append(id) }
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {}
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
