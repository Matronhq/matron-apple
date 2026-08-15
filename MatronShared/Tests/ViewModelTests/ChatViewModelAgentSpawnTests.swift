import XCTest
import MatronChat
import MatronEvents
import MatronJournal
@testable import MatronViewModels

private final class RecordingSpawnAnswerer: AgentSpawnAnswering, @unchecked Sendable {
    var error: Error?
    private(set) var calls: [(requestID: String, decision: AgentChatDecision)] = []
    private let lock = NSLock()

    func answerAgentSpawn(requestID: String, decision: AgentChatDecision) async throws {
        lock.withLock { calls.append((requestID, decision)) }
        if let error { throw error }
    }
}

private let request = AgentSpawnRequest(
    requestID: "spawn-1", fromDeviceID: 4, fromName: "dan-mac",
    targetDeviceID: 9, targetName: "dev-2",
    workdir: "~/yearbook-app", task: "run the failing spec", topic: "ci")

/// The spawn consent card's answer path — the same shape as the agent-chat
/// card's (`ChatViewModelAgentChatTests`), because it fails the same way:
/// answering is an HTTP call that leaves no journal event, so the view model
/// has to remember, and a reply into the conversation never reaches the
/// parked row.
@MainActor
final class ChatViewModelAgentSpawnTests: XCTestCase {
    private func makeViewModel(
        roomID: String = #function,
        answerer: RecordingSpawnAnswerer? = RecordingSpawnAnswerer()
    ) -> (ChatViewModel, RecordingSpawnAnswerer?) {
        UserDefaults.standard.removeObject(forKey: "matron.agentChatAnswers.\(roomID)")
        let vm = ChatViewModel(roomID: roomID, timeline: FakeTimelineService(),
                               media: FakeMediaService(), agentSpawn: answerer)
        return (vm, answerer)
    }

    func test_approveSendsTheRequestIDFromTheCard_andSticks() async {
        let (vm, answerer) = makeViewModel()
        XCTAssertEqual(vm.agentSpawnState("21"), .idle)

        await vm.answerAgentSpawn(eventID: "21", request: request, decision: .approve)

        XCTAssertEqual(answerer?.calls.count, 1)
        XCTAssertEqual(answerer?.calls[0].requestID, "spawn-1")
        XCTAssertEqual(answerer?.calls[0].decision, .approve)
        XCTAssertEqual(vm.agentSpawnState("21"), .answered(approved: true))
    }

    func test_denyRecordsTheDecline() async {
        let (vm, answerer) = makeViewModel()
        await vm.answerAgentSpawn(eventID: "22", request: request, decision: .deny)
        XCTAssertEqual(answerer?.calls[0].decision, .deny)
        XCTAssertEqual(vm.agentSpawnState("22"), .answered(approved: false))
    }

    func test_answersSurviveANewViewModelForTheSameRoom() async {
        let roomID = "spawn-persist-room"
        let (vm, _) = makeViewModel(roomID: roomID)
        await vm.answerAgentSpawn(eventID: "23", request: request, decision: .approve)

        let reopened = ChatViewModel(roomID: roomID, timeline: FakeTimelineService(),
                                     media: FakeMediaService(),
                                     agentSpawn: RecordingSpawnAnswerer())
        XCTAssertEqual(reopened.agentSpawnState("23"), .answered(approved: true))
        UserDefaults.standard.removeObject(forKey: "matron.agentChatAnswers.\(roomID)")
    }

    func test_answeringTwiceIsANoOp() async {
        let (vm, answerer) = makeViewModel()
        await vm.answerAgentSpawn(eventID: "24", request: request, decision: .approve)
        await vm.answerAgentSpawn(eventID: "24", request: request, decision: .deny)
        XCTAssertEqual(answerer?.calls.count, 1)
        XCTAssertEqual(vm.agentSpawnState("24"), .answered(approved: true))
    }

    /// A 409 means the row stopped awaiting an answer between draw and tap —
    /// answered elsewhere or 24h expired. Not actionable, so the card
    /// settles as expired rather than inviting a retry.
    func test_conflictSettlesTheCardAsExpired() async {
        let (vm, answerer) = makeViewModel()
        answerer?.error = JournalAPIError.conflict
        await vm.answerAgentSpawn(eventID: "25", request: request, decision: .approve)
        XCTAssertEqual(vm.agentSpawnState("25"), .expired)
    }

    /// A transport failure is retryable — the card must come back
    /// answerable, with the failure surfaced.
    func test_transportFailureLeavesTheCardRetryable() async {
        let (vm, answerer) = makeViewModel()
        answerer?.error = JournalAPIError.transport("boom")
        await vm.answerAgentSpawn(eventID: "26", request: request, decision: .approve)
        guard case .failed = vm.agentSpawnState("26") else {
            return XCTFail("expected .failed, got \(vm.agentSpawnState("26"))")
        }

        answerer?.error = nil
        await vm.answerAgentSpawn(eventID: "26", request: request, decision: .approve)
        XCTAssertEqual(vm.agentSpawnState("26"), .answered(approved: true))
        XCTAssertEqual(answerer?.calls.count, 2)
    }

    /// No answerer wired (previews, tests): show the card, but never buttons
    /// that cannot resolve it — the exact failure this card family replaces.
    func test_noAnswererRendersReadOnly() {
        let (vm, _) = makeViewModel(answerer: nil)
        XCTAssertEqual(vm.agentSpawnState("27"), .expired)
    }

    /// The two card families share the remembered-answer store (both keyed
    /// by journal seq, unique across the conversation) — an answered chat
    /// card must never read as an answered spawn card's neighbour... but an
    /// answer remembered under one seq must surface identically through both
    /// accessors, because it is the same store.
    func test_sharedStoreKeysNeverCollideAcrossFamilies() async {
        let (vm, answerer) = makeViewModel()
        await vm.answerAgentSpawn(eventID: "28", request: request, decision: .approve)
        XCTAssertEqual(answerer?.calls.count, 1)
        XCTAssertEqual(vm.agentChatState("28"), .answered(approved: true),
                       "same store, same key — the accessors agree by construction")
        XCTAssertEqual(vm.agentSpawnState("29"), .idle,
                       "a different seq is untouched")
    }
}
