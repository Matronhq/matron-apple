import XCTest
import MatronChat
import MatronEvents
import MatronJournal
@testable import MatronViewModels

private final class RecordingStopper: SessionStopping, @unchecked Sendable {
    var error: Error?
    private(set) var stopped: [String] = []
    private let lock = NSLock()

    func stopSession(convoID: String) async throws {
        lock.withLock { stopped.append(convoID) }
        if let error { throw error }
    }
}

private final class NoAnswer: AgentSpawnAnswering, @unchecked Sendable {
    func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision) async throws {}
}

private let spawn = AgentSpawnRequest(
    requestID: "spawn-1", fromDeviceID: 4, fromName: "box-2",
    fromConvoID: "68b2c3d4", fromConvoTitle: "Syncing bridge services",
    targetDeviceID: 7, targetName: "box-6",
    workdir: "/srv/app", task: "Rebase and push", topic: "spawn wiring")

/// The "Approved by the Coordinator" badge on a consent card, read from the
/// journal's `consent_decision` event, and its Stop session.
@MainActor
final class CoordinatorConsentBadgeTests: XCTestCase {
    private func row(_ seq: Int, _ kind: TimelineItem.Kind) -> TimelineItem {
        TimelineItem(id: String(seq), sender: "journal", timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
                     kind: kind, isOwn: false)
    }

