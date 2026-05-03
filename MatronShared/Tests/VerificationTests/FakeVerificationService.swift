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

    /// Routed through the actor (no `nonisolated`) so tests can `await` this
    /// to flush the actor's serial queue — pending `Task { await self.recordX }`
    /// hops from the `nonisolated` stream constructors will have run by the
    /// time this returns. Previous `nonisolated` version gave no flush guarantee
    /// (bugbot caught it).
    func isThisDeviceVerified() async throws -> Bool { true }

    nonisolated func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
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
