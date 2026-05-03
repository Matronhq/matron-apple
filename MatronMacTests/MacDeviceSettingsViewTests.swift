#if os(macOS)
import XCTest
import MatronModels
import MatronVerification
@testable import MatronMac

/// Local fake mirroring the iOS `FakeVerificationServiceForSettings`.
private actor FakeVerificationServiceForSettings: VerificationService {
    var deviceVerifiedReturn: Bool = false

    func setDeviceVerified(_ verified: Bool) { deviceVerifiedReturn = verified }

    func isThisDeviceVerified() async throws -> Bool { deviceVerifiedReturn }
    func isUserVerified(matrixID: String) async throws -> Bool { false }
    nonisolated func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
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
final class MacDeviceSettingsViewTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            userID: "@dan:matron.chat",
            deviceID: "DEV-MAC-1",
            homeserverURL: URL(string: "https://matrix.matron.chat")!,
            accessToken: "tok",
            refreshToken: nil
        )
    }

    /// Constructing the view exercises the @State + binding wiring at
    /// compile time. `onFinished` round-trips through the explicit
    /// Done-button closure so the host can dismiss the sheet.
    func test_view_initialises_andOnFinishedFires() {
        let session = makeSession()
        let svc = FakeVerificationServiceForSettings()
        var dismissals = 0
        let view = MacDeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { nil },
            onFinished: { dismissals += 1 }
        )
        XCTAssertEqual(view.session.deviceID, "DEV-MAC-1")
        view.onFinished()
        XCTAssertEqual(dismissals, 1)
    }

    /// `currentRecoveryKey` closure round-trips a stored key. Mirrors
    /// the iOS test for the same surface — closure indirection keeps
    /// the view free of `RecoveryKeyManager` so it stays trivially
    /// testable without standing up a real `KeychainStore`.
    func test_currentRecoveryKey_closureReturnsStoredKey() throws {
        let session = makeSession()
        let svc = FakeVerificationServiceForSettings()
        var stored: String? = "MAC-MOCK-KEY-1234"
        let view = MacDeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { stored },
            onFinished: {}
        )
        XCTAssertEqual(try view.currentRecoveryKey(), "MAC-MOCK-KEY-1234")
        stored = nil
        XCTAssertNil(try view.currentRecoveryKey())
    }

    /// Verification service is queried for the current device's state;
    /// flipping the seeded value flips the underlying read.
    func test_isThisDeviceVerified_reflectsSeededValue() async throws {
        let svc = FakeVerificationServiceForSettings()
        await svc.setDeviceVerified(true)
        let verifiedTrue = try await svc.isThisDeviceVerified()
        XCTAssertTrue(verifiedTrue)
        await svc.setDeviceVerified(false)
        let verifiedFalse = try await svc.isThisDeviceVerified()
        XCTAssertFalse(verifiedFalse)
    }
}
#endif
