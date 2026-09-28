#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

final class RenderedBaselineTests: XCTestCase {
    func test_lastBaselineIsInsideTheLastLineAndGrowsWithLines() {
        let one = MarkdownAttributed.rendered(for: "Hello", style: .chat)
        let three = MarkdownAttributed.rendered(for: "Hello\n\nSecond\n\nThird", style: .chat)
        let b1 = one.lastBaseline(width: 400), b3 = three.lastBaseline(width: 400)
        XCTAssertGreaterThan(b1, 0)
        XCTAssertLessThanOrEqual(b1, one.size(width: 400).height)
        XCTAssertGreaterThan(b3, b1 * 2)
        XCTAssertEqual(three.lastBaseline(width: 400), b3)   // memo stable
    }
}
#endif
