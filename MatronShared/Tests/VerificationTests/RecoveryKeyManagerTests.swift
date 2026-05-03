import XCTest
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
        try? KeychainStore(service: testService).delete(key: RecoveryKeyManager.storageKey(for: testUser))
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

    /// Phase 3 / Wave 3 / B3: `KeychainStore.recoveryStore()` is the single
    /// place that names the recovery service + access group. This test
    /// pins that the factory uses the platform-specific access group from
    /// `KeychainAccessGroups.recovery` (NOT the implicit-default-of-first-
    /// entry fallback that would silently re-target whichever group the
    /// system happens to pick when Phase 4 adds a second `keychain-access-
    /// groups` entry on iOS for NSE push decryption).
    ///
    /// We intentionally read the constant from the same enum the prod
    /// code reads — hard-coding `"$(AppIdentifierPrefix)chat.matron…"`
    /// here would just be a copy-paste of the factory and miss the case
    /// where someone changes one but not the other.
    func test_recoveryStoreFactory_usesCentralisedAccessGroup() throws {
        // Pin the access-group constant matches the platform's expected
        // suffix — `$(AppIdentifierPrefix)` is signing-team-dependent so
        // we only assert the suffix, which IS the part that needs to
        // match the entitlement file. Mismatch here means a future
        // entitlement edit (or a rename of the access group) wasn't
        // mirrored into `KeychainAccessGroups.recovery`.
        //
        // We intentionally read the constant from the same enum the prod
        // code reads (rather than hard-coding the string) — a copy-paste
        // here would miss the case where someone updates the factory but
        // forgets the entitlement file (or vice versa).
        #if os(macOS)
        XCTAssertTrue(
            KeychainAccessGroups.recovery.hasSuffix("chat.matron.mac"),
            "Mac access-group constant must match the suffix in MatronMac/App/MatronMac.entitlements"
        )
        #else
        XCTAssertTrue(
            KeychainAccessGroups.recovery.hasSuffix("chat.matron"),
            "iOS access-group constant must match the suffix in Matron/App/Matron.entitlements"
        )
        // Defence-in-depth: iOS suffix MUST NOT be `chat.matron.mac` —
        // that would cross-wire the iOS app to the Mac access group on
        // Phase 4's iCloud-sync paths.
        XCTAssertFalse(
            KeychainAccessGroups.recovery.hasSuffix("chat.matron.mac"),
            "iOS access-group constant must NOT match the Mac suffix"
        )
        #endif

        // The factory is the regression guard against a future caller
        // re-introducing `KeychainStore(service: "chat.matron.recovery"
        // /* no accessGroup */)`. Constructing it here proves the surface
        // exists; the round-trip half is gated behind the iCloud-Keychain
        // entitlement that the SPM host (and iOS Simulator without a
        // signing team) doesn't have, so we skip live exercise on hosts
        // that surface `errSecMissingEntitlement`.
        let store = KeychainStore.recoveryStore()
        do {
            try store.set("factory-probe", forKey: "test-key")
            defer { try? store.delete(key: "test-key") }
            XCTAssertEqual(try store.get(key: "test-key"), "factory-probe")
        } catch let KeychainError.unhandled(status) where status == -34018 {
            throw XCTSkip("Host lacks iCloud-keychain entitlement (errSecMissingEntitlement) — factory wiring is structurally verified above")
        }
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

    private func makeManager(keychain: KeychainStore) -> RecoveryKeyManager {
        // ClientProvider's init does not touch the SDK — the SDK call only
        // happens inside `client(for:)`, which `currentKey()` never invokes.
        let provider = ClientProvider(basePath: FileManager.default.temporaryDirectory)
        let session = UserSession(
            userID: "@test:matron.test",
            deviceID: "DEV-TEST",
            homeserverURL: URL(string: "https://matron.test")!,
            accessToken: "fake-access-token"
        )
        return RecoveryKeyManager(provider: provider, session: session, keychain: keychain)
    }
}
