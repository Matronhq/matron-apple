import XCTest
@testable import MatronDesignSystem

/// A pin's glyph: an emoji draws bare, a letter gets the tinted square.
final class PinGlyphTests: XCTestCase {
    func testLettersAndDigitsGetTheSquare() {
        XCTAssertTrue(PinGlyph.isLetter("S"))
        XCTAssertTrue(PinGlyph.isLetter("É"))
        XCTAssertTrue(PinGlyph.isLetter("1"))
        XCTAssertTrue(PinGlyph.isLetter("?"))
    }

    func testEmojiDrawBare() {
        XCTAssertFalse(PinGlyph.isLetter("📮"))
        XCTAssertFalse(PinGlyph.isLetter("☎️"), "text-default emoji with the emoji selector")
        XCTAssertFalse(PinGlyph.isLetter("👩‍👩‍👧‍👦"))
        XCTAssertFalse(PinGlyph.isLetter("🇬🇧"))
    }

    func testTheEditorCountsCodePoints() {
        XCTAssertEqual(PinEditorFields.count("  Inbox triage  "), 12)
        XCTAssertEqual(PinEditorFields.count("é"), 1)
    }
}
