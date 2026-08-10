import XCTest
@testable import MatronDesignSystem

final class BoxChipTests: XCTestCase {
    /// The chip must never grow a row: it renders on the title line, capped
    /// to one line. Rows in this app have a hard fixed-height invariant
    /// (ChatRowHeightTests) that a wrapping chip would break.
    func testChipIsSingleLineAndTruncates() {
        let chip = BoxChip("a-very-long-box-name-that-will-not-fit")
        XCTAssertEqual(chip.displayName, "a-very-long-box-name-that-will-not-fit")
        XCTAssertEqual(chip.lineLimit, 1)
    }
}