    private func makeViewModel(_ items: [TimelineItem], stopper: RecordingStopper? = RecordingStopper()) async -> ChatViewModel {
        let timeline = FakeTimelineService()
        timeline.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: #function, timeline: timeline, media: FakeMediaService(),
                               agentSpawn: NoAnswer(), sessionStopper: stopper)
        let task = await vm.start()
        await task.value
        return vm
    }

    private var card: TimelineItem { row(10, .agentSpawnRequest(eventID: "10", spawn)) }

    private func decision(_ seq: Int, _ value: ConsentDecisionEvent.Decision = .approve) -> TimelineItem {
        row(seq, .consentDecision(eventID: String(seq), ConsentDecisionEvent(
            kind: .spawn, decision: value, reason: "follows the box rules", askID: "spawn-1")))
    }

    private func started(_ seq: Int, child: String? = "child-9") -> TimelineItem {
        row(seq, .spawnOutcomeRow(eventID: String(seq), SpawnOutcome(
            requestID: "spawn-1", outcome: "started", roomID: "room-9", childConvoID: child)))
    }

    func test_badgeTextCarriesTheReason() {
        let approve = ConsentDecisionEvent(kind: .spawn, decision: .approve, reason: "follows\nthe box rules")
        XCTAssertEqual(approve.badgeText, "Approved by the Coordinator — follows the box rules")
        XCTAssertEqual(ConsentDecisionEvent(kind: .chat, decision: .decline).badgeText, "Declined by the Coordinator")
    }

    func test_aCardTheCoordinatorDidNotAnswerHasNoBadge() async {
        let vm = await makeViewModel([card, started(11)])
        XCTAssertNil(vm.coordinatorBadge("10", spawnRequest: spawn))
    }

    /// Approved, not started yet: the card is answered (no Approve /
    /// Decline again) and there is nothing to stop.
    func test_approvedBeforeTheSessionStarts_isAnsweredWithNoStop() async {
        let vm = await makeViewModel([card, decision(11)])
        XCTAssertEqual(vm.agentSpawnState("10", request: spawn), .resolved(.approved(requestID: "spawn-1")))
        let badge = vm.coordinatorBadge("10", spawnRequest: spawn)
        XCTAssertEqual(badge?.text, "Approved by the Coordinator — follows the box rules")
        XCTAssertNil(badge?.stoppableConvoID)
    }

    func test_declinedByTheCoordinator_resolvesTheCardDeclined() async {
        let vm = await makeViewModel([card, decision(11, .decline)])
        guard case .resolved(let outcome) = vm.agentSpawnState("10", request: spawn) else {
            return XCTFail("expected resolved")
        }
        XCTAssertEqual(outcome.kind, .declined)
        XCTAssertNil(vm.coordinatorBadge("10", spawnRequest: spawn)?.stoppableConvoID)
    }

    func test_startedSessionOffersStop_andStopSendsToTheChild() async {
        let stopper = RecordingStopper()
        let vm = await makeViewModel([card, decision(11), started(12)], stopper: stopper)
        XCTAssertEqual(vm.coordinatorBadge("10", spawnRequest: spawn)?.stoppableConvoID, "child-9")
        XCTAssertEqual(vm.coordinatorBadge("10", spawnRequest: spawn)?.stop, .idle)

        await vm.stopSpawnedSession(convoID: "child-9")
        XCTAssertEqual(stopper.stopped, ["child-9"])
        XCTAssertEqual(vm.coordinatorBadge("10", spawnRequest: spawn)?.stop, .sent)

        // A second tap does not send a second `/stop`.
        await vm.stopSpawnedSession(convoID: "child-9")
        XCTAssertEqual(stopper.stopped, ["child-9"])
    }

    func test_aFailedStopCanBeTappedAgain() async {
        let stopper = RecordingStopper()
        stopper.error = JournalAPIError.transport("offline")
        let vm = await makeViewModel([card, decision(11), started(12)], stopper: stopper)
        await vm.stopSpawnedSession(convoID: "child-9")
        guard case .failed = vm.coordinatorBadge("10", spawnRequest: spawn)?.stop else {
            return XCTFail("expected failed")
        }
        stopper.error = nil
        await vm.stopSpawnedSession(convoID: "child-9")
        XCTAssertEqual(stopper.stopped.count, 2)
        XCTAssertEqual(vm.coordinatorBadge("10", spawnRequest: spawn)?.stop, .sent)
    }

    func test_aStopTapOnlyAsks_untilConfirmed() async {
        let stopper = RecordingStopper()
        let vm = await makeViewModel([card, decision(11), started(12)], stopper: stopper)

        vm.requestStopSpawnedSession(convoID: "child-9")
        XCTAssertEqual(vm.pendingSessionStop, "child-9")
        XCTAssertEqual(stopper.stopped, [], "a tap alone must not queue `/stop`")
        XCTAssertEqual(vm.coordinatorBadge("10", spawnRequest: spawn)?.stop, .idle)

        await vm.confirmSessionStop(convoID: "child-9")
        XCTAssertNil(vm.pendingSessionStop)
        XCTAssertEqual(stopper.stopped, ["child-9"])
        XCTAssertEqual(vm.coordinatorBadge("10", spawnRequest: spawn)?.stop, .sent)

        // Once sent there is nothing left to ask about.
        vm.requestStopSpawnedSession(convoID: "child-9")
        XCTAssertNil(vm.pendingSessionStop)
    }

    func test_cancellingTheConfirmationSendsNothing() async {
        let stopper = RecordingStopper()
        let vm = await makeViewModel([card, decision(11), started(12)], stopper: stopper)

        vm.requestStopSpawnedSession(convoID: "child-9")
        vm.cancelPendingSessionStop()
        XCTAssertNil(vm.pendingSessionStop)
        XCTAssertEqual(stopper.stopped, [])
        XCTAssertEqual(vm.coordinatorBadge("10", spawnRequest: spawn)?.stop, .idle)
    }

    func test_noStopperMeansNothingToConfirm() async {
        let vm = await makeViewModel([card, decision(11), started(12)], stopper: nil)
        vm.requestStopSpawnedSession(convoID: "child-9")
        XCTAssertNil(vm.pendingSessionStop)
    }

    func test_noStopperOrNoChildMeansNoStopButton() async {
        let noStopper = await makeViewModel([card, decision(11), started(12)], stopper: nil)
        XCTAssertNil(noStopper.coordinatorBadge("10", spawnRequest: spawn)?.stoppableConvoID)
        let noChild = await makeViewModel([card, decision(11), started(12, child: nil)])
        XCTAssertNil(noChild.coordinatorBadge("10", spawnRequest: spawn)?.stoppableConvoID)
    }

    func test_chatCardBadgeHasTheReasonAndNoStop() async {
        let chat = AgentChatRequest(ask: .invite, roomID: "room-1", fromDeviceID: 4, fromName: "box-2",
                                    targetDeviceID: 7, topic: nil, justification: "sync up")
        let vm = await makeViewModel([
            row(10, .agentChatRequest(eventID: "10", chat)),
            row(11, .consentDecision(eventID: "11", ConsentDecisionEvent(
                kind: .chat, decision: .approve, reason: "same mission", askID: chat.askID))),
        ])
        XCTAssertEqual(vm.agentChatState("10"), .answeredByCoordinator(approved: true))
        let badge = vm.coordinatorBadge("10")
        XCTAssertEqual(badge?.text, "Approved by the Coordinator — same mission")
        XCTAssertNil(badge?.stoppableConvoID)
    }
}

