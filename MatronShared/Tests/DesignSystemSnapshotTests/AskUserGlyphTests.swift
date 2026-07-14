import XCTest
@testable import MatronDesignSystem

/// Pins the pure `splitLeadingGlyph` helper that drives glyph/text alignment
/// across a stack of ask-user answer buttons.
final class AskUserGlyphTests: XCTestCase {
    func test_glyphFollowedBySpace_splits() {
        let (glyph, text) = splitLeadingGlyph("✕ Cancel")
        XCTAssertEqual(glyph, "✕")
        XCTAssertEqual(text, "Cancel")
    }

    func test_singleScalarSymbolGlyph_splits() {
        let (glyph, text) = splitLeadingGlyph("⚡ Send now")
        XCTAssertEqual(glyph, "⚡")
        XCTAssertEqual(text, "Send now")
    }

    func test_multiScalarEmojiGlyph_splits() {
        let (glyph, text) = splitLeadingGlyph("👍 Approve")
        XCTAssertEqual(glyph, "👍")
        XCTAssertEqual(text, "Approve")
    }

    func test_noGlyph_returnsWholeLabel() {
        let (glyph, text) = splitLeadingGlyph("Other action")
        XCTAssertNil(glyph)
        XCTAssertEqual(text, "Other action")
    }

    func test_alphanumericFirstChar_returnsWholeLabel() {
        let (glyph, text) = splitLeadingGlyph("1 apple")
        XCTAssertNil(glyph)
        XCTAssertEqual(text, "1 apple")
    }

    func test_glyphWithNoFollowingSpace_returnsWholeLabel() {
        let (glyph, text) = splitLeadingGlyph("⚡Send")
        XCTAssertNil(glyph)
        XCTAssertEqual(text, "⚡Send")
    }

    func test_wholeLabelIsGlyph_returnsWholeLabel() {
        let (glyph, text) = splitLeadingGlyph("⚡")
        XCTAssertNil(glyph)
        XCTAssertEqual(text, "⚡")
    }
}
