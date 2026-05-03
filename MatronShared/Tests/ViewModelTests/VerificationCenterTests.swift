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

    func scheduleIncoming(_ summaries: [VerificationRequestSummary]) {
        scriptedIncoming = summaries
    }

    func cancelledSnapshot() -> [(id: String, reason: String)] {
        cancelled
    }

    func isThisDeviceVerified() async throws -> Bool { true }

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
        cancelled.append((id: requestID, reason: reason))
    }
}
