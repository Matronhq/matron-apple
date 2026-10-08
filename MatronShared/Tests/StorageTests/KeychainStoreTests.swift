import XCTest
@testable import MatronStorage

final class KeychainStoreTests: XCTestCase {
    let store = KeychainStore(service: "chat.matron.test")

    override func tearDown() async throws {
        try? store.delete(key: "test-key")
    }

    func test_setAndGet_roundTripsString() throws {
        try store.set("hello world", forKey: "test-key")
        let value = try store.get(key: "test-key")
        XCTAssertEqual(value, "hello world")
    }

    func test_get_returnsNil_whenKeyMissing() throws {
        let value = try store.get(key: "missing-key")
        XCTAssertNil(value)
    }

    func test_delete_removesValue() throws {
        try store.set("transient", forKey: "test-key")
        try store.delete(key: "test-key")
        XCTAssertNil(try store.get(key: "test-key"))
    }

    func test_set_overwritesExistingValue() throws {
        try store.set("first", forKey: "test-key")
        try store.set("second", forKey: "test-key")
        XCTAssertEqual(try store.get(key: "test-key"), "second")
    }

    /// Documents that the `synchronizable` flag is independently configurable
    /// without breaking non-sync writes and that the two flavours target
    /// distinct keychain entries (same `service` + key with different
    /// `kSecAttrSynchronizable` values are stored as separate items).
    ///
    /// We skip the synchronizable-write half when the host lacks the
    /// keychain entitlement (`errSecMissingEntitlement = -34018`), which is
    /// the case for the SPM `swift test` runner without a signing team and
    /// also the iOS Simulator. The local (non-sync) write must still work.
    func test_synchronizableInstance_writesIndependently() throws {
        let local = KeychainStore(service: "chat.matron.test", synchronizable: false)
        let icloud = KeychainStore(service: "chat.matron.test", synchronizable: true)

        // The non-synchronizable side always works on the host runner.
        try local.set("local-value", forKey: "sync-test-key")
        XCTAssertEqual(try local.get(key: "sync-test-key"), "local-value")
        defer { try? local.delete(key: "sync-test-key") }

        // Probe the synchronizable side. If the host lacks keychain entitlements,
        // the call surfaces as KeychainError.unhandled(-34018) and we skip the
        // remainder of the assertion. Either way, the local entry above must
        // be unaffected.
        do {
            try icloud.set("icloud-value", forKey: "sync-test-key")
            XCTAssertEqual(try icloud.get(key: "sync-test-key"), "icloud-value")
            // Distinct namespace: local read returns the local value.
            XCTAssertEqual(try local.get(key: "sync-test-key"), "local-value")
            try? icloud.delete(key: "sync-test-key")
        } catch let KeychainError.unhandled(status) where status == -34018 {
            // Expected on hosts without the iCloud Keychain entitlement.
            // The sync flag is wired correctly; we just can't exercise the
            // round-trip here. Real-device coverage is Phase 7 territory.
            throw XCTSkip("Host lacks iCloud keychain entitlement (errSecMissingEntitlement)")
        }
    }
}
