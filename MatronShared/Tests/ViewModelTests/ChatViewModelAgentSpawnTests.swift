import XCTest
import MatronChat
import MatronEvents
import MatronJournal
@testable import MatronViewModels

private final class RecordingSpawnAnswerer: AgentSpawnAnswering, @unchecked Sendable {
    var error: Error?
    private(set) var calls: [(requestID: String, decision: AgentSpawnDecision)] = []
    private let lock = NSLock()

    func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision) async throws {
        lock.withLock { calls.append((requestID, decision)) }
        if let error { throw error }
    }
}

private let request = AgentSpawnRequest(
    requestID: "spawn-1", fromDeviceID: 4, fromName: "dev-2",
    fromConvoID: "68385da9", fromConvoTitle: "Syncing bridge services",
    targetDeviceID: 7, targetName: "dev-6",
    workdir: "/srv/app", task: "Rebase and push", topic: "spawn wiring")

/// The spawn card's answer path — and its one deliberate divergence from the
/// agent-chat card: NOTHING is remembered. A spawn resolves into the journal
/// as a `spawn_outcome` event, so the card reads its answered state off the
/// timeline instead of persisting a decision per device.
@MainActor
final class ChatViewModelAgentSpawnTests: XCTestCase {
    private func makeViewModel(
        roomID: String = #function,
        answerer: RecordingSpawnAnswerer? = RecordingSpawnAnswerer(),
        items: [TimelineItem] = []
    ) async -> (ChatViewModel, RecordingSpawnAnswerer?) {
        let timeline = FakeTimelineService()
        timeline.snapshotsToEmit = items.isEmpty ? [] : [items]
        let vm = ChatViewModel(roomID: roomID, timeline: timeline,
                               media: FakeMediaService(), agentSpawn: answerer)
        if !items.isEmpty {
            // The fake's stream finishes after yielding, so awaiting the
            // observation task is the precise "snapshot applied" signal.
            let task = await vm.start()
            await task.value
        }
        return (vm, answerer)
    }

    private func outcomeItem(
        seq: String, requestID: String = "spawn-1", outcome: String,
        roomID: String? = nil
    ) -> TimelineItem {
        TimelineItem(
            id: seq, sender: "journal", timestamp: Date(timeIntervalSince1970: 100),
            kind: .spawnOutcomeRow(eventID: seq, SpawnOutcome(
                requestID: requestID, outcome: outcome, roomID: roomID)),
            isOwn: false)
    }

    func test_approveSendsTheRequestIDFromTheCard() async throws {
        let (vm, answerer) = await makeViewModel()
        XCTAssertEqual(vm.agentSpawnState("11", request: request), .idle)

        try await vm.answerAgentSpawn(eventID: "11", request: request, decision: .approve)

        XCTAssertEqual(answerer?.calls.count, 1)
        XCTAssertEqual(answerer?.calls[0].requestID, "spawn-1")
        XCTAssertEqual(answerer?.calls[0].decision, .approve)
    }

    /// Approving is not "approved and done": the child still has to start.
    /// The card holds its in-flight state until the journal says otherwise —
    /// no optimistic resolution, because the journal is the record.
    func test_theCardStaysInFlightUntilAnOutcomeLands() async throws {
        let (vm, _) = await makeViewModel()
        try await vm.answerAgentSpawn(eventID: "11", request: request, decision: .approve)
        XCTAssertEqual(vm.agentSpawnState("11", request: request), .sending)
    }

    func test_aSpawnOutcomeRowResolvesTheCard() async throws {
        let (vm, _) = await makeViewModel(
            items: [outcomeItem(seq: "12", outcome: "started", roomID: "room-9")])

        guard case .resolved(let outcome) = vm.agentSpawnState("11", request: request) else {
            return XCTFail("expected .resolved, got \(vm.agentSpawnState("11", request: request))")
        }
        XCTAssertEqual(outcome.openableRoomID, "room-9")
        XCTAssertEqual(vm.spawnOutcomes["spawn-1"], outcome)
    }

    /// The derived outcome outranks everything, including an answer this
    /// device has in flight — a card decided on another device is history
    /// here too, with no local bookkeeping involved.
    func test_aDerivedOutcomeOutranksTheInFlightState() async throws {
        let (vm, _) = await makeViewModel(
            items: [outcomeItem(seq: "12", outcome: "declined")])
        // Answering is refused outright once the request is resolved.
        try await vm.answerAgentSpawn(eventID: "11", request: request, decision: .approve)
        guard case .resolved(let outcome) = vm.agentSpawnState("11", request: request) else {
            return XCTFail("expected .resolved")
        }
        XCTAssertEqual(outcome.kind, .declined)
    }

    func test_answeringAResolvedCardIsANoOp() async throws {
        let (vm, answerer) = await makeViewModel(
            items: [outcomeItem(seq: "12", outcome: "started", roomID: "room-9")])
        try await vm.answerAgentSpawn(eventID: "11", request: request, decision: .deny)
        XCTAssertEqual(answerer?.calls.count, 0, "the ask is already settled — never re-answer it")
    }

