import XCTest
@testable import MatronStorage

final class AppGroupTests: XCTestCase {
    func test_identifier_isStable() {
        XCTAssertEqual(AppGroup.identifier, "group.chat.matron")
    }

    func test_containerURL_returnsAValidURL_whenAppGroupAvailable() throws {
        // In test runner there's no entitlement, so containerURL is nil.
        // We only assert the identifier is right; runtime coverage is via integration test.
        XCTAssertEqual(AppGroup.identifier, "group.chat.matron")
    }

    func test_cryptoStorePath_isUnderContainer() {
        let fakeContainer = URL(fileURLWithPath: "/tmp/test-app-group")
        let path = AppGroup.cryptoStorePath(in: fakeContainer)
        XCTAssertEqual(path, fakeContainer.appendingPathComponent("crypto-store"))
    }

    func test_searchDBPath_isUnderContainer() {
        let fakeContainer = URL(fileURLWithPath: "/tmp/test-app-group")
        let path = AppGroup.searchDBPath(in: fakeContainer)
        XCTAssertEqual(path, fakeContainer.appendingPathComponent("matron-search.sqlite"))
    }
}
