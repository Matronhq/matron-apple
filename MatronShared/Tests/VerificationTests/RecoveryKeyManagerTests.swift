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

    override func tearDown() async throws {
        try? KeychainStore(service: testService).delete(key: RecoveryKeyManager.storageKey)
    }

    func test_currentKey_returnsNil_whenNothingStored() throws {
        let keychain = KeychainStore(service: testService)
        let manager = makeManager(keychain: keychain)
        XCTAssertNil(try manager.currentKey())
    }

    func test_currentKey_readsValuePreviouslyStored() throws {
        let keychain = KeychainStore(service: testService)
        try keychain.set("EsTk-secret-recovery-key", forKey: RecoveryKeyManager.storageKey)
        let manager = makeManager(keychain: keychain)
        XCTAssertEqual(try manager.currentKey(), "EsTk-secret-recovery-key")
    }

    func test_storageKey_isStable() {
        // The key is iCloud-synced, so its value is part of the on-disk
        // contract. A change here would orphan recovery keys on existing
        // installs.
        XCTAssertEqual(RecoveryKeyManager.storageKey, "matron.recovery-key")
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
