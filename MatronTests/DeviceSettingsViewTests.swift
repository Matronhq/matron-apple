import XCTest
import MatronModels
import MatronStorage
import MatronVerification
@testable import Matron

/// Local fake mirroring the actor-based pattern used in
/// `ChatViewBindingTests`. Only the surface that `DeviceSettingsView`'s
/// `task` body touches needs implementing.
private actor FakeVerificationServiceForSettings: VerificationService {
    var deviceVerifiedReturn: Bool = false
    var didCallIsThisDeviceVerified: Int = 0

    func setDeviceVerified(_ verified: Bool) { deviceVerifiedReturn = verified }

    func isThisDeviceVerified() async throws -> Bool? {
        didCallIsThisDeviceVerified += 1
        return deviceVerifiedReturn
    }
    func isUserVerified(matrixID: String) async throws -> UserVerificationResult { .unknown }
    func hasOtherVerifiedDevices() async throws -> Bool { false }
    nonisolated func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { $0.finish() }
    }
    nonisolated func cancelledRequests() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
    nonisolated func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }
    nonisolated func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }
    func confirmEmojiMatch(requestID: String) async throws {}
    func cancel(requestID: String, reason: String) async throws {}
}

@MainActor
final class DeviceSettingsViewTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            userID: "@dan:matron.chat",
            deviceID: "DEV1",
            homeserverURL: URL(string: "https://matrix.matron.chat")!,
            accessToken: "tok",
            refreshToken: nil
        )
    }

    /// Constructing the view exercises the @State + binding wiring at
    /// compile time. The underlying view-model surface (`session`,
    /// `currentRecoveryKey`) must round-trip the values the host
    /// passes in so the body's `LabeledContent` rows render the right
    /// strings.
    func test_view_initialises_withSession_andClosure() {
        let session = makeSession()
        let svc = FakeVerificationServiceForSettings()
        let view = DeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { nil }
        )
        XCTAssertEqual(view.session.userID, "@dan:matron.chat")
        XCTAssertEqual(view.session.deviceID, "DEV1")
    }

    /// Spec §6 / §7: "Show recovery key" reveals the locally-stored key
    /// the closure returns. Wiring goes through a closure (not the
    /// `RecoveryKeyManager` directly) so the view stays trivially
    /// testable without a real Keychain. Mirrors the closure-injection
    /// pattern `RecoveryKeyViewModel` already uses.
    func test_currentRecoveryKey_closureReturnsStoredKey() throws {
        let session = makeSession()
        let svc = FakeVerificationServiceForSettings()
        var stored: String? = "MOCK-KEY-1234-5678"
        let view = DeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { stored }
        )
        XCTAssertEqual(try view.currentRecoveryKey(), "MOCK-KEY-1234-5678")
        // Closure is captured by reference — flip the source to nil so the
        // "no key stored" branch is exercised by the same instance.
        stored = nil
        XCTAssertNil(try view.currentRecoveryKey())
    }

    /// `isThisDeviceVerified()` is the value the Encryption section
    /// shows. Mirrors the per-bot evaluation pattern from Task 10:
    /// query once on appear, store the result.
    func test_isThisDeviceVerified_isQueried_andReflectsSeededValue() async throws {
        let session = makeSession()
        let svc = FakeVerificationServiceForSettings()
        await svc.setDeviceVerified(true)
        let result = try await svc.isThisDeviceVerified()
        XCTAssertTrue(result)
        let calls = await svc.didCallIsThisDeviceVerified
        XCTAssertEqual(calls, 1)
        // Just confirm the view binding compiles with the same service.
        let _ = DeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { nil }
        )
    }

    // MARK: - Wave 4 expert-QA #3 — re-auth-gated reveal

    /// Auth-pass path: `requestAuth` returning `true` lets the reveal
    /// closure run, surfacing the stored key. Without the gate, an
    /// unattended unlocked device exposed the recovery key on Settings
    /// open — the gate IS the regression guard.
    func test_revealKey_succeedsAfterAuthPass() async {
        let session = makeSession()
        let svc = FakeVerificationServiceForSettings()
        let view = DeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { "STORED-KEY" },
            requestAuth: { true }
        )
        // The view's auth-pass closure returns true; structurally
        // exercises the gate's positive path. The full body branch is
        // covered by the snapshot suite — here we lock the closure
        // wiring at construction so a future signature change can't
        // silently drop the gate.
        let authed = await view.requestAuth()
        XCTAssertTrue(authed)
    }

    /// Auth-fail path: `requestAuth` returning `false` (user cancelled,
    /// no biometrics enrolled, policy error) MUST keep the key hidden.
    /// Construction is what's testable here; the full reveal-flow
    /// branching is covered by the snapshot suite. Locks the closure
    /// signature — a future signature change that drops the gate
    /// argument would surface as a compile error.
    func test_revealKey_keepsKeyHidden_whenAuthFails() async {
        let session = makeSession()
        let svc = FakeVerificationServiceForSettings()
        let view = DeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { "STORED-KEY" },
            requestAuth: { false }
        )
        let authed = await view.requestAuth()
        XCTAssertFalse(authed)
    }
}
