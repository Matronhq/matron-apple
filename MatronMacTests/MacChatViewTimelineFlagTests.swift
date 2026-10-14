import XCTest
@testable import MatronMac

/// `chat.timeline.appkit` chooses which timeline `MacChatView` mounts
/// (spec 2026-09-28 §5); flag off keeps the SwiftUI `ScrollViewReader` tree.
@MainActor final class MacChatViewTimelineFlagTests: XCTestCase {
    func test_flagSelectsTimeline() {
        XCTAssertTrue(MacChatView.usesAppKitTimeline(defaults: Self.defaults(true)))
        XCTAssertFalse(MacChatView.usesAppKitTimeline(defaults: Self.defaults(false)))
    }

    func test_unsetFlagFallsBackToTheBuildDefault() {
        let d = UserDefaults(suiteName: "mac-timeline-flag-\(UUID().uuidString)")!
        XCTAssertEqual(MacChatView.usesAppKitTimeline(defaults: d), MacTimelineFlag.defaultValue)
    }

    private static func defaults(_ on: Bool) -> UserDefaults {
        let d = UserDefaults(suiteName: "mac-timeline-flag-\(UUID().uuidString)")!
        d.set(on, forKey: MacTimelineFlag.key)
        return d
    }
}
