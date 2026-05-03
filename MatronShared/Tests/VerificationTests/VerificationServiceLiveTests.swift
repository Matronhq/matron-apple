import XCTest
@testable import MatronVerification

/// Exercises the controller-cache flow logic in `VerificationServiceLive` against
/// `FakeSessionVerificationController`. The SDK-bound surfaces (`isThisDeviceVerified`,
/// `incomingRequests`, `startSAS`) require a live `Client` and are integration-tested
/// in Phase 7.
final class VerificationServiceLiveTests: XCTestCase {
    func test_acceptIncoming_callsAcceptThenStartSas_andYieldsRequested() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-1")

        var collected: [SasFlowState] = []
        let stream = live.acceptIncoming(requestID: "req-1")
        // Collect the first emission (`.requested`) — the stream stays open waiting for
        // SDK delegate callbacks that won't arrive in this isolated test, so cancel
        // explicitly after the first state to terminate iteration.
        var iterator = stream.makeAsyncIterator()
        if let first = await iterator.next() {
            collected.append(first)
        }
        try await live.cancel(requestID: "req-1", reason: "test-teardown") // drains continuation

        XCTAssertEqual(collected, [.requested])
        let accepted = await controller.didAccept
        let startedSas = await controller.didStartSas
        XCTAssertTrue(accepted)
        XCTAssertTrue(startedSas)
    }

    func test_confirmEmojiMatch_callsApprove_yieldsVerified_andClearsCache() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-2")

        // Open a stream so a continuation is registered for req-2.
        let stream = live.acceptIncoming(requestID: "req-2")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // .requested

        try await live.confirmEmojiMatch(requestID: "req-2")

        // After approval the continuation should yield `.verified` and finish.
        var tail: [SasFlowState] = []
        while let next = await iterator.next() { tail.append(next) }

        let approved = await controller.didApprove
        XCTAssertTrue(approved)
        XCTAssertEqual(tail, [.verified])
        let cached = await live.activeFlowsSnapshot()
        XCTAssertNil(cached["req-2"], "approved request should be removed from activeFlows cache")
    }

    func test_cancel_callsCancelOnController_yieldsCancelledWithReason_andClearsCache() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-3")

        let stream = live.acceptIncoming(requestID: "req-3")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // .requested

        try await live.cancel(requestID: "req-3", reason: "user-cancelled")

        var tail: [SasFlowState] = []
        while let next = await iterator.next() { tail.append(next) }

        let cancelled = await controller.didCancel
        XCTAssertTrue(cancelled)
        XCTAssertEqual(tail, [.cancelled(reason: "user-cancelled")])
        let cached = await live.activeFlowsSnapshot()
        XCTAssertNil(cached["req-3"], "cancelled request should be removed from activeFlows cache")
    }

    func test_acceptIncoming_unknownRequestID_yieldsCancelled() async throws {
        let live = VerificationServiceLive()
        let stream = live.acceptIncoming(requestID: "missing")
        var collected: [SasFlowState] = []
        for await state in stream { collected.append(state) }
        XCTAssertEqual(collected.count, 1)
        if case let .cancelled(reason) = collected.first {
            XCTAssertTrue(reason.contains("missing"), "reason should mention the unknown ID")
        } else {
            XCTFail("expected .cancelled, got \(String(describing: collected.first))")
        }
    }

    func test_confirmEmojiMatch_unknownRequestID_throwsUnknownRequest() async throws {
        let live = VerificationServiceLive()
        do {
            try await live.confirmEmojiMatch(requestID: "missing")
            XCTFail("expected throw")
        } catch let error as VerificationError {
            XCTAssertEqual(error, .unknownRequest("missing"))
        }
    }

    func test_cancel_unknownRequestID_isNoOp() async throws {
        let live = VerificationServiceLive()
        // Should not throw; nothing to cancel.
        try await live.cancel(requestID: "missing", reason: "irrelevant")
    }
}
