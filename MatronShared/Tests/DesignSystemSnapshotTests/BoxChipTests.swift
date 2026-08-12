import XCTest
import SwiftUI
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

    /// Visual baseline: two chips whose fixture names land on different
    /// palette hues, side by side, light/dark/axxxl.
    func testChipColorSnapshots() {
        let row = HStack(spacing: 6) {
            BoxChip("eric")  // palette index 4 (teal)
            BoxChip("greg")  // palette index 2 (orange)
        }
        .padding(8)
        assertVariants(of: row, named: "BoxChip_colors")
    }

    /// Every fixture name below hashes to a distinct palette index (0…9 in
    /// order), so this baseline shows the entire palette — text legibility
    /// over the tinted fill is reviewable for all ten hues in light, dark
    /// and accessibility variants at once.
    func testChipFullPaletteSnapshots() {
        let names = ["dev-7", "romeo", "india", "charlie", "quebec",
                     "delta", "lima", "alpha", "echo", "foxtrot"]
        for (index, name) in names.enumerated() {
            XCTAssertEqual(BoxChip.paletteIndex(for: name), index,
                           "\(name) must pin palette index \(index)")
        }
        let grid = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { ForEach(names.prefix(5), id: \.self) { BoxChip($0) } }
            HStack(spacing: 6) { ForEach(names.suffix(5), id: \.self) { BoxChip($0) } }
        }
        .padding(8)
        assertVariants(of: grid, named: "BoxChip_palette")
    }
}
