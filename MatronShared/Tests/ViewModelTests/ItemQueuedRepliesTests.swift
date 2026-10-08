import XCTest
import MatronEvents
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// A reply of yours that waits on the agent's busy queue reads as queued in
/// the item thread, with the card's own Send now. The
/// bridge's `queued_release` card names the reply it holds (`item:
/// {item_id, comment_id}`) and its release row settles it.
@MainActor
final class ItemQueuedRepliesTests: XCTestCase {
    private static func event(_ seq: Int64, type: String, sender: String = "agent:lab-mac", payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: Double(seq)), sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }
    private static func card(_ seq: Int64, prompt: String, item: String = "it_1", comment: String?, sendOne: Bool = false,
                             sender: String = "agent:lab-mac") -> JournalEvent {
        var source: [String: Any] = ["item_id": item]
        if let comment { source["comment_id"] = comment }
        var actions: [[String: Any]] = [["id": "send"], ["id": "cancel"]]
        if sendOne { actions.insert(["id": "send_one"], at: 1) }
        return event(seq, type: JournalEventType.prompt, sender: sender, payload: [
            "kind": "queued_release", "prompt_id": prompt, "items": [["id": "\(prompt)::0", "text": "📌 Item #12"]],
            "actions": actions, "item": source,
        ])
    }
    private static func release(_ seq: Int64, prompt: String, action: String, sender: String = "agent:lab-mac") -> JournalEvent {
        event(seq, type: JournalEventType.promptReply, sender: sender,
              payload: ["kind": "queued_release", "prompt_id": prompt, "action": action])
    }

    // MARK: - Derivation

    func testALiveCardMarksItsReplyQueuedWithTheCardsSeq() {
        let rows = [Self.card(10, prompt: "pr_a", comment: "ic_1", sendOne: true)]
        XCTAssertEqual(ItemQueuedReplies.derive(rows: rows, itemID: "it_1"),
                       ["ic_1": .queued(convoID: "c1", targetSeq: 10, offersSendOne: true)])
    }

    func testReleasesSettleTheReply() {
        let rows = [
            Self.card(10, prompt: "pr_sent", comment: "ic_sent"), Self.card(11, prompt: "pr_one", comment: "ic_one"),
            Self.card(12, prompt: "pr_cancel", comment: "ic_cancel"), Self.card(13, prompt: "pr_exp", comment: "ic_exp"),
            Self.release(20, prompt: "pr_sent", action: "send"), Self.release(21, prompt: "pr_one", action: "send_one"),
            Self.release(22, prompt: "pr_cancel", action: "cancel"), Self.release(23, prompt: "pr_exp", action: "expired"),
        ]
        XCTAssertEqual(ItemQueuedReplies.derive(rows: rows, itemID: "it_1"),
                       ["ic_cancel": .cancelled, "ic_exp": .notDelivered],
                       "delivered replies are absent: they read as sent, which they were")
    }

    func testTheEarliestReleaseWins() {
        let rows = [Self.card(10, prompt: "pr_a", comment: "ic_1"),
                    Self.release(20, prompt: "pr_a", action: "send"), Self.release(21, prompt: "pr_a", action: "expired")]
        XCTAssertEqual(ItemQueuedReplies.derive(rows: rows, itemID: "it_1"), [:],
                       "a boot reconcile's expired after a committed send must not unsend it")
    }

    func testOnlyThisItemsBridgeAuthoredCardsWithACommentCount() {
        let rows = [
            Self.card(10, prompt: "pr_other", item: "it_2", comment: "ic_2"),
            Self.card(11, prompt: "pr_filed", comment: nil), // a user-filed item: no comment to mark
            Self.card(12, prompt: "pr_forged", comment: "ic_1", sender: "user:alice"),
            Self.event(13, type: JournalEventType.prompt, payload: ["kind": "queued_release", "prompt_id": "pr_untagged"]),
            Self.event(14, type: JournalEventType.prompt, payload: ["question": "A or B?", "item": ["item_id": "it_1", "comment_id": "ic_9"]]),
        ]
        XCTAssertEqual(ItemQueuedReplies.derive(rows: rows, itemID: "it_1"), [:])
    }

    func testAReleaseFromAnyoneButTheBridgeIsIgnored() {
        let rows = [Self.card(10, prompt: "pr_a", comment: "ic_1"), Self.release(20, prompt: "pr_a", action: "send", sender: "user:alice")]
        XCTAssertEqual(ItemQueuedReplies.derive(rows: rows, itemID: "it_1"),
                       ["ic_1": .queued(convoID: "c1", targetSeq: 10, offersSendOne: false)])
    }

    func testSendNowPicksJustThisReplyWhenTheCardCan() {
        XCTAssertEqual(ItemQueuedReplies.sendNowChoice(offersSendOne: true), "send_one")
        XCTAssertEqual(ItemQueuedReplies.sendNowChoice(offersSendOne: false), "send")
    }

    // MARK: - View model

    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?
        /// The thread and outbox every read and stream starts from.
        var thread: [TrackerComment] = []
        var outbox: [ItemOutboxRecord] = []
        func comments(itemID: String) throws -> [TrackerComment] { thread }
        func item(id: String) throws -> TrackerItem? { nil }
        func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { outbox }
        func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { $0.yield(self.thread) } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { $0.yield(self.outbox) } }
        func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        private let lock = NSLock()
        private var _refetched: [String] = []
        private var _drains = 0
        private var _cancelled: [String] = []
        private var _cancelResult = OutboxCancelResult.cancelled
        var refetched: [String] { lock.withLock { _refetched } }
        var drains: Int { lock.withLock { _drains } }
        var cancelled: [String] { lock.withLock { _cancelled } }
        /// What `cancelQueuedComment` answers.
        var cancelResult: OutboxCancelResult {
            get { lock.withLock { _cancelResult } } set { lock.withLock { _cancelResult = newValue } }
        }
        func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
        func refreshItem(id: String) async { lock.withLock { _refetched.append(id) } }
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {}
        func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
        func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
        func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
        func drainOutbox() async { lock.withLock { _drains += 1 } }
        func cancelQueuedComment(localID: String) async -> OutboxCancelResult {
            lock.withLock { _cancelled.append(localID); return _cancelResult }
        }
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
    private final class Cards: QueuedRepliesReading, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [JournalEvent] = []
        private var conts: [AsyncStream<[JournalEvent]>.Continuation] = []
        private var _asked: [String] = []
        var asked: [String] { lock.withLock { _asked } }
        func queuedReleaseEventsStream(convoID: String) -> AsyncStream<[JournalEvent]> {
            AsyncStream { cont in
                let now = self.lock.withLock { () -> [JournalEvent] in
                    self._asked.append(convoID); self.conts.append(cont); return self.rows
                }
                cont.yield(now)
            }
        }
        func land(_ rows: [JournalEvent]) {
            let conts = lock.withLock { () -> [AsyncStream<[JournalEvent]>.Continuation] in self.rows = rows; return self.conts }
            for c in conts { c.yield(rows) }
        }
    }
    private final class Release: QueuedReplySending, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [(String, Int64, String)] = []
        private var _fail = false
        var sent: [(String, Int64, String)] { lock.withLock { _sent } }
        var fail: Bool { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
        struct Offline: Error {}
        func sendQueuedRelease(convoID: String, targetSeq: Int64, choice: String) async throws {
            let f = lock.withLock { () -> Bool in _sent.append((convoID, targetSeq, choice)); return _fail }
            if f { throw Offline() }
        }
    }

    private static let item = TrackerItem(id: "it_1", num: 12, kind: .question, state: .open, resolution: nil, awaiting: .agent,
                                          title: "Which auth?", body: "", labels: [], links: [], originConvoID: "c1")

    private func make(cards: Cards = Cards(), release: Release? = Release(), store: Store = Store(),
                      sync: Sync = Sync()) async throws -> (ItemDetailViewModel, Store, Sync) {
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync, queuedCards: cards, queuedRelease: release)
        vm.start()
        try await waitUntil { sync.refetched == ["it_1"] && store.itemCont != nil }
        store.itemCont?.yield(Self.item)
        try await waitUntil { vm.item != nil }
        return (vm, store, sync)
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

    func testTheThreadFollowsTheOriginConversationsCardsLive() async throws {
        let cards = Cards()
        let (vm, _, _) = try await make(cards: cards)
        try await waitUntil { cards.asked == ["c1"] }
        XCTAssertEqual(vm.queuedReplies, [:])
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1", sendOne: true)])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        XCTAssertEqual(vm.queuedReplies["ic_1"], .queued(convoID: "c1", targetSeq: 10, offersSendOne: true))
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1", sendOne: true), Self.release(11, prompt: "pr_a", action: "send")])
        try await waitUntil { vm.queuedReplies.isEmpty }
    }

    func testSendNowAnswersTheCardAndShowsSendingUntilTheReleaseLands() async throws {
        let cards = Cards(); let release = Release()
        let (vm, _, _) = try await make(cards: cards, release: release)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1", sendOne: true)])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        let tap = Task { await vm.sendQueuedReplyNow(commentID: "ic_1") }
        try await waitUntil { release.sent.count == 1 }
        XCTAssertEqual(release.sent.map(\.0), ["c1"]); XCTAssertEqual(release.sent.map(\.1), [10])
        XCTAssertEqual(release.sent.map(\.2), ["send_one"])
        XCTAssertEqual(vm.queuedReplies["ic_1"], .sending, "until the bridge's release row says what happened")
        defer { tap.cancel() }
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1", sendOne: true), Self.release(11, prompt: "pr_a", action: "send_one")])
        try await waitUntil { vm.queuedReplies.isEmpty }
    }

    func testAFailedSendNowStaysQueuedAndTappable() async throws {
        let cards = Cards(); let release = Release(); release.fail = true
        let (vm, _, _) = try await make(cards: cards, release: release)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1")])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        await vm.sendQueuedReplyNow(commentID: "ic_1")
        guard case .sendFailed(let convo, let seq, let one, _) = vm.queuedReplies["ic_1"] else {
            return XCTFail("expected sendFailed, got \(String(describing: vm.queuedReplies["ic_1"]))")
        }
        XCTAssertEqual(convo, "c1"); XCTAssertEqual(seq, 10); XCTAssertFalse(one)
        release.fail = false
        vm.sendNowConfirmTimeout = .milliseconds(50)
        await vm.sendQueuedReplyNow(commentID: "ic_1")
        XCTAssertEqual(release.sent.map(\.2), ["send", "send"], "a card without send_one releases the queue")
        guard case .sendFailed(_, _, _, let reason) = vm.queuedReplies["ic_1"] else {
            return XCTFail("a tap the bridge never confirmed must come back tappable")
        }
        XCTAssertTrue(reason.contains("hasn't confirmed"))
    }

    func testCancelledAndUnqueuedRepliesOfferNothingToSend() async throws {
        let cards = Cards(); let release = Release()
        let (vm, _, _) = try await make(cards: cards, release: release)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1"), Self.release(11, prompt: "pr_a", action: "cancel")])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        XCTAssertEqual(vm.queuedReplies["ic_1"], .cancelled)
        await vm.sendQueuedReplyNow(commentID: "ic_1")
        await vm.sendQueuedReplyNow(commentID: "ic_nope")
        XCTAssertTrue(release.sent.isEmpty)
    }

    func testWithoutAReleaserSendNowDoesNothing() async throws {
        let cards = Cards()
        let (vm, _, _) = try await make(cards: cards, release: nil)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1")])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        await vm.sendQueuedReplyNow(commentID: "ic_1")
        XCTAssertEqual(vm.queuedReplies["ic_1"], .queued(convoID: "c1", targetSeq: 10, offersSendOne: false))
    }

    func testSendNowOnAnOutboxReplyDrainsTheOutboxAtOnce() async throws {
        let (vm, _, sync) = try await make()
        await vm.sendPendingNow()
        XCTAssertEqual(sync.drains, 1)
    }

    /// A first tap's timeout must not fail a later tap still in flight —
    /// the item closed and reopened in between (the view model is kept by
    /// the Mac pane), and the reply was tapped again.
    func testAnEarlierTapsTimeoutLeavesALaterTapAlone() async throws {
        let cards = Cards(); let release = Release()
        let (vm, store, sync) = try await make(cards: cards, release: release)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1")])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        vm.sendNowConfirmTimeout = .milliseconds(300)
        let first = Task { await vm.sendQueuedReplyNow(commentID: "ic_1") }
        try await waitUntil { release.sent.count == 1 }
        vm.stop(); vm.start()
        try await waitUntil { sync.refetched.count == 2 }
        store.itemCont?.yield(Self.item)
        try await waitUntil { vm.queuedReplies["ic_1"] == .queued(convoID: "c1", targetSeq: 10, offersSendOne: false) }
        vm.sendNowConfirmTimeout = .seconds(30)
        let second = Task { await vm.sendQueuedReplyNow(commentID: "ic_1") }
        try await waitUntil { release.sent.count == 2 }
        await first.value // the first attempt's timeout has fired by now
        XCTAssertEqual(vm.queuedReplies["ic_1"], .sending, "the later tap is still waiting on its release")
        second.cancel()
    }

    // MARK: - Cancel

    func testCancelAnswersTheCardWithCancelAndShowsCancellingUntilTheReleaseLands() async throws {
        let cards = Cards(); let release = Release()
        let (vm, _, _) = try await make(cards: cards, release: release)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1", sendOne: true)])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        let tap = Task { await vm.cancelQueuedReply(commentID: "ic_1") }
        defer { tap.cancel() }
        try await waitUntil { release.sent.count == 1 }
        XCTAssertEqual(release.sent.map(\.0), ["c1"]); XCTAssertEqual(release.sent.map(\.1), [10])
        XCTAssertEqual(release.sent.map(\.2), ["cancel"], "the card's own cancel withdraws just this reply, send_one card or not")
        XCTAssertEqual(vm.queuedReplies["ic_1"], .cancelling)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1", sendOne: true), Self.release(11, prompt: "pr_a", action: "cancel")])
        try await waitUntil { vm.queuedReplies["ic_1"] == .cancelled }
    }

    func testAnUnconfirmedCancelComesBackStillQueuedAndTappable() async throws {
        let cards = Cards(); let release = Release()
        let (vm, _, _) = try await make(cards: cards, release: release)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1")])
        try await waitUntil { vm.queuedReplies["ic_1"] != nil }
        vm.sendNowConfirmTimeout = .milliseconds(50)
        await vm.cancelQueuedReply(commentID: "ic_1")
        guard case .sendFailed(_, let seq, _, let reason) = vm.queuedReplies["ic_1"] else {
            return XCTFail("expected sendFailed, got \(String(describing: vm.queuedReplies["ic_1"]))")
        }
        XCTAssertEqual(seq, 10)
        XCTAssertTrue(reason.contains("hasn't confirmed the cancel"))
        // Still on the queue, so both buttons apply again.
        release.fail = true
        await vm.cancelQueuedReply(commentID: "ic_1")
        guard case .sendFailed(_, _, _, let offline) = vm.queuedReplies["ic_1"] else { return XCTFail("still queued") }
        XCTAssertTrue(offline.contains("Couldn't reach the journal"))
        XCTAssertEqual(release.sent.map(\.2), ["cancel", "cancel"])
    }

    func testOnlyAQueuedReplyCanBeCancelled() async throws {
        let cards = Cards(); let release = Release()
        let (vm, _, _) = try await make(cards: cards, release: release)
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1"), Self.release(11, prompt: "pr_a", action: "expired")])
        try await waitUntil { vm.queuedReplies["ic_1"] == .notDelivered }
        await vm.cancelQueuedReply(commentID: "ic_1")
        await vm.cancelQueuedReply(commentID: "ic_nope")
        XCTAssertTrue(release.sent.isEmpty)
    }

    private static func reply(_ id: String, body: String) -> TrackerComment {
        TrackerComment(id: id, itemID: "it_1", author: .user, body: body, createdAt: Date(timeIntervalSince1970: 1))
    }

    func testEditAndResendPutsANeverDeliveredReplysTextInTheReplyBox() async throws {
        let cards = Cards(); let store = Store()
        store.thread = [Self.reply("ic_1", body: "Use OAuth"), Self.reply("ic_2", body: "Still queued")]
        let (vm, _, _) = try await make(cards: cards, store: store)
        try await waitUntil { vm.comments.count == 2 }
        cards.land([Self.card(10, prompt: "pr_a", comment: "ic_1"), Self.release(11, prompt: "pr_a", action: "cancel"),
                    Self.card(12, prompt: "pr_b", comment: "ic_2")])
        try await waitUntil { vm.queuedReplies.count == 2 }
        vm.editAndResend(commentID: "ic_2")
        XCTAssertEqual(vm.draft, "", "a reply still queued can still be sent as it is")
        vm.editAndResend(commentID: "ic_1")
        XCTAssertEqual(vm.draft, "Use OAuth")
        vm.draft = "Actually  "
        vm.editAndResend(commentID: "ic_1")
        XCTAssertEqual(vm.draft, "Actually\n\nUse OAuth", "never over what's already typed")
        vm.editAndResend(commentID: "ic_1")
        XCTAssertEqual(vm.draft, "Actually\n\nUse OAuth", "a second tap doesn't paste it twice")
    }

    private static func outboxRow(_ localID: String, body: String, action: String? = nil) -> ItemOutboxRecord {
        var payload: [String: Any] = ["body": body, "attachments": [Any]()]
        if let action { payload["action"] = action }
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        return ItemOutboxRecord(localID: localID, itemID: "it_1", op: "comment", payloadJSON: json, createdAt: 0, attempts: 1, lastError: "offline")
    }

    func testCancellingAnOutboxReplyWithdrawsItAndReturnsItsTextToTheReplyBox() async throws {
        let store = Store(); let sync = Sync()
        store.outbox = [Self.outboxRow("L1", body: "Use OAuth"), Self.outboxRow("L2", body: "Yes", action: "Yes")]
        let (vm, _, _) = try await make(store: store, sync: sync)
        try await waitUntil { vm.pendingComments.count == 2 }
        await vm.cancelPendingReply(localID: "L1")
        await vm.cancelPendingReply(localID: "L1") // a double-click
        XCTAssertEqual(sync.cancelled, ["L1"], "the second tap finds nothing left to cancel")
        XCTAssertEqual(vm.pendingComments.map(\.localID), ["L2"], "gone at once, not on the stream's next delivery")
        XCTAssertEqual(vm.draft, "Use OAuth")
        XCTAssertEqual(sync.refetched, ["it_1", "it_1"], "refetched, in case an earlier attempt did land")
        await vm.cancelPendingReply(localID: "L2")
        XCTAssertEqual(vm.draft, "Use OAuth", "a queued tap's label is not a reply to edit")
        XCTAssertNil(vm.error)
    }

    func testAnOutboxReplyAlreadyBeingPostedStays() async throws {
        let store = Store(); let sync = Sync(); sync.cancelResult = .alreadySent
        store.outbox = [Self.outboxRow("L1", body: "Use OAuth")]
        let (vm, _, _) = try await make(store: store, sync: sync)
        try await waitUntil { vm.pendingComments.count == 1 }
        await vm.cancelPendingReply(localID: "L1")
        XCTAssertEqual(vm.pendingComments.map(\.localID), ["L1"])
        XCTAssertEqual(vm.draft, "")
        XCTAssertEqual(vm.error, "That reply is already on its way and can't be cancelled.")
        sync.cancelResult = .failed
        await vm.cancelPendingReply(localID: "L1")
        XCTAssertEqual(vm.pendingComments.map(\.localID), ["L1"])
        XCTAssertEqual(vm.error, "Couldn't cancel that reply. Try again.", "a store failure is not a reply on its way")
    }
}
