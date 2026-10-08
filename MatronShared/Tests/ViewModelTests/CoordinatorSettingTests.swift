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

    func testMigratedFlagIsPerUserAndDefaultsFalse() {
        let a = CoordinatorSetting(userID: "@a:s", defaults: defaults)
        XCTAssertFalse(a.migrated)
        a.migrated = true
        XCTAssertTrue(CoordinatorSetting(userID: "@a:s", defaults: defaults).migrated)
        XCTAssertFalse(CoordinatorSetting(userID: "@b:s", defaults: defaults).migrated)
        XCTAssertEqual(CoordinatorSetting.migratedKey(for: "@a:s"), "coordinator.migrated.@a:s")
    }

    /// Spec §3a: local only / journal only / both different / both empty /
    /// already migrated.
    func testReconcileRules() {
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: "cL", migrated: false), .push("cL"),
                       "journal has none, this device has one: first device wins")
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: "cJ", cached: nil, migrated: false), .adopt("cJ"))
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: "cJ", cached: "cL", migrated: false), .adopt("cJ"),
                       "a later device with a different cached id adopts the journal's")
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: nil, migrated: false), .adopt(nil))
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: "cL", migrated: true), .adopt(nil),
                       "after the first reconcile a journal 'none' is a clear from elsewhere, not a gap to fill")
        XCTAssertEqual(CoordinatorSetting.reconcile(journal: nil, cached: "", migrated: false), .adopt(nil))
    }

    func testNewChatModelIsOpus1M() {
        XCTAssertEqual(CoordinatorSetting.newChatModel, "opus[1m]")
    }
}
