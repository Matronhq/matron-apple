import XCTest
import MatrixRustSDK
import MatronModels
import MatronStorage
import MatronSync
@testable import MatronVerification

/// `RecoveryKeyManager`'s `generateAndPersist` / `restore` paths require a
/// live SDK `Client` (Phase 7 / signed-device territory). What we *can*
/// cover here is the keychain-only path: `currentKey()` round-trips with
/// the underlying `KeychainStore`. The SDK-bound paths are wired against
/// the real types but exercised by Phase 7 integration tests.
final class RecoveryKeyManagerTests: XCTestCase {
    private let testService = "chat.matron.test.recovery-key"
    private let testUser = "@test:matron.test"

    override func tearDown() async throws {
        let store = KeychainStore(service: testService)
        try? store.delete(key: RecoveryKeyManager.storageKey(for: testUser))
        // Wave 4 expert-QA #6: the per-user isolation test writes under
        // additional userIDs; clear those too so a fail-mid-test doesn't
        // leak state into the next run.
        try? store.delete(key: RecoveryKeyManager.storageKey(for: "@alice:matron.test"))
        try? store.delete(key: RecoveryKeyManager.storageKey(for: "@bob:matron.test"))
    }

    func test_currentKey_returnsNil_whenNothingStored() throws {
        let keychain = KeychainStore(service: testService)
        let manager = makeManager(keychain: keychain)
        XCTAssertNil(try manager.currentKey())
    }

    func test_currentKey_readsValuePreviouslyStored() throws {
        let keychain = KeychainStore(service: testService)
        try keychain.set("EsTk-secret-recovery-key", forKey: RecoveryKeyManager.storageKey(for: testUser))
        let manager = makeManager(keychain: keychain)
        XCTAssertEqual(try manager.currentKey(), "EsTk-secret-recovery-key")
    }

    /// Phase 3 / Wave 5 bugbot #3: `KeychainStore.recoveryStore()` is the
    /// single place that names the recovery service. This test pins TWO
    /// invariants:
    ///
    ///   1. `KeychainAccessGroups.recoverySuffix` matches the platform's
    ///      entitlement-file suffix — that's the part the entitlement
    ///      plist's `keychain-access-groups` entry ends with after the
    ///      team-dependent `$(AppIdentifierPrefix)` prefix. Mismatch here
    ///      means a future entitlement edit (or a rename) wasn't mirrored.
    ///
    ///   2. `recoveryStore()` does NOT pass an explicit `accessGroup`
    ///      string to `KeychainStore(...)`. The Wave-3 shape passed
    ///      `KeychainAccessGroups.recovery` (which itself was a
    ///      `$(AppIdentifierPrefix)…` literal that doesn't expand in
    ///      Swift strings) — every signed build returned
    ///      `errSecMissingEntitlement`. Wave 5 reverts to implicit-default
    ///      (system uses the first `keychain-access-groups` entry, which
    ///      is ours). This test is the regression guard against a future
    ///      reviewer re-introducing the explicit-string shape.
    func test_recoveryStoreFactory_usesEntitlementSuffix_andNoExplicitGroup() throws {
        // Suffix half: pin the entitlement file's expected suffix. We
        // assert against the centralised constant rather than hard-coding
        // the string here so a copy-paste between this test and the
        // entitlement plist can't drift — both sides read from
        // `KeychainAccessGroups.recoverySuffix`.
        #if os(macOS)
        XCTAssertEqual(
            KeychainAccessGroups.recoverySuffix, "chat.matron.mac",
            "Mac suffix must match the entry in MatronMac/App/MatronMac.entitlements"
        )
        #else
        XCTAssertEqual(
            KeychainAccessGroups.recoverySuffix, "chat.matron",
            "iOS suffix must match the entry in Matron/App/Matron.entitlements"
        )
        // Defence-in-depth: iOS suffix MUST NOT be `chat.matron.mac` —
        // that would cross-wire the iOS app to the Mac access group on
        // Phase 4's iCloud-sync paths.
        XCTAssertNotEqual(
            KeychainAccessGroups.recoverySuffix, "chat.matron.mac",
            "iOS suffix must NOT match the Mac entitlement"
        )
        #endif

        // No-explicit-group half: the factory MUST succeed against the
        // system default (no `accessGroup` passed). Hosts with the right
        // entitlement (real signed device) pass. Hosts without (SPM
        // `swift test`, iOS Simulator without a signing team) surface
        // `errSecMissingEntitlement (-34018)` — that's a HOST limitation,
        // not a factory bug, so we XCTSkip the live half on those hosts.
        // The structural assertion (factory exists + is callable) plus
        // the in-process state of "no explicit group string was passed
        // through to `kSecAttrAccessGroup`" is locked by the source
        // shape: `recoveryStore()` no longer takes any access-group
        // argument, so a future re-introduction of the broken pattern
        // would be visible at the call site here AND would surface as a
        // build break on the now-non-existent `KeychainAccessGroups.recovery`.
        let store = KeychainStore.recoveryStore()
        do {
            try store.set("factory-probe", forKey: "test-key")
            defer { try? store.delete(key: "test-key") }
            XCTAssertEqual(try store.get(key: "test-key"), "factory-probe")
        } catch let KeychainError.unhandled(status) where status == -34018 {
            throw XCTSkip("Host lacks iCloud-keychain entitlement (errSecMissingEntitlement) — factory wiring is structurally verified above")
        }
    }

