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
}
