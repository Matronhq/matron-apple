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
    func test_macOS_appSupportPath_isUnderUserApplicationSupport() {
        let path = StoragePaths.appSupport
        XCTAssertTrue(path.path.contains("/Library/Application Support/chat.matron.mac"))
    }

    func test_macOS_cryptoStorePath_isUnderAppSupport() {
        XCTAssertEqual(StoragePaths.cryptoStorePath, StoragePaths.appSupport.appendingPathComponent("crypto-store"))
    }

    func test_macOS_searchDBPath_isUnderAppSupport() {
        XCTAssertEqual(StoragePaths.searchDBPath, StoragePaths.appSupport.appendingPathComponent("matron-search.sqlite"))
    }
    #endif
}