private final class FakeConsentAPI: CoordinatorConsentProviding, @unchecked Sendable {
    var value: Bool? = true
    var error: Error?
    /// A write for `false` waits this long, so a later `true` would land
    /// first if the store sent them side by side.
    var slowOff: UInt64 = 0
    private(set) var writes: [Bool] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private let lock = NSLock()

    func coordinatorConsent() async throws -> Bool? { value }
    func setCoordinatorConsent(_ enabled: Bool) async throws -> Bool? {
        lock.withLock {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        if !enabled, slowOff > 0 { try? await Task.sleep(nanoseconds: slowOff) }
        let error = lock.withLock { () -> Error? in
            inFlight -= 1
            writes.append(enabled)
            if self.error == nil { value = enabled }
            return self.error
        }
        if let error { throw error }
        return enabled
    }
}

@MainActor
final class CoordinatorConsentStoreTests: XCTestCase {
    func test_loadsAndWritesTheSwitch() async {
        let api = FakeConsentAPI()
        let store = CoordinatorConsentStore(api: api)
        XCTAssertNil(store.isEnabled)
        await store.load()
        XCTAssertEqual(store.isEnabled, true)
        await store.set(false)
        XCTAssertEqual(api.writes, [false])
        XCTAssertEqual(store.isEnabled, false)
    }

    func test_aJournalWithoutTheSwitchHidesTheRow() async {
        let api = FakeConsentAPI()
        api.value = nil
        let store = CoordinatorConsentStore(api: api)
        await store.load()
        XCTAssertNil(store.isEnabled)
    }

    /// Off then on while the first `PUT` is slow: the writes go one after
    /// the other, so the journal ends on the last tap.
    func test_quickTapsReachTheJournalInOrder() async {
        let api = FakeConsentAPI()
        api.slowOff = 50_000_000
        let store = CoordinatorConsentStore(api: api)
        await store.load()
        // `async let` children may start in either order, and an "on" that
        // ran first would be a no-op: wait for the "off" tap to land first.
        let off = Task { await store.set(false) }
        while store.isEnabled != false { await Task.yield() }
        await store.set(true)
        await off.value
        XCTAssertEqual(api.maxInFlight, 1)
        XCTAssertEqual(api.writes.last, true)
        XCTAssertEqual(api.value, true)
        XCTAssertEqual(store.isEnabled, true)
    }

    func test_aFailedWritePutsTheToggleBack() async {
        let api = FakeConsentAPI()
        let store = CoordinatorConsentStore(api: api)
        await store.load()
        api.error = JournalAPIError.forbidden
        await store.set(false)
        XCTAssertEqual(store.isEnabled, true)
        XCTAssertNotNil(store.errorMessage)
    }
}
