import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// The indicator at the foot of an item's thread while the agent that owns
/// the item is busy, from the item's `working` state.
@MainActor
final class ItemWorkingIndicatorTests: XCTestCase {
    private static func item(_ working: ItemWorking?) -> TrackerItem {
        TrackerItem(id: "it_1", num: 7, kind: .question, title: "Ship it?", originConvoID: "c-origin", working: working)
    }

    private func makeViewModel(store: Store, sync: Sync = Sync(), context: ContextStore = ContextStore()) -> ItemDetailViewModel {
        ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync, contextStore: context)
    }

    func testAnIdleItemShowsNothing() async throws {
        let store = Store()
        let vm = makeViewModel(store: store)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(nil))
        try await waitUntil { vm.item != nil }
        XCTAssertNil(vm.workingIndicator)
        vm.stop()
    }

    func testARunningOwnerShowsWorking() async throws {
        let store = Store()
        let vm = makeViewModel(store: store)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { vm.workingIndicator == .working }
        vm.stop()
    }

    /// The reply to a tap already carries `queued`: the indicator is up
    /// before the agent's turn has started, and comes down by itself when
    /// nothing picks the reply up.
    func testAQueuedReplyShowsStartingUntilItLapses() async throws {
        let store = Store()
        let vm = makeViewModel(store: store)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .queued, since: Date(), until: Date().addingTimeInterval(0.3))))
        try await waitUntil { vm.workingIndicator == .starting }
        try await waitUntil { vm.workingIndicator == nil }
        vm.stop()
    }

    func testAQueuedStateAlreadyPastItsDeadlineShowsNothing() async throws {
        let store = Store()
        let vm = makeViewModel(store: store)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .queued, since: Date().addingTimeInterval(-700),
                                                    until: Date().addingTimeInterval(-100))))
        try await waitUntil { vm.item != nil }
        XCTAssertNil(vm.workingIndicator)
        vm.stop()
    }

    /// Another person's item has no owner conversation on this account.
    func testASharedItemNeverShowsTheIndicator() async throws {
        let store = Store()
        let vm = makeViewModel(store: store)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 7, kind: .question, title: "Ship it?", originConvoID: "",
                                          working: ItemWorking(state: .running, since: Date())))
        try await waitUntil { vm.item != nil && vm.loadedCommentCount != nil }
        XCTAssertNil(vm.workingIndicator)
        vm.stop()
    }

    /// A copy that says `running` is only as old as its last fetch: a
    /// device with nothing of its own to set it against waits for the
    /// opening read.
    func testACachedRunningCopyWaitsForTheOpeningRead() async throws {
        let store = Store(); let sync = Sync()
        sync.hold()
        let vm = makeViewModel(store: store, sync: sync)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { vm.item != nil }
        XCTAssertNil(vm.workingIndicator)
        sync.release()
        try await waitUntil { vm.workingIndicator == .working }
        vm.stop()
    }

    /// A turn starting or ending does not touch the item, so the detail
    /// reads the item again each time the owner's state changes.
    func testTheItemIsReadAgainWhenTheOwnersTurnStartsOrEnds() async throws {
        let store = Store(); let sync = Sync(); let context = ContextStore()
        context.known = true
        let vm = makeViewModel(store: store, sync: sync, context: context)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(nil))
        try await waitUntil { context.sessionCont != nil && sync.refreshes == 1 }

        context.sessionCont?.yield("waiting")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.refreshes, 1, "the first value is the state the opening read already saw")

        context.sessionCont?.yield("running")
        try await waitUntil { sync.refreshes == 2 }
        context.sessionCont?.yield("running")
        context.sessionCont?.yield("waiting")
        try await waitUntil { sync.refreshes == 3 }
        vm.stop()
    }

    /// A stored copy that still says `running` after this device has seen
    /// the turn end is not shown while the fresh read is on its way.
    func testAStaleRunningCopyIsNotShownOnceTheTurnIsKnownToHaveEnded() async throws {
        let store = Store(); let context = ContextStore()
        context.known = true
        let vm = makeViewModel(store: store, context: context)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { context.sessionCont != nil && context.ownerCont != nil }
        context.sessionCont?.yield("running")
        try await waitUntil { vm.workingIndicator == .working }

        context.sessionCont?.yield("waiting")
        try await waitUntil { vm.workingIndicator == nil }
        vm.stop()
    }

    /// A device without the owner conversation has no state of its own to
    /// set against the journal's.
    func testWithoutTheOwnerConversationTheJournalsStateStands() async throws {
        let store = Store(); let context = ContextStore()
        let vm = makeViewModel(store: store, context: context)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { context.sessionCont != nil }
        context.sessionCont?.yield("waiting")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.workingIndicator, .working)
        vm.stop()
    }

    // MARK: - Fakes

    private final class ContextStore: ItemContextReading, @unchecked Sendable {
        /// Whether this device has the owner conversation.
        var known = false
        var ownerCont: AsyncStream<JournalStore.ConversationOrigin>.Continuation?
        var sessionCont: AsyncStream<String>.Continuation?
        func missionStream(id: String) -> AsyncStream<Mission?> { AsyncStream { $0.yield(nil) } }
        func conversationOriginStream(id: String) -> AsyncStream<JournalStore.ConversationOrigin> {
            AsyncStream {
                self.ownerCont = $0
                $0.yield(self.known ? .init(exists: true, label: "box-a · Server") : .unknown)
            }
        }
        func sessionStateStream(convoID: String) -> AsyncStream<String> { AsyncStream { self.sessionCont = $0 } }
    }
    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?
        func comments(itemID: String) throws -> [TrackerComment] { [] }
        func item(id: String) throws -> TrackerItem? { nil }
        func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { [] }
        func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { $0.yield([]) } }
        func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        private let lock = NSLock(); private var count = 0; private var held = false
        var refreshes: Int { lock.lock(); defer { lock.unlock() }; return count }
        /// Keeps every `refreshItem` from returning until `release()`.
        func hold() { lock.withLock { held = true } }
        func release() { lock.withLock { held = false } }
        func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
        func refreshItem(id: String) async {
            lock.withLock { count += 1 }
            while lock.withLock({ held }) { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {}
        func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
        func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
        func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }
    private final class API: ItemsProviding, @unchecked Sendable {
        func uploadMedia(_ data: Data, contentType: String) async throws -> String { fatalError() }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    }

    private struct TimedOut: Error {}
    private func waitUntil(_ cond: @escaping () -> Bool, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting", file: file, line: line); throw TimedOut() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
