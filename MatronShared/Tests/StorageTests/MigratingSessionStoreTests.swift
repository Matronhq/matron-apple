import Security
import XCTest
@testable import MatronStorage

/// The session's move into the Keychain and the file fallback. The Keychain
/// is a fake here, so these never touch the real one.
final class MigratingSessionStoreTests: XCTestCase {
    private let key = "matron.journal.session"
    private var directory: URL!
    private var file: FileSessionStore!
    private var keychain: FakeKeychain!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        file = FileSessionStore(directory: directory)
        keychain = FakeKeychain()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private var store: MigratingSessionStore { MigratingSessionStore(keychain: keychain, file: file) }
    private var fileURL: URL { directory.appendingPathComponent("\(key).json") }
    private var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: - Migration

    func test_get_movesALegacyFileIntoTheKeychain_andDeletesTheFile() throws {
        try file.set("{\"userID\":\"alice\"}", forKey: key)

        XCTAssertEqual(try store.get(key: key), "{\"userID\":\"alice\"}")
        XCTAssertEqual(keychain.values[key], "{\"userID\":\"alice\"}")
        XCTAssertFalse(fileExists)
        // Later reads come from the Keychain.
        XCTAssertEqual(try store.get(key: key), "{\"userID\":\"alice\"}")
    }

    func test_get_keepsTheFile_whenTheKeychainWriteFails() throws {
        try file.set("alice-session", forKey: key)
        keychain.failure = .unhandled(errSecMissingEntitlement)

        XCTAssertEqual(try store.get(key: key), "alice-session", "nobody is signed out by a failed move")
        XCTAssertTrue(fileExists)
    }

    func test_get_prefersTheFile_overAnOlderKeychainItem() throws {
        keychain.values[key] = "old"
        try file.set("new", forKey: key)

        XCTAssertEqual(try store.get(key: key), "new")
        XCTAssertEqual(keychain.values[key], "new")
        XCTAssertFalse(fileExists)
    }

    func test_get_readsTheKeychain_whenThereIsNoFile() throws {
        keychain.values[key] = "alice-session"
        XCTAssertEqual(try store.get(key: key), "alice-session")
    }

    func test_get_returnsNil_whenNeitherHasASession() throws {
        XCTAssertNil(try store.get(key: key))
    }

    func test_get_returnsNil_whenTheKeychainIsUnusable_andThereIsNoFile() throws {
        keychain.failure = .unhandled(errSecMissingEntitlement)
        XCTAssertNil(try store.get(key: key))
    }

    // MARK: - Writes

    func test_set_writesTheKeychain_andRemovesTheFile() throws {
        try file.set("legacy", forKey: key)

        try store.set("bob-session", forKey: key)

        XCTAssertEqual(keychain.values[key], "bob-session")
        XCTAssertFalse(fileExists)
    }

    func test_set_fallsBackToTheFile_whenTheKeychainFails() throws {
        keychain.failure = .unhandled(errSecMissingEntitlement)

        try store.set("bob-session", forKey: key)

        XCTAssertEqual(try file.get(key: key), "bob-session")
        XCTAssertEqual(try store.get(key: key), "bob-session", "the fallback build restores its session")
    }

    func test_set_fallbackWrite_isNotShadowedByAnOlderKeychainItem() throws {
        keychain.values[key] = "old"
        keychain.failure = .unhandled(errSecInteractionNotAllowed)
        try store.set("new", forKey: key)

        keychain.failure = nil
        XCTAssertEqual(try store.get(key: key), "new")
    }

    // MARK: - Delete

    func test_delete_clearsBoth() throws {
        keychain.values[key] = "in-keychain"
        try file.set("in-file", forKey: key)

        try store.delete(key: key)

        XCTAssertNil(keychain.values[key])
        XCTAssertFalse(fileExists)
        XCTAssertNil(try store.get(key: key))
    }

    func test_delete_clearsTheFile_whenTheKeychainIsUnusable() throws {
        keychain.failure = .unhandled(errSecMissingEntitlement)
        try file.set("in-file", forKey: key)

        XCTAssertNoThrow(try store.delete(key: key))
        XCTAssertFalse(fileExists)
    }

    func test_delete_leavesASignedOutMarker_whenTheKeychainDeleteFails() throws {
        keychain.values[key] = "alice-session"
        keychain.failure = .unhandled(errSecInteractionNotAllowed)

        XCTAssertNoThrow(try store.delete(key: key))
        XCTAssertNil(try store.get(key: key), "a sign-out sticks even when the Keychain item stays")

        // Once the Keychain works again, the next read finishes the delete.
        keychain.failure = nil
        XCTAssertNil(try store.get(key: key))
        XCTAssertNil(keychain.values[key])
        XCTAssertFalse(fileExists)
    }

    func test_set_afterASignedOutMarker_signsBackIn() throws {
        keychain.values[key] = "alice-session"
        keychain.failure = .unhandled(errSecInteractionNotAllowed)
        try store.delete(key: key)
        keychain.failure = nil

        try store.set("bob-session", forKey: key)

        XCTAssertEqual(try store.get(key: key), "bob-session")
        XCTAssertFalse(fileExists)
    }

    // MARK: - Choosing the store

    func test_live_usesTheFileAlone_inATestRun() {
        XCTAssertTrue(SessionStores.live(directory: directory, environment: [:], arguments: [], isTestRun: true) is FileSessionStore)
    }

    func test_live_usesTheKeychain_outsideTests() {
        XCTAssertTrue(SessionStores.live(directory: directory, environment: [:], arguments: [], isTestRun: false)
            is MigratingSessionStore)
    }

    func test_live_usesTheFileAlone_withAContainerOverride() {
        let store = SessionStores.live(directory: directory,
                                       environment: ["MATRON_APP_SUPPORT_OVERRIDE": "/tmp/box-a"],
                                       arguments: [], isTestRun: false)
        XCTAssertTrue(store is FileSessionStore)
    }

    func test_live_usesTheFileAlone_withTheLaunchArgument() {
        let store = SessionStores.live(directory: directory, environment: [:],
                                       arguments: ["Matron", "-MatronSessionFile"], isTestRun: false)
        XCTAssertTrue(store is FileSessionStore)
    }

    // MARK: - The Keychain item's shape

    /// The session item, on a host without the `keychain-access-groups`
    /// entitlement (this test runner), either works or fails at once with
    /// `errSecMissingEntitlement` — the case the fallback covers. It never
    /// waits on a prompt. Uses its own service so it never meets a real
    /// session.
    func test_dataProtectionKeychainStore_worksOrReportsMissingEntitlement() throws {
        let store = KeychainStore(service: "chat.matron.test.session", synchronizable: false,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                  useDataProtectionKeychain: true)
        do {
            try store.set("alice-session", forKey: "test-key")
            defer { try? store.delete(key: "test-key") }
            XCTAssertEqual(try store.get(key: "test-key"), "alice-session")
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            // Expected without the entitlement.
        }
    }
}

/// In-memory stand-in for `KeychainStore` that can be made to fail.
private final class FakeKeychain: SessionStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var failure: KeychainError?

    func set(_ value: String, forKey key: String) throws {
        if let failure { throw failure }
        values[key] = value
    }

    func get(key: String) throws -> String? {
        if let failure { throw failure }
        return values[key]
    }

    func delete(key: String) throws {
        if let failure { throw failure }
        values[key] = nil
    }
}
