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

    /// Pins name → palette index for fixed fixtures. If this test breaks,
    /// the hash or palette changed and every user's colours re-shuffle —
    /// that must never happen silently.
    func testPaletteIndexIsPinned() {
        XCTAssertEqual(BoxChip.paletteIndex(for: "eric"), 4)
        XCTAssertEqual(BoxChip.paletteIndex(for: "dan-mac"), 4)
        XCTAssertEqual(BoxChip.paletteIndex(for: "build-7"), 9)
        XCTAssertEqual(BoxChip.paletteIndex(for: ""), 1)      // FNV offset basis % 10
        XCTAssertEqual(BoxChip.paletteIndex(for: "🦊 box"), 1) // multi-byte UTF-8
    }

    func testPaletteIndexIsDeterministicAndInRange() {
        for name in ["eric", "dan-mac", "build-7", "", "🦊 box", "a-very-long-box-name-that-will-not-fit"] {
            let first = BoxChip.paletteIndex(for: name)
            XCTAssertEqual(first, BoxChip.paletteIndex(for: name))
            XCTAssertTrue((0..<BoxChip.palette.count).contains(first))
        }
        // Distinct fixtures observed to land on distinct hues.
        XCTAssertNotEqual(BoxChip.paletteIndex(for: "eric"), BoxChip.paletteIndex(for: "build-7"))
    }
}
