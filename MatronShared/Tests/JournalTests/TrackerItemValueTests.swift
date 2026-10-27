import XCTest
import MatronModels

/// `TrackerItem` keeps its fields in a shared box so copies are cheap;
/// equality and hashing must still go by value, not by box.
final class TrackerItemValueTests: XCTestCase {
    private func item(title: String = "Ship it", deviceName: String? = "box") -> TrackerItem {
        TrackerItem(id: "it_1", num: 7, kind: .question, title: title, originConvoID: "c1",
                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                    actions: ["Merge", "Hold"], deviceName: deviceName)
    }

    func testSeparatelyBuiltItemsWithTheSameFieldsAreEqualAndHashAlike() {
        let a = item(), b = item()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(Set([a, b]).count, 1)
    }

    func testADifferentFieldMakesItemsUnequal() {
        XCTAssertNotEqual(item(), item(title: "Hold it"))
        XCTAssertNotEqual(item(), item(deviceName: "other"))
    }

    func testFieldsReadBackAsGiven() {
        let a = item(deviceName: "  box  ")
        XCTAssertEqual(a.id, "it_1")
        XCTAssertEqual(a.num, 7)
        XCTAssertEqual(a.title, "Ship it")
        XCTAssertEqual(a.actions, ["Merge", "Hold"])
        XCTAssertEqual(a.deviceName, "box")
        XCTAssertEqual(item(deviceName: "  ").deviceName, nil)
    }
}
