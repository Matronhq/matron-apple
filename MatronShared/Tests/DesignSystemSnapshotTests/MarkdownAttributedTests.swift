#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

/// Unit tests for the Mac-only markdown → `NSAttributedString` converter. Assert
/// on attributes at specific character indexes (located via `range(of:)`) so a
/// regression in the intent → attribute mapping is caught without a pixel diff.
final class MarkdownAttributedTests: XCTestCase {

    // MARK: - Helpers

    private func convert(_ source: String) -> NSAttributedString {
        MarkdownAttributed.attributedString(for: source)
    }

    /// Attributes at the first character of `substring` in `attributed`.
    private func attributes(
        of attributed: NSAttributedString,
        atFirst substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [NSAttributedString.Key: Any] {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound else {
            XCTFail("substring \(substring.debugDescription) not found in \(attributed.string.debugDescription)", file: file, line: line)
            return [:]
        }
        return attributed.attributes(at: range.location, effectiveRange: nil)
    }

    private func font(
        _ attrs: [NSAttributedString.Key: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NSFont {
        guard let font = attrs[.font] as? NSFont else {
            XCTFail("no font attribute", file: file, line: line)
            return .systemFont(ofSize: 12)
        }
        return font
    }

    // MARK: - Paragraphs

    func test_twoParagraphs_singleStringWithParagraphSpacing() {
        let attributed = convert("First paragraph.\n\nSecond paragraph.")

        // Both paragraphs land in one attributed string.
        XCTAssertTrue(attributed.string.contains("First paragraph."))
        XCTAssertTrue(attributed.string.contains("Second paragraph."))

        // The first paragraph carries the block paragraph spacing.
        let attrs = attributes(of: attributed, atFirst: "First")
        let style = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacing, 8)
    }

    // MARK: - Inline intents

    func test_bold_setsBoldTrait() {
        let attributed = convert("This is **bold** text.")
        let font = font(attributes(of: attributed, atFirst: "bold"))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_italic_setsItalicTrait() {
        let attributed = convert("This is *slanted* text.")
        let font = font(attributes(of: attributed, atFirst: "slanted"))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func test_inlineCode_monospacedWithBackground() {
        let attributed = convert("Run `swift test` now.")
        let attrs = attributes(of: attributed, atFirst: "swift test")
        XCTAssertTrue(font(attrs).fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(attrs[.backgroundColor] as? NSColor, NSColor.controlBackgroundColor)
    }

    func test_strikethrough_setsStrikeStyle() {
        let attributed = convert("This is ~~gone~~ now.")
        let attrs = attributes(of: attributed, atFirst: "gone")
        XCTAssertEqual(attrs[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
    }

    // MARK: - Lists

    func test_unorderedList_getsBulletPrefix() {
        let attributed = convert("- One\n- Two")
        XCTAssertTrue(attributed.string.contains("\u{2022} One"))
        XCTAssertTrue(attributed.string.contains("\u{2022} Two"))
    }

    func test_orderedList_getsNumberPrefix() {
        let attributed = convert("1. First\n2. Second")
        XCTAssertTrue(attributed.string.contains("1. First"))
        XCTAssertTrue(attributed.string.contains("2. Second"))
    }

    // MARK: - Links

    func test_httpsLink_getsLinkAttribute() {
        let attributed = convert("See the [docs](https://example.com/help) here.")
        let attrs = attributes(of: attributed, atFirst: "docs")
        XCTAssertEqual(attrs[.link] as? URL, URL(string: "https://example.com/help"))
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, NSColor.controlAccentColor)
    }

    func test_matrixLink_suppressedButAccentColoured() {
        let attributed = convert("Jump to [room](matrix:r/foo:example.com) now.")
        let attrs = attributes(of: attributed, atFirst: "room")
        XCTAssertNil(attrs[.link], "matrix: links must not become clickable")
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, NSColor.controlAccentColor)
    }

    // MARK: - Headers

    func test_headerSizesStepUp() {
        let base = MarkdownAttributed.baseFontSize

        let h1 = font(attributes(of: convert("# Big"), atFirst: "Big"))
        XCTAssertEqual(h1.pointSize, base * 1.4, accuracy: 0.01)
        XCTAssertTrue(h1.fontDescriptor.symbolicTraits.contains(.bold))

        let h2 = font(attributes(of: convert("## Medium"), atFirst: "Medium"))
        XCTAssertEqual(h2.pointSize, base * 1.25, accuracy: 0.01)

        let h3 = font(attributes(of: convert("### Small"), atFirst: "Small"))
        XCTAssertEqual(h3.pointSize, base * 1.1, accuracy: 0.01)
    }

    // MARK: - Code blocks

    func test_codeBlock_monospacedWithBackground() {
        let attributed = convert("""
        Here:
        ```swift
        let x = 1
        ```
        """)
        let attrs = attributes(of: attributed, atFirst: "let x = 1")
        let font = font(attrs)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(font.pointSize, 12)
        XCTAssertEqual(attrs[.backgroundColor] as? NSColor, NSColor.controlBackgroundColor)
    }

    // MARK: - Cache

    func test_sameSource_returnsCachedInstance() {
        let source = "A cached body with `code` and **bold**."
        let first = convert(source)
        let second = convert(source)
        XCTAssertTrue(first === second, "same source should hit the NSCache")
    }
}
#endif
