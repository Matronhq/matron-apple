import XCTest
@testable import MatronMac

final class MacTimelineFlagTests: XCTestCase {
    func test_defaultsOnInDebugAndRelease() {
        XCTAssertTrue(MacTimelineFlag.defaultValue(isDebugBuild: true))
        XCTAssertTrue(MacTimelineFlag.defaultValue(isDebugBuild: false))
        XCTAssertEqual(MacTimelineFlag.key, "chat.timeline.appkit")
    }
}
