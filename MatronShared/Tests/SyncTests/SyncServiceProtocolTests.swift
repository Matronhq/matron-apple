import XCTest
import MatrixRustSDK
@testable import MatronSync

actor FakeSyncService: MatronSync.SyncService {
    var startCallCount = 0
    var stopCallCount = 0
    private var running = false
    private(set) var isReady = false
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var stateContinuations: [AsyncStream<SyncConnectionState>.Continuation] = []
    private var currentState: SyncConnectionState = .connecting

    func start() async throws {
        startCallCount += 1
        running = true
        isReady = true
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume() }
        currentState = .running
        for cont in stateContinuations { cont.yield(.running) }
    }

    func stop() async {
        stopCallCount += 1
        running = false
        isReady = false
        let conts = stateContinuations
        stateContinuations.removeAll()
        for cont in conts { cont.finish() }
        currentState = .connecting
    }

    var isRunning: Bool { running }

    func waitUntilReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }

    func sdkService() async -> MatrixRustSDK.SyncService? { nil }

    func stateStream() -> AsyncStream<SyncConnectionState> {
        let snapshot = currentState
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            stateContinuations.append(continuation)
        }
    }

    /// Test-only mutator to drive a state transition without going
    /// through `start()` (which always lands on `.running`). Used to
    /// pin offline / connecting → running flow without standing up
    /// the live SDK.
    func _emitState(_ state: SyncConnectionState) {
        currentState = state
        for cont in stateContinuations { cont.yield(state) }
    }
}

final class SyncServiceProtocolTests: XCTestCase {
    func test_startSetsRunningTrue() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        let running = await svc.isRunning
        XCTAssertTrue(running)
    }

    func test_stopSetsRunningFalse() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        await svc.stop()
        let running = await svc.isRunning
        XCTAssertFalse(running)
    }

    func test_waitUntilReady_resumesAfterStart() async throws {
        let svc = FakeSyncService()
        let waitTask = Task { try await svc.waitUntilReady() }
        try await Task.sleep(nanoseconds: 10_000_000)
        let readyBefore = await svc.isReady
        XCTAssertFalse(readyBefore)
        try await svc.start()
        try await waitTask.value
        let readyAfter = await svc.isReady
        XCTAssertTrue(readyAfter)
    }

    func test_waitUntilReady_returnsImmediately_ifAlreadyReady() async throws {
        let svc = FakeSyncService()
        try await svc.start()
        try await svc.waitUntilReady()
    }

    func test_syncReadyError_distinguishesTerminalStates() {
        // The live impl's waitUntilReady() throws one of these when sync
        // reaches a terminal state without ever passing .running. Locking the
        // shape so a future refactor doesn't silently merge them.
        XCTAssertNotEqual(SyncReadyError.timeout, SyncReadyError.terminated)
        XCTAssertNotEqual(SyncReadyError.timeout, SyncReadyError.errored)
        XCTAssertNotEqual(SyncReadyError.terminated, SyncReadyError.errored)
    }

    func test_readyTimeout_isAReasonableUpperBound() {
        // Tighter bound would surface false positives on a slow first sync
        // against a real homeserver; looser would let the UI wedge for too
        // long when the server is unreachable.
        XCTAssertGreaterThanOrEqual(SyncServiceLive.readyTimeout, 10)
        XCTAssertLessThanOrEqual(SyncServiceLive.readyTimeout, 60)
    }

    /// Subscribers must receive the current value on subscribe so the
    /// banner doesn't render an empty stripe on first appear.
    func test_stateStream_replaysCurrentState_onSubscribe() async throws {
        let svc = FakeSyncService()
        var iterator = await svc.stateStream().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .connecting,
                       "fresh subscriber must receive the current state immediately, not block waiting for the next transition")
    }

    /// `start()` flips the user-facing state to `.running` and the
    /// stream broadcasts. `stop()` then finishes the stream so
    /// `for await` exits cleanly.
    func test_stateStream_yieldsRunning_afterStart_andFinishesOnStop() async throws {
        let svc = FakeSyncService()
        let received: Task<[SyncConnectionState], Never> = Task {
            var observed: [SyncConnectionState] = []
            for await state in await svc.stateStream() {
                observed.append(state)
            }
            return observed
        }
        // Yield once so the consumer task has had a chance to register
        // before start() runs — without this the start()'s yield can
        // race the subscribe and the test times out waiting for a
        // .running that already shipped.
        try await Task.sleep(nanoseconds: 50_000_000)
        try await svc.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        await svc.stop()
        let observed = await received.value
        XCTAssertEqual(observed.first, .connecting, "first yield is the replayed initial state")
        XCTAssertTrue(observed.contains(.running), "start() must broadcast .running")
    }

    /// Mid-test transitions land on every active subscriber. Belt-and-
    /// braces against a regression where the fake (or live impl)
    /// silently dropped subscribers after a transition.
    func test_stateStream_broadcastsTransitions_toExistingSubscribers() async throws {
        let svc = FakeSyncService()
        var iterator = await svc.stateStream().makeAsyncIterator()
        _ = await iterator.next() // drain the initial .connecting replay
        await svc._emitState(.offline(reason: "test"))
        let next = await iterator.next()
        XCTAssertEqual(next, .offline(reason: "test"),
                       "existing subscriber must receive offline transition")
    }
}
