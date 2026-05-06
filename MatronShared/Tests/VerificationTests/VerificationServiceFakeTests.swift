import XCTest
@testable import MatronVerification

final class VerificationServiceFakeTests: XCTestCase {
    func test_startSAS_yieldsScriptedTransitions() async throws {
        let svc = FakeVerificationService()
        var collected: [SasFlowState] = []
        for await state in svc.startSAS(withUser: "@a:s", deviceID: "DEV1") {
            collected.append(state)
        }
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected.first, .requested)
        XCTAssertEqual(collected.last, .verified)
    }

    func test_startSAS_recordsCallArgumentsOnActor() async throws {
        let svc = FakeVerificationService()
        // Drain the stream to ensure the recording task has had a chance to run.
        for await _ in svc.startSAS(withUser: "@b:s", deviceID: nil) {}
        // The recording is fire-and-forget via `Task { await self.recordStart }`
        // from a `nonisolated` startSAS. The Task body races with subsequent
        // actor calls — even an actor-isolated probe doesn't fully serialise
        // it (the Task creation queues the hop separately). Poll-with-timeout
        // so a slower CI runner doesn't see an empty array. Was a flake.
        var calls: [(userID: String, deviceID: String?)] = []
        let deadline = Date().addingTimeInterval(2)
        while calls.isEmpty && Date() < deadline {
            calls = await svc.didCallStart
            if calls.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.userID, "@b:s")
        XCTAssertNil(calls.first?.deviceID)
    }

    func test_confirmEmojiMatch_recordsRequestID() async throws {
        let svc = FakeVerificationService()
        try await svc.confirmEmojiMatch(requestID: "req-1")
        let confirmed = await svc.didConfirm
        XCTAssertEqual(confirmed, ["req-1"])
    }

    func test_cancel_recordsReason() async throws {
        let svc = FakeVerificationService()
        try await svc.cancel(requestID: "req-2", reason: "user-cancelled")
        let cancels = await svc.didCancel
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.requestID, "req-2")
        XCTAssertEqual(cancels.first?.reason, "user-cancelled")
    }

    func test_acceptIncoming_emitsRequestedThenFinishes() async throws {
        let svc = FakeVerificationService()
        var collected: [SasFlowState] = []
        for await state in svc.acceptIncoming(requestID: "req-3") {
            collected.append(state)
        }
        XCTAssertEqual(collected, [.requested])
    }

    func test_isThisDeviceVerified_returnsTrueByDefault() async throws {
        let svc = FakeVerificationService()
        let verified = try await svc.isThisDeviceVerified()
        XCTAssertEqual(verified, true)
    }

    /// M2 expert-QA fix: the default for an un-seeded user is `.unknown`,
    /// not `.unverified` — collapsing "identity not loaded" into
    /// "unverified" caused the per-bot banner to flash on every cold-start
    /// chat open until sliding-sync warmed up the local crypto store.
    /// Spec §7.5 still applies: callers hide the banner on `.unknown`
    /// (so nothing is auto-trusted) and re-evaluate on the next sync tick.
    func test_isUserVerified_returnsUnknown_whenIdentityNotCached() async throws {
        let svc = FakeVerificationService()
        let result = try await svc.isUserVerified(matrixID: "@bot:s")
        XCTAssertEqual(result, .unknown)
    }

    /// `setUserVerified(true, for:)` is the convenience seam — maps to
    /// `.verified` on the new tri-state map. Locks that the legacy
    /// boolean-shape seam still drives the `.verified` arm so existing
    /// callers don't churn.
    func test_isUserVerified_returnsVerified_whenIdentityVerified() async throws {
        let svc = FakeVerificationService()
        await svc.setUserVerified(true, for: "@bot:s")
        let result = try await svc.isUserVerified(matrixID: "@bot:s")
        XCTAssertEqual(result, .verified)
        // Other users are unaffected — they remain `.unknown`.
        let other = try await svc.isUserVerified(matrixID: "@other:s")
        XCTAssertEqual(other, .unknown)
    }

    /// `setUserVerified(false, for:)` maps to `.unverified` (NOT `.unknown`).
    /// This is the "SDK has the identity AND it's flagged unverified"
    /// branch — the banner renders on this state.
    func test_isUserVerified_returnsUnverified_whenSeededFalse() async throws {
        let svc = FakeVerificationService()
        await svc.setUserVerified(false, for: "@bot:s")
        let result = try await svc.isUserVerified(matrixID: "@bot:s")
        XCTAssertEqual(result, .unverified)
    }

    /// Exercises the tri-state seam directly so tests can cover the
    /// `.unknown` arm (which the Bool seam can't reach — Bool only maps
    /// to `.verified` / `.unverified`).
    func test_setUserVerificationResult_drivesAllThreeStates() async throws {
        let svc = FakeVerificationService()
        await svc.setUserVerificationResult(.verified,   for: "@v:s")
        await svc.setUserVerificationResult(.unverified, for: "@u:s")
        await svc.setUserVerificationResult(.unknown,    for: "@k:s")
        let v = try await svc.isUserVerified(matrixID: "@v:s")
        let u = try await svc.isUserVerified(matrixID: "@u:s")
        let k = try await svc.isUserVerified(matrixID: "@k:s")
        XCTAssertEqual(v, .verified)
        XCTAssertEqual(u, .unverified)
        XCTAssertEqual(k, .unknown)
    }
}
