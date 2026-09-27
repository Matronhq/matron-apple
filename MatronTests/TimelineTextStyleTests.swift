import XCTest
import UIKit
import MatronDesignSystem
@testable import Matron

final class TimelineTextStyleTests: XCTestCase {
    func test_defaultCategory_isTheSystemBody() {
        let style = TimelineTextStyle(sizeCategory: .large)
        XCTAssertEqual(style.bodySize, 17)
        XCTAssertEqual(style.markdown, .phoneChat(bodySize: 17))
        XCTAssertEqual(style.segmentSpacing, 8)
    }

    func test_dynamicType_scalesBodyAndCaption() {
        let small = TimelineTextStyle(sizeCategory: .large)
        let big = TimelineTextStyle(sizeCategory: .accessibilityExtraLarge)
        XCTAssertGreaterThan(big.bodySize, small.bodySize)
        XCTAssertGreaterThan(big.timestampFont.pointSize, small.timestampFont.pointSize)
        XCTAssertNotEqual(big, small, "the style is half of every measurement cache key")
    }

    func test_codeFont_isMonospacedCallout() {
        let style = TimelineTextStyle(sizeCategory: .large)
        XCTAssertTrue(style.codeFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertEqual(style.codeFont.pointSize, UIFont.preferredFont(forTextStyle: .callout).pointSize)
    }
}
