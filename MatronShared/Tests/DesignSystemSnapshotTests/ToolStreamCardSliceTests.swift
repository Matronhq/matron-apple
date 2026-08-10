import XCTest
@testable import MatronDesignSystem

/// Pins the collapsed-pane tail cap (`ToolStreamCard.collapsedSlice`):
/// a collapsed card must not re-parse + re-lay-out the full 64 KiB
/// stream tail on every append (2026-08-10 main-thread stalls), so it
/// renders only the last `collapsedDisplayCapChars`, opened at a line
/// boundary, and reports the cut so the truncation notice shows.
final class ToolStreamCardSliceTests: XCTestCase {
    func test_shortText_passesThroughUncut() {
        let (text, cut) = ToolStreamCard.collapsedSlice(of: "line one\nline two\n")
        XCTAssertEqual(text, "line one\nline two\n")
        XCTAssertFalse(cut)
    }

    func test_textAtCap_passesThroughUncut() {
        let exact = String(repeating: "x", count: ToolStreamCard.collapsedDisplayCapChars)
        let (text, cut) = ToolStreamCard.collapsedSlice(of: exact)
        XCTAssertEqual(text.count, exact.count)
        XCTAssertFalse(cut)
    }

    func test_longText_cutsToCapAndOpensAtLineBoundary() {
        // 200 numbered 40-char lines ≈ 8 KiB — over the 4 KiB cap.
        let lines = (0..<200).map { String(format: "%04d ", $0) + String(repeating: "a", count: 35) }
        let (text, cut) = ToolStreamCard.collapsedSlice(of: lines.joined(separator: "\n"))
        XCTAssertTrue(cut)
        XCTAssertLessThanOrEqual(text.count, ToolStreamCard.collapsedDisplayCapChars)
        // Opens on a complete line: the cap lands mid-line, and the partial
        // line up to the next newline is dropped.
        XCTAssertTrue(text.hasPrefix("0"), "expected a full numbered line at the head, got: \(text.prefix(12))…")
        // The tail (newest output) is always preserved verbatim.
        XCTAssertTrue(text.hasSuffix(lines.last!))
    }

    func test_singleGiantLine_keepsCapWorthOfTail() {
        // No newline anywhere in the suffix — nothing to trim to, keep the cap.
        let giant = String(repeating: "y", count: 3 * ToolStreamCard.collapsedDisplayCapChars)
        let (text, cut) = ToolStreamCard.collapsedSlice(of: giant)
        XCTAssertTrue(cut)
        XCTAssertEqual(text.count, ToolStreamCard.collapsedDisplayCapChars)
    }
}
