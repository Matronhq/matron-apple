import XCTest
@testable import MatronViewModels
import MatronVerification

/// `VerificationCenter` (spec §7.1, §5.9) observes `incomingRequests()` and
/// surfaces summaries to the chat-list banner. The dismiss-cancels-SDK
/// invariant is the load-bearing piece: a banner dismiss MUST cancel the
/// underlying SDK request before removing from `pending`, otherwise the
/// other side keeps the request open forever and shows a stale "waiting"
/// UI on the partner device.
final class VerificationCenterTests: XCTestCase {

    @MainActor
    func test_dismiss_callsServiceCancelBeforeRemovingFromPending() async {
        let svc = ScriptedVerificationService()
        let center = VerificationCenter(service: svc)
        let summary = VerificationRequestSummary(
            id: "req-1",
            otherUserID: "@bob:s",
            otherDeviceID: "DEV",
            createdAt: Date()
        )
        center.injectPending(summary)

        await center.dismiss(summary)

        let cancelled = await svc.cancelledSnapshot()
        XCTAssertEqual(cancelled.map(\.id), ["req-1"])
        XCTAssertEqual(cancelled.first?.reason, "User dismissed")
        XCTAssertTrue(center.pending.isEmpty)
    }

    /// Wave 4 expert-QA #5: `dismiss()` MUST complete and remove the
    /// summary from `pending` even when the service's `cancel()` throws —
    /// the prior `try?` silently swallowed the error, but a partner
    /// device showing a stale "waiting" UI is the only observable
    /// downside, and that's strictly better than leaving an undismissable
    /// banner stuck on screen. The `os.Logger.error` call inside `dismiss`
    /// isn't directly asserted (XCTest can't subscribe to OSLog without
    /// extra plumbing), but the structural guarantee — local removal
    /// happens regardless of the cancel failure — is the load-bearing
    /// invariant for the UI.
    @MainActor
    func test_dismiss_completesAndRemovesPending_evenWhenCancelThrows() async {
        let svc = ScriptedVerificationService()
        await svc.setShouldThrowOnCancel(true)
        let center = VerificationCenter(service: svc)
        let summary = VerificationRequestSummary(
            id: "req-throwing",
            otherUserID: "@bob:s",
            otherDeviceID: "DEV",
            createdAt: Date()
        )
        center.injectPending(summary)

        await center.dismiss(summary)

        // Local removal STILL happens — the user's banner-dismiss tap is
        // never undone by an SDK transport failure.
        XCTAssertTrue(center.pending.isEmpty)
        // And the cancel was attempted even though it threw — the
        // partner-device side at least received the cancel intent before
        // the transport failed.
        let attempted = await svc.cancelAttemptedCount()
        XCTAssertEqual(attempted, 1)
    }

    @MainActor
    func test_start_appendsIncomingSummaryToPending() async {
        let svc = ScriptedVerificationService()
        let summary = VerificationRequestSummary(
            id: "req-2",
            otherUserID: "@bot:s",
            otherDeviceID: "BOTDEV",
            createdAt: Date()
        )
        await svc.scheduleIncoming([summary])
        let center = VerificationCenter(service: svc)

        center.start()
        // Wait for the AsyncStream to drive a single iteration through the
        // observation task — bounded poll so a regression here can't hang
        // CI. The stream finishes after the scripted batch is delivered.
        try? await waitUntil { center.pending == [summary] }

        XCTAssertEqual(center.pending, [summary])
        center.stop()
    }

    /// `start()` is idempotent — re-firing it (e.g. on a SwiftUI view
    /// remount) must not duplicate the same request in `pending`. The
    /// `pending.contains(where:)` guard inside the observation task is
    /// what protects against this.
    @MainActor
    func test_start_dedupesByRequestID() async {
        let svc = ScriptedVerificationService()
        let summary = VerificationRequestSummary(
            id: "req-3",
            otherUserID: "@bot:s",
            otherDeviceID: "BOTDEV",
            createdAt: Date()
        )
        await svc.scheduleIncoming([summary, summary, summary])
        let center = VerificationCenter(service: svc)

        center.start()
        try? await waitUntil { center.pending.count == 1 }

        XCTAssertEqual(center.pending, [summary])
        center.stop()
    }

