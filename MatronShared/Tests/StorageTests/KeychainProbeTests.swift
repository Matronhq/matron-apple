import XCTest
@testable import MatronStorage

/// Coverage for `KeychainProbe.run(keychain:)` (Phase 3 / Task 13).
///
/// The probe is the regression guard against shipping a Mac build with
/// broken `keychain-access-groups` entitlements — without it, the user
/// signs in, generates a recovery key, and never realises Keychain
/// persistence silently failed (bugbot caught the equivalent for iOS in
/// Phase 1 — that's why iOS uses `FileSessionStore` for the session blob).
final class KeychainProbeTests: XCTestCase {
    /// Positive path. Round-trips through a real `KeychainStore` against a
    /// throwaway service. The `synchronizable: false` side always works
    /// on the SPM `swift test` host (see `KeychainStoreTests.test_setAndGet`)
    /// — no entitlement gating to dance around.
    func test_run_succeeds_againstRealKeychainStore() throws {
        let store = KeychainStore(service: "chat.matron.test.probe")
        try KeychainProbe.run(keychain: store)

        // Probe must clean up after itself — leaving the entry behind
        // would let a stale value mask a future entitlement regression.
        XCTAssertNil(try store.get(key: KeychainProbe.probeKey),
                     "probe must delete its entry on success")
    }

    /// Negative path: write fails. Mirrors the `errSecMissingEntitlement`
    /// shape the Mac app would hit on a misconfigured bundle. Uses an
    /// in-memory `SessionStore` double so the failure mode is reproducible
    /// on the SPM host without standing up a deliberately-broken Keychain.
    func test_run_throwsSetFailed_whenStoreSetFails() {
        let store = ThrowingSessionStore(failureMode: .onSet)
        XCTAssertThrowsError(try KeychainProbe.run(keychain: store)) { error in
            guard case KeychainProbeError.setFailed(let underlying) = error else {
                return XCTFail("expected .setFailed, got \(error)")
            }
            XCTAssertEqual((underlying as? FakeStoreError), .injected)
        }
    }

    /// Negative path: read fails after a successful write. Probe must
    /// surface `.getFailed` and still attempt cleanup.
    func test_run_throwsGetFailed_whenStoreGetFails() {
        let store = ThrowingSessionStore(failureMode: .onGet)
        XCTAssertThrowsError(try KeychainProbe.run(keychain: store)) { error in
            guard case KeychainProbeError.getFailed = error else {
                return XCTFail("expected .getFailed, got \(error)")
            }
        }
        XCTAssertTrue(store.didAttemptDelete,
                      "probe must attempt cleanup even when get fails")
    }

    /// Negative path: round-trip mismatch. The store accepted the write
    /// but read returns a different value. This shape catches access-group
    /// collisions where another bundle's entry shadows ours.
    func test_run_throwsRoundTripMismatch_whenGetReturnsWrongValue() {
        let store = ThrowingSessionStore(failureMode: .returnsWrongValue)
        XCTAssertThrowsError(try KeychainProbe.run(keychain: store)) { error in
            guard case KeychainProbeError.roundTripMismatch(_, let got) = error else {
                return XCTFail("expected .roundTripMismatch, got \(error)")
            }
            XCTAssertEqual(got, "wrong-value")
        }
    }
}

// MARK: - Test doubles

private enum FakeStoreError: Error, Equatable {
    case injected
}

/// In-memory `SessionStore` double that can be configured to fail at any
/// step of the probe cycle. Lets the negative-path tests exercise every
/// `KeychainProbeError` branch without needing a deliberately-broken
/// Keychain (which doesn't exist on the SPM `swift test` host anyway).
private final class ThrowingSessionStore: SessionStore, @unchecked Sendable {
    enum FailureMode {
        case onSet
        case onGet
        case returnsWrongValue
        case onDelete
    }

    private var storage: [String: String] = [:]
    private let failureMode: FailureMode
    private(set) var didAttemptDelete = false

    init(failureMode: FailureMode) {
        self.failureMode = failureMode
    }

    func set(_ value: String, forKey key: String) throws {
        if case .onSet = failureMode { throw FakeStoreError.injected }
        storage[key] = value
    }

    func get(key: String) throws -> String? {
        switch failureMode {
        case .onGet:
            throw FakeStoreError.injected
        case .returnsWrongValue:
            return "wrong-value"
        default:
            return storage[key]
        }
    }

    func delete(key: String) throws {
        didAttemptDelete = true
        if case .onDelete = failureMode { throw FakeStoreError.injected }
        storage.removeValue(forKey: key)
    }
}
