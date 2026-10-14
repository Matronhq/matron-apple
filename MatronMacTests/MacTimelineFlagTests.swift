import XCTest
@testable import MatronMac

final class MacTimelineFlagTests: XCTestCase {
    func test_defaultsOnInDebugOffInRelease() {
        XCTAssertTrue(MacTimelineFlag.defaultValue(isDebugBuild: true))
        XCTAssertFalse(MacTimelineFlag.defaultValue(isDebugBuild: false))
        XCTAssertEqual(MacTimelineFlag.key, "chat.timeline.appkit")
    }
}
