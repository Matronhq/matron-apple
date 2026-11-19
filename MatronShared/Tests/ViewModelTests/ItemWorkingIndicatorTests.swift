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

    /// A tap made while the agent is mid-turn on something else waits for
    /// that turn: the thread says so, not that the agent is working on
    /// it, and it does not lapse while that turn runs.
    func testAReplyWaitingBehindAnotherTurnSaysTheAgentIsBusyElsewhere() async throws {
        let store = Store()
        let vm = makeViewModel(store: store)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(json: ["state": "queued", "since": 1_000, "until": NSNull(), "behind_turn": true])))
        try await waitUntil { vm.workingIndicator == .busyElsewhere }
        XCTAssertEqual(vm.workingIndicator?.label, "Busy with something else. Yours is next.")
        // Its own turn starts.
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { vm.workingIndicator == .working }
        vm.stop()
    }

    /// A `behind_turn` copy is as old as its fetch, like a `running` one:
    /// once this device has seen the owner's turn end, it is not shown
    /// (the refetch that event starts brings the hand-off state).
    func testABehindTurnCopyIsNotShownOnceTheTurnIsKnownToHaveEnded() async throws {
        let store = Store(); let context = ContextStore()
        context.known = true
        let vm = makeViewModel(store: store, context: context)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .queued, since: Date(), behindTurn: true)))
        try await waitUntil { context.sessionCont != nil && context.ownerCont != nil }
        context.sessionCont?.yield("running")
        try await waitUntil { vm.workingIndicator == .busyElsewhere }
        context.sessionCont?.yield("waiting")
        try await waitUntil { vm.workingIndicator == nil }
        vm.stop()
    }

    /// Send now tapped on the queued tap: until the bridge's release
    /// arrives, the tap is still waiting, and the thread still says so.
    func testATapWhoseSendNowIsOnItsWayStillWaits() async throws {
        let store = Store(); let cards = Cards(); let release = Release()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), queuedCards: cards,
                                     queuedRelease: release, contextStore: ContextStore())
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_tap")])
        try await waitUntil { vm.workingIndicator == .busyElsewhere }
        release.hold()
        let send = Task { await vm.sendQueuedReplyNow(commentID: "ic_tap") }
        try await waitUntil { release.sent == 1 && vm.queuedReplies["ic_tap"] == .sending }
        XCTAssertEqual(vm.workingIndicator, .busyElsewhere)
        release.letGo()
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_tap"), Self.release(11, prompt: "pr_a", action: "send_one")])
        try await waitUntil { vm.workingIndicator == .working }
        send.cancel()
        vm.stop()
    }

    /// `behind_turn` only means something on `queued`, and a journal that
    /// never sends it reads as before.
    func testBehindTurnIsReadFromTheJournalOnlyOnAQueuedState() {
        XCTAssertEqual(ItemWorking(json: ["state": "queued", "since": 1, "behind_turn": true])?.behindTurn, true)
        XCTAssertEqual(ItemWorking(json: ["state": "queued", "since": 1, "until": 2])?.behindTurn, false)
        XCTAssertEqual(ItemWorking(json: ["state": "running", "since": 1, "behind_turn": true])?.behindTurn, false)
        // A copy stored before the field existed still decodes.
        let old = #"{"state":"queued","since":0,"until":1}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(ItemWorking.self, from: old).behindTurn, false)
        let new = ItemWorking(state: .queued, since: Date(timeIntervalSince1970: 0), behindTurn: true)
        XCTAssertEqual(try JSONDecoder().decode(ItemWorking.self, from: JSONEncoder().encode(new)), new)
    }

    /// A journal that still says `running` for every turn: the bridge's
    /// queued card for the user's tap on this item says the turn is not
    /// about it. Once the card is released, the tap's own turn reads as
    /// working.
    func testALiveQueuedCardForTheTapTurnsWorkingIntoBusyElsewhere() async throws {
        let store = Store(); let cards = Cards()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), queuedCards: cards,
                                     contextStore: ContextStore())
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { vm.workingIndicator == .working }
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_tap")])
        try await waitUntil { vm.workingIndicator == .busyElsewhere }
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_tap"), Self.release(11, prompt: "pr_a", action: "send")])
        try await waitUntil { vm.workingIndicator == .working }
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

    /// A turn that ends while the read its start asked for is still open
    /// is seen at once: the next state does not wait behind that read.
    func testATurnEndingIsSeenWhileTheReadItsStartAskedForIsStillOpen() async throws {
        let store = Store(); let sync = Sync(); let context = ContextStore()
        context.known = true
        let vm = makeViewModel(store: store, sync: sync, context: context)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(nil))
        try await waitUntil { context.sessionCont != nil && vm.loadedCommentCount != nil }
        context.sessionCont?.yield("waiting")
        sync.hold()
        context.sessionCont?.yield("running")
        try await waitUntil { sync.refreshes == 2 }
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { vm.workingIndicator == .working }

        context.sessionCont?.yield("waiting")
        try await waitUntil { vm.workingIndicator == nil }
        sync.release()
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

    /// "For you only": this device hears no `session_status` for the
    /// owner, so its stored state is whatever the chat list last read
    /// ("waiting" here) while the journal says the reply waits behind a
    /// running turn. The journal's copy stands.
    func testAStaleOwnerStateOnForYouOnlyDoesNotHideTheJournalsCopy() async throws {
        let store = Store(); let context = ContextStore(); let liveness = Liveness(live: false)
        context.known = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), contextStore: context,
                                     sessionLiveness: liveness)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .queued, since: Date(), behindTurn: true)))
        try await waitUntil { context.sessionCont != nil && context.ownerCont != nil && liveness.asked == ["c-origin"] }
        context.sessionCont?.yield("waiting")
        try await waitUntil { vm.workingIndicator == .busyElsewhere }
        // A `running` copy is shown the same way.
        store.itemCont?.yield(Self.item(ItemWorking(state: .running, since: Date())))
        try await waitUntil { vm.workingIndicator == .working }
        // The re-read that finds the turn over brings it down.
        store.itemCont?.yield(Self.item(nil))
        try await waitUntil { vm.workingIndicator == nil }
        vm.stop()
    }

    /// The Coordinator's conversation (or any on "Everything") is followed
    /// live, so this device's own word on its turn ending still wins.
    func testALiveOwnerStateStillOverridesAStaleCopy() async throws {
        let store = Store(); let context = ContextStore(); let liveness = Liveness(live: true)
        context.known = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), contextStore: context,
                                     sessionLiveness: liveness)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .queued, since: Date(), behindTurn: true)))
        try await waitUntil { context.sessionCont != nil && context.ownerCont != nil && liveness.asked == ["c-origin"] }
        context.sessionCont?.yield("running")
        try await waitUntil { vm.workingIndicator == .busyElsewhere }
        context.sessionCont?.yield("waiting")
        try await waitUntil { vm.workingIndicator == nil }
        vm.stop()
    }

    /// The owner stops being followed live while the page is open (the
    /// Coordinator role moved, or the device switched to For you only):
    /// the next re-read asks again, and the journal's copy stands.
    func testLivenessIsAskedAgainOnEachReRead() async throws {
        let store = Store(); let context = ContextStore(); let liveness = Liveness(live: true)
        context.known = true
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), contextStore: context,
                                     sessionLiveness: liveness)
        vm.workingRecheckInterval = .milliseconds(50)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(ItemWorking(state: .queued, since: Date(), behindTurn: true)))
        try await waitUntil { context.sessionCont != nil && context.ownerCont != nil && !liveness.asked.isEmpty }
        context.sessionCont?.yield("waiting")
        // A live state that says the turn ended wins.
        try await waitUntil { vm.loadedCommentCount != nil && vm.workingIndicator == nil }
        liveness.live = false
        try await waitUntil { vm.workingIndicator == .busyElsewhere }
        XCTAssertEqual(Set(liveness.asked), ["c-origin"])
        vm.stop()
    }

    // MARK: - Fakes
    private final class Liveness: SessionStateLiveness, @unchecked Sendable {
        private let lock = NSLock(); private var convos: [String] = []; private var answer: Bool
        init(live: Bool) { answer = live }
        var live: Bool {
            get { lock.withLock { answer } }
            set { lock.withLock { answer = newValue } }
        }
        var asked: [String] { lock.withLock { convos } }
        func followsSessionStateLive(convoID: String) async -> Bool {
            lock.withLock { convos.append(convoID); return answer }
        }
    }

    private static func event(_ seq: Int64, type: String, payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c-origin", ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:box-a", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }
    private static func card(_ seq: Int64, prompt: String, comment: String) -> JournalEvent {
        event(seq, type: JournalEventType.prompt, payload: [
            "kind": "queued_release", "prompt_id": prompt, "items": [["id": "\(prompt)::0", "text": "📌 Item #7"]],
            "actions": [["id": "send"], ["id": "cancel"]], "item": ["item_id": "it_1", "comment_id": comment],
        ])
    }
    private static func release(_ seq: Int64, prompt: String, action: String) -> JournalEvent {
        event(seq, type: JournalEventType.promptReply, payload: ["kind": "queued_release", "prompt_id": prompt, "action": action])
    }
    private final class Release: QueuedReplySending, @unchecked Sendable {
        private let lock = NSLock(); private var count = 0; private var held = false
        var sent: Int { lock.withLock { count } }
        func hold() { lock.withLock { held = true } }
        func letGo() { lock.withLock { held = false } }
        func sendQueuedRelease(convoID: String, targetSeq: Int64, choice: String) async throws {
            lock.withLock { count += 1 }
            while lock.withLock({ held }) { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
    }
    private final class Cards: QueuedRepliesReading, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [JournalEvent] = []
        private var conts: [AsyncStream<[JournalEvent]>.Continuation] = []
        func queuedReleaseEventsStream(convoID: String) -> AsyncStream<[JournalEvent]> {
            AsyncStream { cont in
                let now = self.lock.withLock { () -> [JournalEvent] in self.conts.append(cont); return self.rows }
                cont.yield(now)
            }
        }
        func land(_ rows: [JournalEvent]) {
            let conts = lock.withLock { () -> [AsyncStream<[JournalEvent]>.Continuation] in self.rows = rows; return self.conts }
            for c in conts { c.yield(rows) }
        }
    }

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
        func itemSectionsStream(scope: ItemsScope) -> AsyncStream<ItemsIndexSections> { AsyncStream { _ in } }
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
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment?) { fatalError() }
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
