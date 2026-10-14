import XCTest
@testable import MatronStorage

final class StoragePathsTests: XCTestCase {

    #if os(iOS)
    func test_iOS_appGroupIdentifier_isStable() {
        XCTAssertEqual(StoragePaths.appGroupIdentifier, "group.chat.matron")
    }

    func test_iOS_cryptoStorePath_endsWithExpectedComponent() {
        // groupContainer is force-unwrapped in StoragePaths (entitlement
        // required at runtime). In the test runner the entitlement is absent
        // so we don't touch the property here; instead we test the exported
        // path-derivation helper that doesn't rely on the entitlement.
        let fake = URL(fileURLWithPath: "/tmp/test-group")
        XCTAssertEqual(StoragePaths.cryptoStore(in: fake), fake.appendingPathComponent("crypto-store"))
        XCTAssertEqual(StoragePaths.searchDB(in: fake), fake.appendingPathComponent("matron-search.sqlite"))
    }
    #endif

    #if os(macOS)
    private let userSupport = URL(fileURLWithPath: "/Users/alice/Library/Application Support", isDirectory: true)

    func test_macOS_appSupportPath_isUnderUserApplicationSupport() {
        let path = StoragePaths.appSupport(environment: [:], userApplicationSupport: userSupport, processID: 1,
                                           isTestRun: false)
        XCTAssertEqual(path.path, "/Users/alice/Library/Application Support/chat.matron.app")
    }

    func test_macOS_overrideWins() {
        let path = StoragePaths.appSupport(environment: ["MATRON_APP_SUPPORT_OVERRIDE": "/tmp/box"],
                                           userApplicationSupport: userSupport, processID: 1, isTestRun: true)
        XCTAssertEqual(path.path, "/tmp/box")
    }

    /// A test run never opens the developer's own store, override or not.
    func test_macOS_testRunWithoutOverride_getsAThrowawayContainer() {
        let path = StoragePaths.appSupport(environment: [:], userApplicationSupport: userSupport, processID: 42,
                                           isTestRun: true)
        XCTAssertEqual(path.lastPathComponent, "matron-tests-42")
        XCTAssertFalse(path.path.hasPrefix(userSupport.path))
    }

    func test_macOS_thisTestRun_isNotInTheUsersStore() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertFalse(StoragePaths.appSupport.path.hasPrefix(real.path), StoragePaths.appSupport.path)
    }

    func test_macOS_cryptoStorePath_isUnderAppSupport() {
        XCTAssertEqual(StoragePaths.cryptoStorePath, StoragePaths.appSupport.appendingPathComponent("crypto-store"))
    }

    func test_macOS_searchDBPath_isUnderAppSupport() {
        XCTAssertEqual(StoragePaths.searchDBPath, StoragePaths.appSupport.appendingPathComponent("matron-search.sqlite"))
    }
    #endif
}
