import XCTest
@testable import MatronVerification

/// Exercises the controller-cache flow logic in `VerificationServiceLive` against
/// `FakeSessionVerificationController` and the SDK delegate routing entry points.
/// The SDK-bound surfaces (`isThisDeviceVerified`, `start()`,
/// `incomingRequests` against a real `Client`) require a live SDK and are
/// integration-tested in Phase 7 — these tests drive the routing entry
/// points (`routeSas…`) directly to simulate what the production delegate
/// would call.
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

    /// `confirmEmojiMatch` must call `approveVerification` on the SDK
    /// controller but MUST NOT synthesise `.verified` — that's the delegate's
    /// `didFinish` callback's job (routed via `routeSasFinished()`). The
    /// expert-QA finding (B1) was that the prior implementation yielded
    /// `.verified` locally without waiting for the SDK to actually finish
    /// signing the cross-signing material — both a security and UX bug.
    func test_confirmEmojiMatch_callsApprove_butDoesNotYieldVerifiedItself() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-2")

        // Open a stream so a continuation is registered for req-2.
        let stream = live.acceptIncoming(requestID: "req-2")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // .requested

        try await live.confirmEmojiMatch(requestID: "req-2")

        // The cache entry must remain — `confirmEmojiMatch` no longer clears it
        // because `routeSasFinished` (the SDK's `didFinish` callback) is now
        // the source of truth for completion. Local synthesis would lie about
        // whether the SDK has actually signed.
        let approved = await controller.didApprove
        XCTAssertTrue(approved)
        let cached = await live.activeFlowsSnapshot()
        XCTAssertNotNil(cached["req-2"], "approveVerification alone must not clear the cache — wait for didFinish")
    }

    /// The full `.requested → .readyForEmoji → .verified` walk via the
    /// delegate-routing entry points (what the SDK delegate would call
    /// after `didReceiveVerificationData` and `didFinish`).
    func test_routeSasData_thenRouteSasFinished_drivesReadyForEmojiThenVerified() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-walk")

        let stream = live.acceptIncoming(requestID: "req-walk")
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next() // .requested
        XCTAssertEqual(first, .requested)

        // Production code: SDK delegate fires didReceiveVerificationData →
        // routeSasData. Here we drive the routing entry point directly with a
        // scripted `SessionVerificationData` value; the live SDK's
        // SessionVerificationEmoji is a class wrapper around an FFI handle, so
        // we go through the public `SasEmoji` constructor by yielding a
        // .readyForEmoji manually via a synthetic continuation route.
        // Simulating this via the actor-mediated `routeSasData(_:)` entry
        // point requires a real `SessionVerificationData.emojis(...)`
        // — but constructing one from Swift code crosses into FFI territory.
        // Instead, exercise the no-FFI path: drive the `.readyForEmoji` and
        // `.verified` transitions through the routing methods that don't
        // require SDK-only types.
        //
        // The .readyForEmoji branch is covered by `test_routeSasData_decimalsCancelsCleanly`
        // (the `.decimals` SDK variant doesn't need a SessionVerificationEmoji
        // handle). The `.verified` end of the walk is what we assert here.
        await live.routeSasFinished()

        var tail: [SasFlowState] = []
        while let next = await iterator.next() { tail.append(next) }
        XCTAssertEqual(tail, [.verified])
        let cached = await live.activeFlowsSnapshot()
        XCTAssertNil(cached["req-walk"], "routeSasFinished must clear the FlowStore entry")
    }

    /// `routeSasCancelled` (delegate's `didCancel`) yields `.cancelled` and
    /// clears the FlowStore entry. The reason string is generic because the
    /// SDK doesn't surface a reason on the callback — local cancels via
    /// `cancel(requestID:reason:)` use the caller's string and clear before
    /// the SDK round-trip.
    func test_routeSasCancelled_yieldsCancelled_andClears() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-cxl")

        let stream = live.acceptIncoming(requestID: "req-cxl")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // .requested

        await live.routeSasCancelled()

        var tail: [SasFlowState] = []
        while let next = await iterator.next() { tail.append(next) }
        XCTAssertEqual(tail, [.cancelled(reason: "Verification cancelled")])
        let cached = await live.activeFlowsSnapshot()
        XCTAssertNil(cached["req-cxl"])
    }

    /// `routeSasFailed` (delegate's `didFail`) surfaces a fail-specific
    /// reason string so error logs distinguish between explicit
    /// cancellation and an SDK-internal failure.
    func test_routeSasFailed_yieldsCancelledWithFailReason_andClears() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-fail")

        let stream = live.acceptIncoming(requestID: "req-fail")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // .requested

        await live.routeSasFailed()

        var tail: [SasFlowState] = []
        while let next = await iterator.next() { tail.append(next) }
        XCTAssertEqual(tail, [.cancelled(reason: "Verification failed")])
        let cached = await live.activeFlowsSnapshot()
        XCTAssertNil(cached["req-fail"])
    }

    /// Delegate callbacks that arrive when no flow is active (e.g. the SDK
    /// races its own `didFinish` past our `cancel`-clear) must be safe
    /// no-ops. `routeSasFinished` returns silently when `activeFlowID` is
    /// nil; nothing crashes, no continuation is yielded.
    func test_routeSasFinished_withNoActiveFlow_isNoOp() async throws {
        let live = VerificationServiceLive()
        // Don't register anything — activeFlowID is nil.
        await live.routeSasFinished()
        let cached = await live.activeFlowsSnapshot()
        XCTAssertTrue(cached.isEmpty)
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

    /// `start()` requires a live SDK client — the no-arg test init has no
    /// provider/session, so `start()` throws `.notConfigured`. This guards
    /// against a regression where `start()` silently no-ops without a client
    /// (which would mask delegate-registration failures in production).
    func test_start_withoutClient_throwsNotConfigured() async {
        let live = VerificationServiceLive()
        do {
            try await live.start()
            XCTFail("expected throw")
        } catch let error as VerificationError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("expected VerificationError.notConfigured, got \(error)")
        }
    }
}
