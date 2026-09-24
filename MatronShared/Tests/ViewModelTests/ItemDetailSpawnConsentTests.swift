import XCTest
import MatronEvents
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// The spawn consent card inside item detail (item #2318): an item whose
/// link is `matron://consent/spawn/<id>` renders the card the journal
/// published into the origin conversation, with the state derived the way
/// `ChatViewModel.agentSpawnState` derives it — a `spawn_outcome` row wins,
/// then the in-flight transient, then the item's own open/closed state.
/// And it answers only against that card: the request id in the item's
/// link is agent-written, so an ask without its card is never answerable.
@MainActor
final class ItemDetailSpawnConsentTests: XCTestCase {
    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?; var commentsCont: AsyncStream<[TrackerComment]>.Continuation?
        func comments(itemID: String) throws -> [TrackerComment] { [] }
        func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { self.commentsCont = $0 } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { $0.yield([]) } }
        func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        var refetched: [String] = []
        func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
        func refreshItem(id: String) async { refetched.append(id) }
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?) async {}
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
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    }
    /// The origin conversation's consent rows: a subscription yields what
    /// is there now, and `land` simulates a card (or its outcome) reaching
    /// the local store later.
    private final class Events: ConsentEventsReading, @unchecked Sendable {
        var rows: [String: [JournalEvent]] = [:]
        var asked: [String] = []
        private var conts: [String: [AsyncStream<[JournalEvent]>.Continuation]] = [:]
        func consentEventsStream(convoID: String) -> AsyncStream<[JournalEvent]> {
            asked.append(convoID)
            return AsyncStream { cont in
                self.conts[convoID, default: []].append(cont)
                cont.yield(self.rows[convoID] ?? [])
            }
        }
        func land(_ convoID: String, _ rows: [JournalEvent]) {
            self.rows[convoID] = rows
            for cont in conts[convoID] ?? [] { cont.yield(rows) }
        }
    }
    /// Records answers; `error` makes the next one throw; `gate` holds it.
    private final class Spawn: AgentSpawnAnswering, @unchecked Sendable {
        var answers: [(String, AgentSpawnDecision)] = []
        var error: Error?
        var gate: CheckedContinuation<Void, Never>?
        var holds = false
        func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision) async throws {
            answers.append((requestID, decision))
            if holds { holds = false; await withCheckedContinuation { gate = $0 } }
            if let error { throw error }
        }
        func release() { let g = gate; gate = nil; g?.resume() }
    }

    private static func event(_ seq: Int64, convo: String = "c1", type: String, payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:greg", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }
    private static let card = event(10, type: JournalEventType.permissionRequest, payload: [
        "kind": "agent_spawn", "request_id": "spawn-1", "from_device_id": 4, "from_name": "greg",
        "from_convo_id": "c1", "from_convo_title": "consent deploy", "target_device_id": 9, "target_name": "dan-mac",
        "workdir": "/Users/dan/Dev/matron-apple", "task": "Deploy the journal, then start #2318.", "topic": "consent items",
    ])
    private static let started = event(11, type: JournalEventType.spawnOutcome, payload: [
        "request_id": "spawn-1", "outcome": "started", "room_id": "room-7", "child_convo_id": "child-1",
    ])
    private static func item(state: ItemState = .open, links: [TrackerLink] = [TrackerLink(url: "matron://consent/spawn/spawn-1", title: "Spawn request spawn-1")]) -> TrackerItem {
        TrackerItem(id: "it_1", num: 2366, kind: .question, state: state, resolution: state == .closed ? .decided : nil,
                    awaiting: state == .open ? .user : nil, title: "Approve spawn on dan-mac — consent items",
                    body: "**greg** asks to start a new agent session on **dan-mac**.", labels: ["consent"], links: links, originConvoID: "c1")
    }

    /// Started, and past its opening refetch — by then the store's item
    /// stream continuation exists, so a test's first `yield` lands.
    private func make(events: Events? = Events(), spawn: Spawn? = Spawn()) async throws -> (ItemDetailViewModel, Store, Sync) {
        let store = Store(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: sync, events: events, agentSpawn: spawn)
        vm.start()
        try await waitUntil { sync.refetched == ["it_1"] && store.itemCont != nil }
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

    // MARK: - Derivation

    func testAnItemWithoutAConsentLinkHasNoConsentCard() async throws {
        let (vm, store, _) = try await make()
        store.itemCont?.yield(Self.item(links: [TrackerLink(url: "https://example.com")]))
        try await waitUntil { vm.item != nil }
        XCTAssertNil(vm.spawnConsent)
    }

    func testTheCardComesFromTheOriginConversationsPermissionRequest() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        let consent = try XCTUnwrap(vm.spawnConsent)
        XCTAssertEqual(consent.requestID, "spawn-1")
        XCTAssertEqual(consent.request?.task, "Deploy the journal, then start #2318.")
        XCTAssertEqual(consent.request?.targetName, "dan-mac")
        XCTAssertEqual(consent.state, .idle, "an open ask with an answerer wired is answerable")
        XCTAssertEqual(events.asked.first, "c1", "the card lives in the item's origin conversation")
    }

    /// The forgery this guards against: an agent files an item in ITS
    /// conversation linking ANOTHER conversation's request id under a
    /// benign body. No card in the origin conversation, no answer.
    func testAMissingCardIsNotAnswerable() async throws {
        let spawn = Spawn()
        let (vm, store, _) = try await make(spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertNil(vm.spawnConsent?.request, "the card event has not synced: no facts to draw")
        await vm.answerSpawn(approve: true)
        XCTAssertTrue(spawn.answers.isEmpty, "the request id alone is never enough to answer on")
    }

    func testAStoreWithoutEventsReadsAsNoCard() async throws {
        let spawn = Spawn()
        let (vm, store, _) = try await make(events: nil, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertNil(vm.spawnConsent?.request)
        await vm.answerSpawn(approve: true)
        XCTAssertTrue(spawn.answers.isEmpty)
    }

    /// The push-open case: the item is on screen before the origin
    /// conversation synced. The card must arrive without reopening.
    func testACardThatLandsLaterMakesTheAskAnswerable() async throws {
        let events = Events()
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertNil(vm.spawnConsent?.request)
        events.land("c1", [Self.card])
        try await waitUntil { vm.spawnConsent?.request != nil }
        XCTAssertEqual(vm.spawnConsent?.state, .idle)
        XCTAssertEqual(events.asked, ["c1"], "one subscription per origin conversation, not one per item update")
    }

    func testAnOpenConsentAskOffersNoManualClose() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertEqual(vm.availableResolutions, [], "Approve and Decline are the only honest closes; cancelling would park the spawn unseen")
    }

    /// Bugbot (PR #230): a closed consent item still offers Reopen (and a
    /// user's comment on a closed item reopens it too). Once the ask is
    /// settled the item is an ordinary question again — the guard must
    /// hide the closes only while the card is still awaiting an answer,
    /// or a reopened item can never be closed.
    func testAReopenedConsentItemWithItsOutcomeOffersTheQuestionCloses() async throws {
        let events = Events(); events.rows["c1"] = [Self.card, Self.started]
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state.isResolvedStarted == true }
        XCTAssertEqual(vm.availableResolutions, [.cancelled], "the ask is settled; the item closes like any question")
    }

    func testAnAskSettledByAConflictLeavesTheItemCloseable() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let spawn = Spawn(); spawn.error = JournalAPIError.conflict
        let (vm, store, _) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        XCTAssertEqual(vm.availableResolutions, [])
        await vm.answerSpawn(approve: true)
        XCTAssertEqual(vm.availableResolutions, [.cancelled], "no longer waiting means nothing left to park unseen")
    }

    func testACardStillSyncingKeepsTheClosesHidden() async throws {
        let (vm, store, _) = try await make(events: Events())
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertNil(vm.spawnConsent?.request)
        XCTAssertEqual(vm.availableResolutions, [], "no card yet: the ask may still be parked, so no manual close")
    }

    func testASpawnOutcomeInTheStoreResolvesTheCard() async throws {
        let events = Events(); events.rows["c1"] = [Self.card, Self.started]
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item(state: .closed))
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertEqual(vm.spawnConsent?.state,
                       .resolved(SpawnOutcome(requestID: "spawn-1", outcome: "started", roomID: "room-7", childConvoID: "child-1")))
    }

    func testAnOutcomeForAnotherRequestIsIgnored() async throws {
        let events = Events()
        events.rows["c1"] = [Self.card, Self.event(12, type: JournalEventType.spawnOutcome, payload: ["request_id": "spawn-2", "outcome": "declined"])]
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertEqual(vm.spawnConsent?.state, .idle)
    }

    func testAClosedItemWithNoLocalOutcomeIsNoLongerWaiting() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item(state: .closed))
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertEqual(vm.spawnConsent?.state, .resolved(.expired(requestID: "spawn-1")),
                       "closed means the row stopped awaiting an answer; the thread's closing note says how")
        XCTAssertNotNil(vm.spawnConsent?.request, "the card's facts still render")
    }

    func testNoAnswererMeansAReadOnlyCard() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let (vm, store, _) = try await make(events: events, spawn: nil)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent != nil }
        XCTAssertEqual(vm.spawnConsent?.state, .resolved(.expired(requestID: "spawn-1")),
                       "same convention as the timeline card: never buttons with nothing behind them")
    }

    /// The journal appends the outcome, then closes the item: the outcome
    /// row resolves the card on its own, the item update follows.
    func testTheCardReDerivesWhenTheOutcomeLands() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let (vm, store, _) = try await make(events: events)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        events.land("c1", [Self.card, Self.started])
        try await waitUntil { vm.spawnConsent?.state.isResolvedStarted == true }
        store.itemCont?.yield(Self.item(state: .closed))
        try await waitUntil { vm.item?.state == .closed }
        XCTAssertTrue(vm.spawnConsent?.state.isResolvedStarted == true)
    }

    // MARK: - Answering

    func testApproveAnswersOnTheRequestIdAndStaysSendingUntilTheOutcomeLands() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let spawn = Spawn()
        let (vm, store, sync) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        await vm.answerSpawn(approve: true)
        XCTAssertEqual(spawn.answers.map(\.0), ["spawn-1"])
        XCTAssertEqual(spawn.answers.map(\.1), [.approve])
        XCTAssertEqual(vm.spawnConsent?.state, .sending, "approved is not done: the child still has to start")
        XCTAssertEqual(sync.refetched.filter { $0 == "it_1" }.count, 2, "the item is refetched after the answer (opening refetch + this one)")
    }

    func testDeclineSendsDeny() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let spawn = Spawn()
        let (vm, store, _) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        await vm.answerSpawn(approve: false)
        XCTAssertEqual(spawn.answers.map(\.1), [.deny])
    }

    func testAConflictSettlesTheCardAsExpired() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let spawn = Spawn(); spawn.error = JournalAPIError.conflict
        let (vm, store, _) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        await vm.answerSpawn(approve: true)
        XCTAssertEqual(vm.spawnConsent?.state, .resolved(.expired(requestID: "spawn-1")))
    }

    func testAnErrorSettlesIntoTheCardAndLeavesItAnswerableAgain() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let spawn = Spawn(); spawn.error = JournalAPIError.transport("offline")
        let (vm, store, _) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        await vm.answerSpawn(approve: true)
        XCTAssertEqual(vm.spawnConsent?.state, .failed("Couldn't reach the server — check your connection and try again."))
        spawn.error = nil
        await vm.answerSpawn(approve: true)
        XCTAssertEqual(spawn.answers.count, 2, "a failed card can be answered again")
        XCTAssertEqual(vm.spawnConsent?.state, .sending)
    }

    func testASecondTapWhileSendingIsIgnored() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let spawn = Spawn(); spawn.holds = true
        let (vm, store, _) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        let first = Task { await vm.answerSpawn(approve: true) }
        // `.sending` is set before the answer call hops off the main
        // actor, so wait for the answer itself to be recorded (and held)
        // too — otherwise the count below can read 0 on a slow runner.
        try await waitUntil { vm.spawnConsent?.state == .sending && spawn.answers.count == 1 }
        await vm.answerSpawn(approve: false)
        XCTAssertEqual(spawn.answers.count, 1, "the in-flight answer is the only one sent")
        spawn.release()
        await first.value
    }

    func testAnsweringAResolvedCardIsANoOp() async throws {
        let events = Events(); events.rows["c1"] = [Self.card, Self.started]
        let spawn = Spawn()
        let (vm, store, _) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item(state: .closed))
        try await waitUntil { vm.spawnConsent != nil }
        await vm.answerSpawn(approve: true)
        XCTAssertTrue(spawn.answers.isEmpty)
    }

    func testAnOutcomeOutranksATransient() async throws {
        let events = Events(); events.rows["c1"] = [Self.card]
        let spawn = Spawn(); spawn.error = JournalAPIError.transport("offline")
        let (vm, store, _) = try await make(events: events, spawn: spawn)
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.spawnConsent?.state == .idle }
        await vm.answerSpawn(approve: true)
        guard case .failed = vm.spawnConsent?.state else { return XCTFail("expected failed") }
        events.land("c1", [Self.card, Self.started])
        try await waitUntil { vm.spawnConsent?.state.isResolvedStarted == true }
    }
}

private extension AgentSpawnCardState {
    var isResolvedStarted: Bool {
        if case .resolved(let outcome) = self { return outcome.kind == .started }
        return false
    }
}
