import XCTest
import MatronChat
import MatronModels
@testable import MatronMac

/// The shared timeline sources compile into the Mac app and behave as on iOS.
final class TimelineSharedSourcesTests: XCTestCase {
    func test_scrollModelPinsToBottomWhileFollowing() {
        var model = TimelineScrollModel()
        model.setViewportHeight(500)
        model.replaceRows((0..<20).map { .init(id: "r\($0)", height: 100) }, footerHeight: 0)
        XCTAssertTrue(model.isFollowingTail)
        XCTAssertEqual(model.contentOffsetY, model.maxOffsetY, accuracy: 0.01)
    }

    func test_senderLabelsMatchBothItemViews() {
        XCTAssertEqual(TimelineSenderLabels.displayName(for: "@bot:server.com"), "bot")
        XCTAssertEqual(MacTimelineItemView.displayName(for: "@bot:server.com"), "bot")
    }
}