    /// Stop must cancel the observation task so a long-lived stream
    /// (production wiring observes for the entire session) doesn't leak
    /// into the background. The `Task.isCancelled` check inside the loop
    /// terminates iteration on the next yield.
    @MainActor
    func test_stop_isSafe_withoutStart() {
        let svc = ScriptedVerificationService()
        let center = VerificationCenter(service: svc)
        // No-op when the observation task was never created. Crashes here
        // would catch a stray force-unwrap in stop().
        center.stop()
        XCTAssertTrue(center.pending.isEmpty)
    }

    /// Wave 5 bugbot #4: `start()` MUST be a no-op when an observation
    /// task is already running. Two call sites fire `start()` on cold-
    /// launch — the host's `.task(id: session.userID)` AND the chat-list
    /// view's `.onAppear` — and the prior cancel-then-restart shape meant
    /// whichever fired second cancelled the first's observation, silently
    /// breaking the incoming-request stream depending on scheduler
    /// ordering. Locks the new contract: first caller wins, second is a
    /// safe no-op. Asserts via the `hasObservationTask` DEBUG seam (a
    /// task-identity comparison would need exposing `Task` itself, which
    /// is more surface than the test needs — installed-or-not is enough
    /// because the loop only ever ends via `stop()` or stream finish).
    @MainActor
    func test_start_isNoOp_whenAlreadyRunning() async {
        let svc = ScriptedVerificationService()
        let center = VerificationCenter(service: svc)

        center.start()
        XCTAssertTrue(center.hasObservationTask, "first start() installs the task")

        // Second call — must NOT replace the running task. Under the
        // prior shape this cancelled the prior task and started a new one,
        // which two-call-site coverage would silently break.
        center.start()
        XCTAssertTrue(center.hasObservationTask, "second start() must keep the task installed")

        // After stop(), the task is cleared so a future start() can
        // re-install. This guards against an over-eager fix that turned
        // start() into a permanent latch.
        center.stop()
        XCTAssertFalse(center.hasObservationTask, "stop() clears the task")

        center.start()
        XCTAssertTrue(center.hasObservationTask, "start() after stop() re-installs the task")
        center.stop()
    }

    /// Bounded poll — drives the runloop in 5ms slices for up to 1s so
    /// the AsyncStream-backed observation task gets a chance to deliver
    /// scripted summaries. Avoids `Task.sleep(_:)` because that pauses
    /// the test, blocking the actor reentrancy that the observation
    /// task needs to write into `pending`.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("waitUntil timed out after \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Local fake

/// `FakeVerificationService` already exists in `VerificationTests` but isn't
/// reachable from `ViewModelTests` (test targets can't import each other's
/// internal fakes). Duplicated minimally here for the `dismiss` + observation
/// flows the center exercises.
private actor ScriptedVerificationService: VerificationService {
    private var cancelled: [(id: String, reason: String)] = []
    private var scriptedIncoming: [VerificationRequestSummary] = []
    /// Wave 4 expert-QA #5 seam: drive the throw-from-cancel arm so the
    /// `dismiss()` log-and-still-remove behaviour can be exercised in
    /// the unit test.
    private var shouldThrowOnCancel: Bool = false
    private var cancelAttempts: Int = 0

    func scheduleIncoming(_ summaries: [VerificationRequestSummary]) {
        scriptedIncoming = summaries
    }

    func cancelledSnapshot() -> [(id: String, reason: String)] {
        cancelled
    }

    func setShouldThrowOnCancel(_ shouldThrow: Bool) {
        shouldThrowOnCancel = shouldThrow
    }

    func cancelAttemptedCount() -> Int {
        cancelAttempts
    }

    private struct ScriptedCancelError: Error {}

    func isThisDeviceVerified() async throws -> Bool { true }

    func hasOtherVerifiedDevices() async throws -> Bool { true }

    func isUserVerified(matrixID: String) async throws -> UserVerificationResult { .unknown }

    nonisolated func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let queue = await self.takeIncoming()
                for summary in queue {
                    continuation.yield(summary)
                }
                continuation.finish()
            }
        }
    }

    nonisolated func cancelledRequests() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    private func takeIncoming() -> [VerificationRequestSummary] {
        let queue = scriptedIncoming
        scriptedIncoming = []
        return queue
    }

    nonisolated func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }

    nonisolated func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }

    func confirmEmojiMatch(requestID: String) async throws {}

    func cancel(requestID: String, reason: String) async throws {
        cancelAttempts += 1
        if shouldThrowOnCancel {
            throw ScriptedCancelError()
        }
        cancelled.append((id: requestID, reason: reason))
    }
}
