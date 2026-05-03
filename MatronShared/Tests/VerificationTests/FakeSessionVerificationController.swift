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

        func recordAccept()   { didAccept = true }
        func recordStartSas() { didStartSas = true }
        func recordApprove()  { didApprove = true }
        func recordDecline()  { didDecline = true }
        func recordCancel()   { didCancel = true }
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

    func acceptVerificationRequest() async throws { await recorder.recordAccept() }
    func startSasVerification()      async throws { await recorder.recordStartSas() }
    func approveVerification()       async throws { await recorder.recordApprove() }
    func declineVerification()       async throws { await recorder.recordDecline() }
    func cancelVerification()        async throws { await recorder.recordCancel() }
}
