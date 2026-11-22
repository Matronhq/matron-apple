import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// Multi-select answers on the item page: the tick state, Send, the
/// `selected` answer it queues, and the chosen state read back from
/// `chosen_actions`. One-tap questions are left exactly as they were.
@MainActor
final class ItemMultiSelectTests: XCTestCase {
    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?
        var commentsCont: AsyncStream<[TrackerComment]>.Continuation?
        var outboxCont: AsyncStream<[ItemOutboxRecord]>.Continuation?
        var storedItem: TrackerItem?
        var storedComments: [TrackerComment] = []
        var storedOutbox: [ItemOutboxRecord] = []
        func comments(itemID: String) throws -> [TrackerComment] { storedComments }
        func item(id: String) throws -> TrackerItem? { storedItem }
        func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { storedOutbox }
        func itemSectionsStream(scope: ItemsScope) -> AsyncStream<ItemsIndexSections> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { self.commentsCont = $0 } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { self.outboxCont = $0; $0.yield([]) } }
        func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    }

    @MainActor private final class Sync: ItemsSyncing {
        struct Answer: Equatable { let selected: [String]; let body: String; let replyTo: String? }
        var answers: [Answer] = []
        var taps: [String?] = []
        /// Runs inside `enqueueSelection` with the row's local id.
        var onEnqueue: ((String, [String], String?) -> Void)?
        func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
        func refreshItem(id: String) async {}
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {
            taps.append(action)
        }
        func enqueueSelection(itemID: String, localID: String, selected: [String], body: String, replyTo: String?) async {
            answers.append(Answer(selected: selected, body: body, replyTo: replyTo))
            onEnqueue?(localID, selected, replyTo)
        }
        func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
        func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
        func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }

    @MainActor private final class API: ItemsProviding {
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment?) { fatalError() }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
        func uploadMedia(_ data: Data, contentType: String) async throws -> String { fatalError() }
    }

    private static let labels = ["Close the Docs mission", "Close the Billing mission", "Close the Search mission"]

    private func question(multiSelect: Bool = true, chosen: [String] = [], state: ItemState = .open) -> TrackerItem {
        TrackerItem(id: "it_1", num: 1, kind: .question, state: state, awaiting: .user, title: "Which missions can close?",
                    originConvoID: "c1", actions: Self.labels, chosenAction: chosen.first,
                    multiSelect: multiSelect, chosenActions: chosen)
    }

    private func start(_ item: TrackerItem, comments: [TrackerComment] = []) async throws -> (ItemDetailViewModel, Store, Sync) {
        let store = Store(); store.storedItem = item; store.storedComments = comments
        let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync)
        vm.start()
        try await waitUntil { store.itemCont != nil && store.commentsCont != nil }
        store.itemCont?.yield(item)
        store.commentsCont?.yield(comments)
        try await waitUntil { vm.item != nil && vm.comments.count == comments.count }
        return (vm, store, sync)
    }

    private func row(_ localID: String, selected: [String], replyTo: String?) -> ItemOutboxRecord {
        var payload: [String: Any] = ["body": selected.joined(separator: ", "), "attachments": [], "selected": selected]
        if let replyTo { payload["replyTo"] = replyTo }
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        return ItemOutboxRecord(localID: localID, itemID: "it_1", op: "comment", payloadJSON: json, createdAt: 1, attempts: 0, lastError: nil)
    }

    func testAnUnansweredQuestionTicksNothingAndSendWaitsForATick() async throws {
        let (vm, _, _) = try await start(question())
        let state = try XCTUnwrap(vm.itemMultiSelect)
        XCTAssertEqual(state.labels, Self.labels)
        XCTAssertEqual(state.ticked, [])
        XCTAssertFalse(state.canSend, "Send is disabled until something is ticked")
        XCTAssertFalse(state.isAnswered)

        vm.toggleTick(Self.labels[2], commentID: nil)
        vm.toggleTick(Self.labels[0], commentID: nil)
        XCTAssertEqual(vm.itemMultiSelect?.ticked, [Self.labels[0], Self.labels[2]])
        XCTAssertEqual(vm.itemMultiSelect?.canSend, true)

        vm.toggleTick(Self.labels[0], commentID: nil)
        vm.toggleTick(Self.labels[2], commentID: nil)
        XCTAssertEqual(vm.itemMultiSelect?.canSend, false, "unticking everything disables Send again")
        vm.toggleTick("Not offered", commentID: nil)
        XCTAssertEqual(vm.itemMultiSelect?.ticked, [])
    }

    func testSendQueuesTheTickedLabelsInOfferedOrderAndShowsThemChosen() async throws {
        let (vm, store, sync) = try await start(question())
        sync.onEnqueue = { id, selected, replyTo in store.storedOutbox = [self.row(id, selected: selected, replyTo: replyTo)] }
        vm.toggleTick(Self.labels[2], commentID: nil)
        vm.toggleTick(Self.labels[0], commentID: nil)
        await vm.sendSelection(commentID: nil)

        XCTAssertEqual(sync.answers, [.init(selected: [Self.labels[0], Self.labels[2]],
                                            body: "\(Self.labels[0]), \(Self.labels[2])", replyTo: nil)])
        XCTAssertEqual(sync.taps, [], "an answer is never sent as a one-tap action")
        let state = try XCTUnwrap(vm.itemMultiSelect)
        XCTAssertEqual(state.answered, [Self.labels[0], Self.labels[2]], "the queued answer shows as chosen")
        XCTAssertEqual(state.ticked, state.answered)
        XCTAssertFalse(state.canSend, "sending the same answer again does nothing")

        await vm.sendSelection(commentID: nil)
        XCTAssertEqual(sync.answers.count, 1)
    }

    func testTheChosenStateComesFromChosenActions() async throws {
        let (vm, _, sync) = try await start(question(chosen: [Self.labels[1], Self.labels[2]]))
        let state = try XCTUnwrap(vm.itemMultiSelect)
        XCTAssertEqual(state.answered, [Self.labels[1], Self.labels[2]])
        XCTAssertEqual(state.ticked, [Self.labels[1], Self.labels[2]])
        XCTAssertTrue(state.isAnswered)
        XCTAssertFalse(state.canSend)

        // Change the ticks and send again: the latest answer wins.
        vm.toggleTick(Self.labels[2], commentID: nil)
        XCTAssertEqual(vm.itemMultiSelect?.canSend, true)
        await vm.sendSelection(commentID: nil)
        XCTAssertEqual(sync.answers.map(\.selected), [[Self.labels[1]]])
    }

    func testAnswersHeldInFlightUntilTheItemRecordsThem() async throws {
        let (vm, store, sync) = try await start(question())
        // The post lands at once: no queued row, the store's item not yet
        // carrying the answer — the marker keeps the ticks until it does.
        sync.onEnqueue = { _, _, _ in }
        vm.toggleTick(Self.labels[1], commentID: nil)
        await vm.sendSelection(commentID: nil)
        XCTAssertEqual(vm.itemMultiSelect?.answered, [], "an answer that landed nowhere lets go")

        sync.onEnqueue = { id, selected, replyTo in store.storedOutbox = [self.row(id, selected: selected, replyTo: replyTo)] }
        vm.toggleTick(Self.labels[1], commentID: nil)
        await vm.sendSelection(commentID: nil)
        store.outboxCont?.yield([])
        XCTAssertEqual(vm.itemMultiSelect?.answered, [Self.labels[1]], "a stale empty outbox doesn't drop the answer")
        store.storedOutbox = []
        let answered = question(chosen: [Self.labels[1]])
        store.storedItem = answered
        store.itemCont?.yield(answered)
        try await waitUntil { vm.item?.chosenActions == [Self.labels[1]] }
        XCTAssertEqual(vm.itemMultiSelect?.answered, [Self.labels[1]])
    }

    func testAFollowUpQuestionIsAnsweredWithReplyTo() async throws {
        let asking = TrackerComment(id: "ic_ask", itemID: "it_1", author: .agent, body: "And which should we archive?",
                                    actions: ["Docs", "Billing"], multiSelect: true)
        let tapQuestion = TrackerComment(id: "ic_tap", itemID: "it_1", author: .agent, body: "Ship it?", actions: ["Go", "Wait"])
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q", originConvoID: "c1")
        let (vm, _, sync) = try await start(item, comments: [asking, tapQuestion])
        XCTAssertNil(vm.itemMultiSelect)
        XCTAssertEqual(Array(vm.commentMultiSelects.keys), ["ic_ask"], "a one-tap follow-up has no tick list")
        vm.toggleTick("Billing", commentID: "ic_ask")
        await vm.sendSelection(commentID: "ic_ask")
        XCTAssertEqual(sync.answers, [.init(selected: ["Billing"], body: "Billing", replyTo: "ic_ask")])
    }

    func testAOneTapQuestionIsUnchanged() async throws {
        let (vm, _, sync) = try await start(question(multiSelect: false))
        XCTAssertNil(vm.itemMultiSelect)
        await vm.chooseAction(Self.labels[0])
        XCTAssertEqual(sync.taps, [Self.labels[0]])
        XCTAssertEqual(sync.answers, [])
    }

    func testAMultiSelectQuestionTakesNoOneTapAnswerAndNoneOnceClosed() async throws {
        let (vm, _, sync) = try await start(question())
        await vm.chooseAction(Self.labels[0])
        XCTAssertEqual(sync.taps, [])
        let (closed, _, _) = try await start(question(state: .closed))
        XCTAssertNil(closed.itemMultiSelect)
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
