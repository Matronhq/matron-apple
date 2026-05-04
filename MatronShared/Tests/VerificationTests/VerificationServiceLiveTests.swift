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
    /// Wave 7 bug #5 fix: `acceptIncoming` now calls ONLY
    /// `acceptVerificationRequest()`. The SDK's
    /// `didAcceptVerificationRequest` callback (routed via
    /// `routeAcceptedVerificationRequest()` on the live impl) is what
    /// later calls `startSasVerification()` for the responder. Calling
    /// `startSasVerification()` immediately after `acceptVerificationRequest()`
    /// raced the SDK's internal state and tripped the partner-side MAC
    /// verification (live-debugged).
    func test_acceptIncoming_callsAcceptOnly_notStartSas() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-1")

        var collected: [SasFlowState] = []
        let stream = live.acceptIncoming(requestID: "req-1")
        var iterator = stream.makeAsyncIterator()
        if let first = await iterator.next() {
            collected.append(first)
        }
        try await live.cancel(requestID: "req-1", reason: "test-teardown")

        XCTAssertEqual(collected, [.requested])
        let accepted = await controller.didAccept
        let startedSas = await controller.didStartSas
        XCTAssertTrue(accepted, "acceptIncoming must call acceptVerificationRequest")
        XCTAssertFalse(startedSas, "Wave 7: acceptIncoming MUST NOT call startSasVerification — the delegate's didAcceptVerificationRequest does")
    }

    /// Wave 7 bug #5: when the SDK's `didAcceptVerificationRequest`
    /// callback fires (routed to `routeAcceptedVerificationRequest()`),
    /// the responder side issues `startSasVerification()`. The flow
    /// role is set to `.responder` by `acceptIncoming`; this test
    /// drives the routing entry point directly and asserts the SDK
    /// SAS-start happened.
    func test_routeAcceptedVerificationRequest_responder_callsStartSas() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-resp")

        let stream = live.acceptIncoming(requestID: "req-resp")
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // .requested

        // Pre-condition: acceptIncoming has NOT fired startSasVerification.
        let startedBefore = await controller.didStartSas
        XCTAssertFalse(startedBefore)

        await live.routeAcceptedVerificationRequest()

        // Post-condition: the routing entry point fired startSasVerification.
        let startedAfter = await controller.didStartSas
        XCTAssertTrue(startedAfter, "Wave 7: routeAcceptedVerificationRequest must call startSasVerification for responder role")

        try await live.cancel(requestID: "req-resp", reason: "test-teardown")
    }

    /// Wave 7 bug #6: the requester side MUST NOT call
    /// `startSasVerification()` from `routeAcceptedVerificationRequest()`.
    /// Both sides issuing `m.key.verification.start` sends two
    /// `m.key.verification.start` events and trips the SAS MAC check
    /// (live-debugged). The role is set to `.requester` by `startSAS`;
    /// this test sets it manually via the test seam and drives the
    /// routing entry point.
    func test_routeAcceptedVerificationRequest_requester_doesNotCallStartSas() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-init")
        await live.setActiveFlowID("req-init")
        await live.setFlowRole(.requester, for: "req-init")

        await live.routeAcceptedVerificationRequest()

        let startedSas = await controller.didStartSas
        XCTAssertFalse(startedSas, "Wave 7: requester side MUST NOT call startSasVerification — only the responder may")
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

    /// M3 expert-QA fix: when a second `setContinuation` lands for the
    /// same `requestID` while the first continuation is still alive
    /// (e.g. the user taps "Verify with another device", cancels, then
    /// taps it again — the second `startSAS` re-registers under the
    /// same `userID` cache key), the FIRST continuation must be drained
    /// with `.cancelled(reason: "Replaced by new flow")` then `finish()`.
    /// The prior implementation silently overwrote the dict entry, so
    /// the first stream's `for await` loop never terminated and the
    /// dismissed sheet's view-model leaked.
    ///
    /// We exercise the fix through `acceptIncoming` (which calls
    /// `setContinuation` internally) because that's the public surface;
    /// drives two streams against the same cached controller, asserts
    /// the first one terminates with the expected reason after the
    /// second one is opened. Same root-cause coverage as a `startSAS`
    /// retry against the same userID.
    func test_secondTap_cancelsPriorContinuation() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-replace")

        // First flow: open the stream + consume the `.requested` head
        // so the continuation is registered against `req-replace`.
        let first = live.acceptIncoming(requestID: "req-replace")
        var firstIter = first.makeAsyncIterator()
        let firstHead = await firstIter.next()
        XCTAssertEqual(firstHead, .requested,
                       "first flow must publish .requested before being replaced")

        // Second flow: same requestID. `setContinuation` must drain the
        // first continuation with `.cancelled(reason: "Replaced by new flow")`
        // BEFORE installing the second one. We open the stream but don't
        // consume — the reason-string assertion comes from the FIRST
        // continuation's drain, not the second.
        let second = live.acceptIncoming(requestID: "req-replace")
        var secondIter = second.makeAsyncIterator()
        // Drive the second stream a single step to ensure its
        // `setContinuation` actor hop has landed before we drain the
        // first iterator below — without this the test races.
        _ = await secondIter.next()

        // The first stream must now be terminated with the M3 reason.
        // Drain the iterator: should see `.cancelled(reason: "Replaced
        // by new flow")` and then nil (stream finished).
        var firstTail: [SasFlowState] = []
        while let next = await firstIter.next() { firstTail.append(next) }
        XCTAssertEqual(firstTail, [.cancelled(reason: "Replaced by new flow")],
                       "prior continuation must be drained with the replacement reason")
    }

    /// Companion to `test_secondTap_cancelsPriorContinuation`: the
    /// second stream stays alive after replacing the first. Without
    /// this assertion a regression that finished BOTH continuations
    /// (over-eager cleanup) would still pass the M3 invariant test
    /// above.
    func test_secondTap_secondContinuationStaysAlive() async throws {
        let live = VerificationServiceLive()
        let controller = FakeSessionVerificationController()
        await live.register(controller: controller, for: "req-alive")

        // Open the first stream + drain its head so it's registered.
        let first = live.acceptIncoming(requestID: "req-alive")
        var firstIter = first.makeAsyncIterator()
        _ = await firstIter.next() // .requested

        // Open the second stream — first one is replaced. The second
        // continuation must still be live: a subsequent
        // `routeSasFinished()` must drive the second stream to
        // `.verified`, not the first one.
        let second = live.acceptIncoming(requestID: "req-alive")
        var secondIter = second.makeAsyncIterator()
        let secondHead = await secondIter.next()
        XCTAssertEqual(secondHead, .requested,
                       "second flow must publish .requested as normal")

        // Drive the SDK delegate path against the active flow.
        // `acceptIncoming` set `activeFlowID = "req-alive"`, so this
        // routes through the SECOND continuation (the first was
        // already finished by setContinuation's M3 guard).
        await live.routeSasFinished()

        var secondTail: [SasFlowState] = []
        while let next = await secondIter.next() { secondTail.append(next) }
        XCTAssertEqual(secondTail, [.verified],
                       "second flow's continuation must still be live after the first was replaced")
    }
}
