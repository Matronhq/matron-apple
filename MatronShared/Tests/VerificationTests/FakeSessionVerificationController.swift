import Foundation
@testable import MatronVerification

/// In-memory fake conforming to `SessionVerificationControlling`. Records calls so
/// `VerificationServiceLive` flow tests can assert which controller methods fired
/// without spinning up a real SDK `Client`.
///
/// Backed by an internal `Recorder` actor so mutation from the protocol's `async`
/// methods is concurrency-safe under Swift 6 strict checking. The class itself is
/// `@unchecked Sendable` because it only forwards into the actor; the public
/// observation properties block on the actor to read.
final class FakeSessionVerificationController: SessionVerificationControlling, @unchecked Sendable {
    private actor Recorder {
        var didAccept = false
        var didStartSas = false
        var didApprove = false
        var didDecline = false
        var didCancel = false
        /// Call counters — useful for asserting idempotency / double-fire
        /// behaviour where the SDK fires its callbacks more than once
        /// (matrix-rust-sdk has been observed to fire
        /// `didAcceptVerificationRequest` twice in succession; tests use
        /// these counts to assert the wrapper handles it safely).
        var startSasCount = 0
        var acceptCount = 0
        /// Configurable error for the next `startSasVerification` call
        /// (cleared on first throw). Lets the cleanup-path test simulate
        /// "the SDK threw during route" without requiring a real client.
        var nextStartSasError: Error?

        func recordAccept()   { didAccept = true; acceptCount += 1 }
        func recordStartSas() throws {
            didStartSas = true; startSasCount += 1
            if let err = nextStartSasError {
                nextStartSasError = nil
                throw err
            }
        }
        func recordApprove()  { didApprove = true }
        func recordDecline()  { didDecline = true }
        func recordCancel()   { didCancel = true }
        func setNextStartSasError(_ err: Error) { nextStartSasError = err }
    }

    private let recorder = Recorder()

    var didAccept: Bool {
        get async { await recorder.didAccept }
    }
    var didStartSas: Bool {
        get async { await recorder.didStartSas }
    }
    var didApprove: Bool {
        get async { await recorder.didApprove }
    }
    var didDecline: Bool {
        get async { await recorder.didDecline }
    }
    var didCancel: Bool {
        get async { await recorder.didCancel }
    }
    var startSasCount: Int {
        get async { await recorder.startSasCount }
    }
    var acceptCount: Int {
        get async { await recorder.acceptCount }
    }

    /// Set the error the NEXT `startSasVerification` call should throw.
    /// One-shot — cleared on first throw.
    func setNextStartSasError(_ error: Error) async {
        await recorder.setNextStartSasError(error)
    }

    func acceptVerificationRequest() async throws { await recorder.recordAccept() }
    func startSasVerification()      async throws { try await recorder.recordStartSas() }
    func approveVerification()       async throws { await recorder.recordApprove() }
    func declineVerification()       async throws { await recorder.recordDecline() }
    func cancelVerification()        async throws { await recorder.recordCancel() }
}
