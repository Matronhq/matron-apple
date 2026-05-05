import Foundation
@testable import MatronVerification

/// Test fake conforming to `VerificationService`. Records calls and yields a
/// scripted state sequence so tests can assert transitions deterministically.
///
/// Mutable state lives on the actor; the protocol's nonisolated stream
/// constructors schedule `Task` calls back into the actor to record metadata.
actor FakeVerificationService: VerificationService {
    private(set) var didCallStart: [(userID: String, deviceID: String?)] = []
    private(set) var didConfirm: [String] = []
    private(set) var didCancel: [(requestID: String, reason: String)] = []
    /// Per-user tri-state verification map for `isUserVerified(matrixID:)`.
    /// Default for any user the test hasn't explicitly seeded is `.unknown`
    /// (was `.unverified` under the prior Bool shape). This matches the live
    /// impl's "identity not in the local crypto store yet" branch — the
    /// per-bot banner hides on `.unknown` and re-evaluates on the next
    /// sliding-sync tick rather than flashing "unverified" on cold start
    /// (expert-QA finding M2).
    private var userVerificationMap: [String: UserVerificationResult] = [:]

    /// Routed through the actor (no `nonisolated`) so tests can `await` this
    /// to flush the actor's serial queue — pending `Task { await self.recordX }`
    /// hops from the `nonisolated` stream constructors will have run by the
    /// time this returns. Previous `nonisolated` version gave no flush guarantee
    /// (bugbot caught it).
    func isThisDeviceVerified() async throws -> Bool { true }

    /// Test-tunable result for `hasOtherVerifiedDevices`. Default `true`
    /// matches the old test posture (callers that don't care about the
    /// chooser's SAS-availability gating get the existing behaviour).
    var hasOtherVerifiedDevicesValue: Bool = true
    func hasOtherVerifiedDevices() async throws -> Bool { hasOtherVerifiedDevicesValue }

    func isUserVerified(matrixID: String) async throws -> UserVerificationResult {
        userVerificationMap[matrixID, default: .unknown]
    }

    /// Bool-shape test seam preserved for callers that want `.verified` /
    /// `.unverified` only. Mirrors the original `setUserVerified(_:for:)`
    /// surface so existing tests don't churn — `true` maps to `.verified`
    /// and `false` maps to `.unverified`. Tests that need to exercise the
    /// `.unknown` branch should call `setUserVerificationResult(_:for:)`.
    func setUserVerified(_ verified: Bool, for matrixID: String) {
        userVerificationMap[matrixID] = verified ? .verified : .unverified
    }

    /// Test seam for the tri-state shape — exercises the `.unknown` arm
    /// that the Bool seam can't reach (M2 cold-start regression coverage).
    func setUserVerificationResult(_ result: UserVerificationResult, for matrixID: String) {
        userVerificationMap[matrixID] = result
    }

    nonisolated func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { $0.finish() }
    }

    nonisolated func cancelledRequests() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    nonisolated func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        Task { await self.recordStart(userID: userID, deviceID: deviceID) }
        let states: [SasFlowState] = [
            .requested,
            .readyForEmoji([SasEmoji(symbol: "🐢", description: "Turtle")]),
            .verified,
        ]
        return AsyncStream { continuation in
            for state in states {
                continuation.yield(state)
            }
            continuation.finish()
        }
    }

    nonisolated func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { continuation in
            continuation.yield(.requested)
            continuation.finish()
        }
    }

    func confirmEmojiMatch(requestID: String) async throws {
        didConfirm.append(requestID)
    }

    func cancel(requestID: String, reason: String) async throws {
        didCancel.append((requestID: requestID, reason: reason))
    }

    private func recordStart(userID: String, deviceID: String?) {
        didCallStart.append((userID: userID, deviceID: deviceID))
    }
}
