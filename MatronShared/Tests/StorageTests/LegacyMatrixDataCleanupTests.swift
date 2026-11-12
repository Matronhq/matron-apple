import XCTest
import Security
@testable import MatronStorage

final class LegacyMatrixDataCleanupTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyMatrixDataCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "LegacyMatrixDataCleanupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Records the services it was asked to delete and answers `status`.
    private final class FakeKeychain: @unchecked Sendable {
        var deleted: [String] = []
        var status: OSStatus
        init(status: OSStatus = errSecSuccess) { self.status = status }
        var eraser: LegacyMatrixDataCleanup.KeychainEraser {
            LegacyMatrixDataCleanup.KeychainEraser { service in
                self.deleted.append(service)
                return self.status
            }
        }
    }

    private func makeFolder(_ name: String, withFile: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if withFile {
            try Data("x".utf8).write(to: url.appendingPathComponent("data.sqlite3"))
        }
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func test_removesLegacyFoldersFlagsAndKeychainItem_andKeepsCurrentData() throws {
        let sdkStore = try makeFolder("sdk-store")
        let cryptoStore = try makeFolder("crypto-store")
        let trace = try makeFolder("matron-sdk-trace")
        let journal = try makeFolder("journal-store")
        let sessions = try makeFolder("sessions")
        let search = root.appendingPathComponent("matron-search.sqlite")
        try Data("x".utf8).write(to: search)

        defaults.set(true, forKey: "matron.verify-done.@alice:example.com")
        defaults.set(true, forKey: "matron.verify-done.@bob:example.com")
        defaults.set(true, forKey: "AppLock.enabled")
        defaults.set(["p1"], forKey: "matron.answeredPrompts.room-1")
        let keychain = FakeKeychain()

        let folders = LegacyMatrixDataCleanup.containerFolders(in: root)
            + [root.appendingPathComponent("matron-sdk-trace", isDirectory: true)]
        XCTAssertTrue(LegacyMatrixDataCleanup.run(folders: folders, defaults: defaults, keychain: keychain.eraser))

        XCTAssertFalse(exists(sdkStore))
        XCTAssertFalse(exists(cryptoStore))
        XCTAssertFalse(exists(trace))
        XCTAssertTrue(exists(journal))
        XCTAssertTrue(exists(sessions))
        XCTAssertTrue(exists(search))

        XCTAssertNil(defaults.object(forKey: "matron.verify-done.@alice:example.com"))
        XCTAssertNil(defaults.object(forKey: "matron.verify-done.@bob:example.com"))
        XCTAssertTrue(defaults.bool(forKey: "AppLock.enabled"))
        XCTAssertEqual(defaults.stringArray(forKey: "matron.answeredPrompts.room-1"), ["p1"])

        XCTAssertEqual(keychain.deleted, ["chat.matron.recovery"])
        XCTAssertTrue(defaults.bool(forKey: LegacyMatrixDataCleanup.doneKey))
    }

    func test_runsOnlyOnce() throws {
        let keychain = FakeKeychain()
        let folders = LegacyMatrixDataCleanup.containerFolders(in: root)
        LegacyMatrixDataCleanup.run(folders: folders, defaults: defaults, keychain: keychain.eraser)

        // Anything appearing after the first run is left alone.
        let sdkStore = try makeFolder("sdk-store")
        defaults.set(true, forKey: "matron.verify-done.@alice:example.com")
        XCTAssertTrue(LegacyMatrixDataCleanup.run(folders: folders, defaults: defaults, keychain: keychain.eraser))

        XCTAssertTrue(exists(sdkStore))
        XCTAssertTrue(defaults.bool(forKey: "matron.verify-done.@alice:example.com"))
        XCTAssertEqual(keychain.deleted.count, 1)
    }

    func test_nothingPresent_finishesQuietly() {
        let keychain = FakeKeychain(status: errSecItemNotFound)
        let folders = LegacyMatrixDataCleanup.containerFolders(in: root)
        XCTAssertTrue(LegacyMatrixDataCleanup.run(folders: folders, defaults: defaults, keychain: keychain.eraser))
        XCTAssertTrue(defaults.bool(forKey: LegacyMatrixDataCleanup.doneKey))
    }

    func test_lockedKeychain_retriesOnNextLaunch() throws {
        let sdkStore = try makeFolder("sdk-store")
        let keychain = FakeKeychain(status: errSecInteractionNotAllowed)
        let folders = LegacyMatrixDataCleanup.containerFolders(in: root)

        XCTAssertFalse(LegacyMatrixDataCleanup.run(folders: folders, defaults: defaults, keychain: keychain.eraser))
        XCTAssertFalse(exists(sdkStore), "the folders go even when the Keychain is locked")
        XCTAssertFalse(defaults.bool(forKey: LegacyMatrixDataCleanup.doneKey))

        keychain.status = errSecItemNotFound
        XCTAssertTrue(LegacyMatrixDataCleanup.run(folders: folders, defaults: defaults, keychain: keychain.eraser))
        XCTAssertEqual(keychain.deleted.count, 2)
        XCTAssertTrue(defaults.bool(forKey: LegacyMatrixDataCleanup.doneKey))
    }

    func test_otherKeychainErrors_areLoggedAndFinish() {
        let keychain = FakeKeychain(status: errSecMissingEntitlement)
        let folders = LegacyMatrixDataCleanup.containerFolders(in: root)
        XCTAssertTrue(LegacyMatrixDataCleanup.run(folders: folders, defaults: defaults, keychain: keychain.eraser))
        XCTAssertTrue(defaults.bool(forKey: LegacyMatrixDataCleanup.doneKey))
    }

    func test_containerFolders_nameOnlyTheMatrixStores() {
        XCTAssertEqual(LegacyMatrixDataCleanup.containerFolders(in: root).map(\.lastPathComponent),
                       ["sdk-store", "crypto-store"])
    }

    /// The live eraser against the real Keychain: a missing service is not
    /// an error. Skipped where the test runner has no usable Keychain.
    func test_liveEraser_missingServiceIsNotFound() throws {
        let status = LegacyMatrixDataCleanup.KeychainEraser.live
            .deleteService("chat.matron.tests.\(UUID().uuidString)")
        if status == errSecMissingEntitlement || status == errSecInteractionNotAllowed {
            throw XCTSkip("no usable Keychain here (OSStatus \(status))")
        }
        XCTAssertEqual(status, errSecItemNotFound)
    }
}
