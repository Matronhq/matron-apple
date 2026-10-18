#if os(macOS)
import XCTest
@testable import MatronMac

final class MacItemThreadFlagTests: XCTestCase {
    func test_key() {
        XCTAssertEqual(MacItemThreadFlag.key, "items.thread.native")
    }

    func test_onInDebugAndRelease() {
        XCTAssertTrue(MacItemThreadFlag.defaultValue(isDebugBuild: true))
        XCTAssertTrue(MacItemThreadFlag.defaultValue(isDebugBuild: false))
    }

    func test_isOn_readsTheStoredChoice_elseTheBuildDefault() throws {
        let suite = "MacItemThreadFlagTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MacItemThreadFlag.isOn(defaults), MacItemThreadFlag.defaultValue)
        defaults.set(false, forKey: MacItemThreadFlag.key)
        XCTAssertFalse(MacItemThreadFlag.isOn(defaults))
        defaults.set(true, forKey: MacItemThreadFlag.key)
        XCTAssertTrue(MacItemThreadFlag.isOn(defaults))
    }
}
#endif
