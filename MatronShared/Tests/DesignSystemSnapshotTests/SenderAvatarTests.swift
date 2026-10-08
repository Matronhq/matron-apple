import XCTest
import SwiftUI
@testable import MatronDesignSystem

final class SenderAvatarInitialsTests: XCTestCase {
    /// Collision cases from the spec: distinct box names with a shared
    /// letter prefix must still land on distinct initials so box-2 /
    /// box-3 / box-6's avatars read apart at a glance.
    func testInitials_digitsCountAsSegments() {
        XCTAssertEqual(SenderAvatar.initials(for: "box-2"), "B2")
        XCTAssertEqual(SenderAvatar.initials(for: "box-3"), "B3")
        XCTAssertEqual(SenderAvatar.initials(for: "box-6"), "B6")
    }

    func testInitials_twoWordName() {
        XCTAssertEqual(SenderAvatar.initials(for: "lab-mac"), "LM")
    }

    func testInitials_singleWordName_yieldsOneLetter() {
        // No second segment to draw from — must not pad or repeat.
        XCTAssertEqual(SenderAvatar.initials(for: "juno"), "J")
    }

    func testInitials_emptyString_doesNotCrash() {
        XCTAssertEqual(SenderAvatar.initials(for: ""), "")
    }

    func testInitials_capsAtTwoCharacters() {
        XCTAssertEqual(SenderAvatar.initials(for: "a-b-c"), "AB")
    }

    func testInitials_lowercaseInput_isUppercased() {
        XCTAssertEqual(SenderAvatar.initials(for: "atlas"), "A")
    }

    /// Leading/duplicate separators must not produce empty segments.
    func testInitials_ignoresEmptySegments() {
        XCTAssertEqual(SenderAvatar.initials(for: "--dev--2"), "D2")
    }

    /// `uppercased()` can EXPAND a character — German `ß` becomes `"SS"`
    /// — so capping at 2 characters BEFORE uppercasing doesn't bound the
    /// final string length. `"ß-a"` caps to the two letters "ß"/"a"
    /// pre-uppercase, which then uppercase to 3 displayed characters
    /// ("SSA") unless the cap is re-applied after (CodeRabbit, PR #141).
    func testInitials_expandingUppercase_staysCappedAtTwoCharacters() {
        XCTAssertEqual(SenderAvatar.initials(for: "ß-a"), "SS")
        XCTAssertEqual(SenderAvatar.initials(for: "ß-a").count, 2)
    }
}

final class SenderAvatarSnapshotTests: XCTestCase {
    /// Visual baseline: three avatars whose fixture names land on
    /// distinct `BoxChip` palette hues, side by side — confirms the
    /// circle + initials render legibly across the palette.
    func testAvatarRow() {
        let row = HStack(spacing: 8) {
            SenderAvatar("box-2")
            SenderAvatar("lab-mac")
            SenderAvatar("juno")
        }
        .padding(8)
        assertVariants(of: row, named: "SenderAvatar_row")
    }

    /// Same fixture names as `BoxChipTests.testChipFullPaletteSnapshots`
    /// (pinned to palette indices 0…9 there), reused here so white
    /// initials-on-fill contrast is reviewable across every hue — the
    /// lighter ones (cyan, mint) are the ones worth eyeballing.
    func testAvatarFullPaletteSnapshots() {
        let names = ["vega", "romeo", "india", "charlie", "quebec",
                     "delta", "lima", "alpha", "echo", "foxtrot"]
        let grid = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { ForEach(names.prefix(5), id: \.self) { SenderAvatar($0) } }
            HStack(spacing: 6) { ForEach(names.suffix(5), id: \.self) { SenderAvatar($0) } }
        }
        .padding(8)
        assertVariants(of: grid, named: "SenderAvatar_palette")
    }
}
