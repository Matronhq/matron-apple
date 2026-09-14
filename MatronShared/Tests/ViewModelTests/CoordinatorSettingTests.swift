import XCTest
import MatronModels

/// App shell (spec §5b): the coordinator conversation id, one per
/// signed-in journal user. Each test uses its own throwaway suite (the
/// `BoxCapacityCacheTests` idiom) so `.standard` is never touched.
final class CoordinatorSettingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.coordinatorSetting.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testKeyIsPerUser() {
        XCTAssertEqual(CoordinatorSetting.defaultsKey(for: "@a:s"), "coordinator.convoID.@a:s")
    }

    func testRoundTripsPerUser() {
        let a = CoordinatorSetting(userID: "@a:s", defaults: defaults)
        let b = CoordinatorSetting(userID: "@b:s", defaults: defaults)
        XCTAssertNil(a.convoID, "nil by default")
        a.convoID = "cv_1"
        XCTAssertEqual(a.convoID, "cv_1")
        XCTAssertNil(b.convoID, "another user's setting is untouched")
        XCTAssertEqual(CoordinatorSetting(userID: "@a:s", defaults: defaults).convoID, "cv_1", "survives a new instance")
    }

    func testClears() {
        let a = CoordinatorSetting(userID: "@a:s", defaults: defaults)
        a.convoID = "cv_1"
        a.convoID = nil
        XCTAssertNil(a.convoID)
        a.convoID = "cv_2"
        CoordinatorSetting.clear(for: "@a:s", defaults: defaults)
        XCTAssertNil(a.convoID)
        XCTAssertNil(defaults.object(forKey: CoordinatorSetting.defaultsKey(for: "@a:s")), "clearing removes the key outright")
    }
}