    /// THE contrast with the agent-chat card, whose equivalent test asserts
    /// persistence survives a new view model. Here nothing is persisted at
    /// all: a fresh view model for the same room resolves the card purely
    /// from the rows it is handed, and the defaults database is untouched.
    func test_aNewViewModelForTheSameRoomResolvesFromItemsAlone_withoutPersistence() async throws {
        let roomID = "spawn-persist-room"
        let (vm, _) = await makeViewModel(
            roomID: roomID, items: [outcomeItem(seq: "12", outcome: "started", roomID: "room-9")])
        try await vm.answerAgentSpawn(eventID: "11", request: request, decision: .approve)

        // Every key this app writes is `matron.<something>` (see the
        // answeredPrompts / agentChatAnswers keys) — so a spawn key would be
        // one of those and nothing else in the host's defaults can be
        // mistaken for one.
        let spawnDefaults = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("matron.") && $0.lowercased().contains("spawn") }
        XCTAssertTrue(spawnDefaults.isEmpty,
                      "the spawn card must persist nothing — the journal is the record (found: \(spawnDefaults))")

        // A brand-new view model, a brand-new answerer, the same rows.
        let (reopened, _) = await makeViewModel(
            roomID: roomID, items: [outcomeItem(seq: "12", outcome: "started", roomID: "room-9")])
        guard case .resolved(let outcome) = reopened.agentSpawnState("11", request: request) else {
            return XCTFail("expected the card to resolve from the timeline alone")
        }
        XCTAssertEqual(outcome.openableRoomID, "room-9")

        // …and a view model WITHOUT those rows offers the card again: proof
        // the resolution came from the timeline, not from anything stored.
        let (empty, _) = await makeViewModel(roomID: roomID)
        XCTAssertEqual(empty.agentSpawnState("11", request: request), .idle)
    }

    /// 409 = the row stopped awaiting an answer between the card being drawn
    /// and the tap. Not a failure the user can retry, so the card settles as
    /// expired — in memory only, replaced when the real outcome syncs.
    func test_conflictSettlesTheCardAsExpired_withoutPersisting() async throws {
        let (vm, answerer) = await makeViewModel()
        answerer?.error = JournalAPIError.conflict

        try await vm.answerAgentSpawn(eventID: "15", request: request, decision: .approve)

        guard case .resolved(let outcome) = vm.agentSpawnState("15", request: request) else {
            return XCTFail("expected .resolved, got \(vm.agentSpawnState("15", request: request))")
        }
        XCTAssertEqual(outcome.kind, .expired)
        XCTAssertTrue(vm.spawnOutcomes.isEmpty,
                      "a synthetic resolution is not a journal outcome and must not pose as one")
    }

    func test_notFoundSaysSo() async throws {
        let (vm, answerer) = await makeViewModel()
        answerer?.error = JournalAPIError.notFound

        try await vm.answerAgentSpawn(eventID: "16", request: request, decision: .approve)

        XCTAssertEqual(vm.agentSpawnState("16", request: request),
                       .failed("That request is no longer on the server."))
    }

    /// A failed send must stay retryable — the decision genuinely was not
    /// recorded, so the card goes back to offering both buttons.
    func test_transportFailureLeavesTheCardAnswerable() async throws {
        let (vm, answerer) = await makeViewModel()
        answerer?.error = JournalAPIError.transport("offline")

        try await vm.answerAgentSpawn(eventID: "17", request: request, decision: .approve)

        guard case .failed(let message) = vm.agentSpawnState("17", request: request) else {
            return XCTFail("expected .failed, got \(vm.agentSpawnState("17", request: request))")
        }
        XCTAssertTrue(message.contains("connection"))

        answerer?.error = nil
        try await vm.answerAgentSpawn(eventID: "17", request: request, decision: .approve)
        XCTAssertEqual(answerer?.calls.count, 2, "a failed answer is retryable")
        XCTAssertEqual(vm.agentSpawnState("17", request: request), .sending)
    }

    /// Cancellation is not an answer: drop the in-flight state so the card
    /// comes back answerable, and let the cancellation propagate.
    func test_cancellationDropsTheInFlightStateAndRethrows() async throws {
        let (vm, answerer) = await makeViewModel()
        answerer?.error = CancellationError()

        do {
            try await vm.answerAgentSpawn(eventID: "18", request: request, decision: .approve)
            XCTFail("expected the cancellation to propagate")
        } catch is CancellationError { /* expected */ }

        XCTAssertEqual(vm.agentSpawnState("18", request: request), .idle)
    }

    /// No answerer wired (previews, tests, a host that hasn't passed one):
    /// render the card read-only rather than draw buttons that silently do
    /// nothing.
    func test_withoutAnAnswererTheCardOffersNoButtons() async throws {
        let (vm, _) = await makeViewModel(answerer: nil)
        guard case .resolved(let outcome) = vm.agentSpawnState("19", request: request) else {
            return XCTFail("expected a read-only resolved rendering")
        }
        XCTAssertEqual(outcome.kind, .expired)
        try await vm.answerAgentSpawn(eventID: "19", request: request, decision: .approve)
        guard case .resolved = vm.agentSpawnState("19", request: request) else {
            return XCTFail("still read-only")
        }
    }

    /// A request resolves exactly once, but replayed history can carry the
    /// same outcome twice — and a newer row must win rather than an earlier
    /// one being resurrected.
    func test_theLastOutcomeRowWinsForARequest() async throws {
        let (vm, _) = await makeViewModel(items: [
            outcomeItem(seq: "12", outcome: "expired"),
            outcomeItem(seq: "13", outcome: "started", roomID: "room-9"),
        ])
        XCTAssertEqual(vm.spawnOutcomes["spawn-1"]?.openableRoomID, "room-9")
    }
}