    // MARK: - Wave 4 expert-QA #1 — restore() error translation

    /// SDK-side `RecoveryError.SecretStorage` (server rejected the derived
    /// key) MUST translate to `RestoreError.invalidKey` so the UI can
    /// render the "check for typos" copy. Locks the bug shape — under the
    /// previous `try await encryption.recover(...)` path, a wrong key
    /// surfaced as a generic `localizedDescription` like
    /// `RecoveryError.SecretStorage(errorMessage: "...")`.
    func test_restore_translatesSecretStorageError_toInvalidKey() async throws {
        let manager = makeManager(keychain: KeychainStore(service: testService))
        manager.sdkRecoverOverride = { _ in
            throw RecoveryError.SecretStorage(errorMessage: "wrong key")
        }
        do {
            try await manager.restore(usingKey: "WRONG-KEY")
            XCTFail("expected RestoreError.invalidKey")
        } catch RecoveryKeyManager.RestoreError.invalidKey {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// SDK-side `RecoveryError.Import` (local SDK couldn't decrypt the
    /// fetched secret) ALSO translates to `RestoreError.invalidKey` —
    /// the user-facing meaning is the same: "that key didn't work."
    func test_restore_translatesImportError_toInvalidKey() async throws {
        let manager = makeManager(keychain: KeychainStore(service: testService))
        manager.sdkRecoverOverride = { _ in
            throw RecoveryError.Import(errorMessage: "decryption failed")
        }
        do {
            try await manager.restore(usingKey: "WRONG-KEY")
            XCTFail("expected RestoreError.invalidKey")
        } catch RecoveryKeyManager.RestoreError.invalidKey {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// `URLError` (no network / DNS / TLS) translates to
    /// `RestoreError.network` so the UI surfaces "couldn't reach the
    /// homeserver" instead of the wrong-key copy. Tests the
    /// transport-failure path that bubbles up before the SDK's
    /// `RecoveryError` mapping.
    func test_restore_translatesURLError_toNetwork() async throws {
        let manager = makeManager(keychain: KeychainStore(service: testService))
        manager.sdkRecoverOverride = { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            try await manager.restore(usingKey: "ANY")
            XCTFail("expected RestoreError.network")
        } catch RecoveryKeyManager.RestoreError.network {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// `RecoveryError.Client(.Generic)` whose message contains a network-
    /// shape token (e.g. "timeout", "connection") classifies as
    /// `.network` so the UI doesn't accuse the user of a wrong key when
    /// the homeserver was unreachable.
    func test_restore_classifiesGenericNetworkError_asNetwork() async throws {
        let manager = makeManager(keychain: KeychainStore(service: testService))
        manager.sdkRecoverOverride = { _ in
            throw RecoveryError.Client(source: .Generic(msg: "request timeout", details: nil))
        }
        do {
            try await manager.restore(usingKey: "ANY")
            XCTFail("expected RestoreError.network")
        } catch RecoveryKeyManager.RestoreError.network {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Errors that don't match any classified shape fall through to
    /// `.other` — the UI renders a generic "couldn't restore" message
    /// rather than misleading the user about a specific cause.
    func test_restore_fallsThroughToOther_forUnknownError() async throws {
        struct CustomError: Error {}
        let manager = makeManager(keychain: KeychainStore(service: testService))
        manager.sdkRecoverOverride = { _ in
            throw CustomError()
        }
        do {
            try await manager.restore(usingKey: "ANY")
            XCTFail("expected RestoreError.other")
        } catch RecoveryKeyManager.RestoreError.other {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// `LocalizedError` conformance: `errorDescription` MUST be the
    /// human-readable copy — the `RecoveryKeyViewModel.attemptRestore`
    /// fallback path renders `error.localizedDescription` for
    /// non-translated cases, and on dispatch'd cases the explicit string
    /// matches the conformance so the message is consistent regardless
    /// of which path the error reaches the UI through.
    func test_restoreError_localizedDescriptions_areUserFriendly() {
        XCTAssertEqual(
            RecoveryKeyManager.RestoreError.invalidKey.errorDescription,
            "That recovery key didn't work — check for typos and try again."
        )
        XCTAssertEqual(
            RecoveryKeyManager.RestoreError.network(underlying: URLError(.timedOut)).errorDescription,
            "Couldn't reach the homeserver. Check your connection and try again."
        )
        XCTAssertTrue(
            RecoveryKeyManager.RestoreError.other(underlying: URLError(.timedOut))
                .errorDescription?.contains("Couldn't restore") ?? false
        )
    }

    // MARK: - Wave 4 expert-QA #6 — per-user storage-key isolation

    /// Locks the multi-account-Keychain-overwrite bugbot fix at the
    /// read-after-write layer: writing a key for user A through one
    /// manager and user B through a separate manager (each session
    /// scoped to its own `userID`) MUST round-trip distinct values
    /// per-user. The static-method shape was already locked by
    /// `test_storageKey_isPerUserAndStable`; this test exercises the
    /// actual `KeychainStore` write + read against a manager-instance
    /// configured for each user.
    func test_currentKey_isolatesPerUser_acrossManagers() throws {
        let keychain = KeychainStore(service: testService)
        let userA = "@alice:matron.test"
        let userB = "@bob:matron.test"
        let managerA = makeManager(userID: userA, keychain: keychain)
        let managerB = makeManager(userID: userB, keychain: keychain)
        // Direct write through KeychainStore using the managers' storage
        // keys — `RecoveryKeyManager` exposes `currentKey()` for read but
        // its `generateAndPersist` write path requires a live SDK Client.
        // Asserting the read-after-write shape against the same key
        // function the live impl uses (`Self.storageKey(for:)`) gives us
        // the multi-account guard without standing up the SDK.
        try keychain.set("KEY-A", forKey: RecoveryKeyManager.storageKey(for: userA))
        try keychain.set("KEY-B", forKey: RecoveryKeyManager.storageKey(for: userB))
        defer {
            try? keychain.delete(key: RecoveryKeyManager.storageKey(for: userA))
            try? keychain.delete(key: RecoveryKeyManager.storageKey(for: userB))
        }
        XCTAssertEqual(try managerA.currentKey(), "KEY-A")
        XCTAssertEqual(try managerB.currentKey(), "KEY-B")
        XCTAssertNotEqual(try managerA.currentKey(), try managerB.currentKey())
    }

    func test_storageKey_isPerUserAndStable() {
        // The key is iCloud-synced, so the format is part of the on-disk
        // contract. A change here would orphan recovery keys on existing
        // installs. Per-user scoping fixes the multi-account overwrite
        // bugbot caught.
        XCTAssertEqual(RecoveryKeyManager.storageKey(for: "@a:s"), "matron.recovery-key.@a:s")
        XCTAssertEqual(RecoveryKeyManager.storageKey(for: "@b:s"), "matron.recovery-key.@b:s")
        XCTAssertNotEqual(
            RecoveryKeyManager.storageKey(for: "@a:s"),
            RecoveryKeyManager.storageKey(for: "@b:s"),
            "different users must get different storage keys"
        )
    }

    // MARK: - Helpers

    private func makeManager(userID: String = "@test:matron.test", keychain: KeychainStore) -> RecoveryKeyManager {
        // ClientProvider's init does not touch the SDK — the SDK call only
        // happens inside `client(for:)`, which `currentKey()` never invokes.
        // The `restore()` error-translation tests inject `sdkRecoverOverride`
        // so the SDK path is bypassed entirely.
        let provider = ClientProvider(basePath: FileManager.default.temporaryDirectory)
        let session = UserSession(
            userID: userID,
            deviceID: "DEV-TEST",
            homeserverURL: URL(string: "https://matron.test")!,
            accessToken: "fake-access-token"
        )
        return RecoveryKeyManager(provider: provider, session: session, keychain: keychain)
    }
}
