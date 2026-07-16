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
        XCTAssertEqual(h1.pointSize, base * 1.3, accuracy: 0.01)
        XCTAssertTrue(h1.fontDescriptor.symbolicTraits.contains(.bold))

        let h2 = font(attributes(of: convert("## Medium"), atFirst: "Medium"))
        XCTAssertEqual(h2.pointSize, base * 1.15, accuracy: 0.01)

        let h3 = font(attributes(of: convert("### Small"), atFirst: "Small"))
        XCTAssertEqual(h3.pointSize, base * 1.05, accuracy: 0.01)
    }

    /// A heading after a paragraph gets extra space above (on top of the
    /// previous paragraph's spacing) and a tighter gap below, so it visually
    /// closes the previous section and opens its own.
    func test_headerAfterParagraph_getsSpacingBefore() {
        let attributed = convert("Intro paragraph.\n\n## Section\n\nBody text.")
        let style = attributes(of: attributed, atFirst: "Section")[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacingBefore, 10)
        XCTAssertEqual(style?.paragraphSpacing, 6)
    }

    /// A message that STARTS with a heading must not carry the extra
    /// space-above — it would render as a dead band at the bubble top.
    func test_leadingHeader_suppressesSpacingBefore() {
        let attributed = convert("# Title\n\nBody text.")
        let style = attributes(of: attributed, atFirst: "Title")[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(style?.paragraphSpacingBefore, 0)
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

    // MARK: - Trailing newlines (Dan, 2026-07-16: dead space at bubble bottom)

    /// A fenced code block's run text keeps its trailing "\n" from the
    /// parser. Left in place at the END of a message it renders an empty
    /// monospaced line + paragraph spacing — ~25pt of dead space at the
    /// bottom of the bubble, and plan-style messages very often end with a
    /// code block. The converted string must never end with a newline,
    /// whatever the final block kind is.
    func test_output_neverEndsWithNewline() {
        let endings = [
            "para\n\n```swift\nlet x = 1\nlet y = 2\n```",
            "para\n\n```swift\nlet x = 1\n```\n",
            "para\n\n- alpha\n- beta",
            "para\n\n## Trailing heading",
            "Closing paragraph.",
            "Closing paragraph.\n\n\n",
        ]
        for source in endings {
            let attributed = convert(source)
            XCTAssertFalse(
                attributed.string.hasSuffix("\n"),
                "converted string must not end with a newline for source ending \(source.suffix(20).debugDescription)"
            )
        }
    }

    /// Mid-message, the same trailing "\n" doubled up with the block-boundary
    /// newline the builder appends — an empty code-styled line between a code
    /// block and the following paragraph. The boundary newline must be
    /// skipped when the previous block already ends with one.
    func test_codeBlockBeforeParagraph_singleNewlineBetween() {
        let attributed = convert("""
        Intro line.

        ```swift
        let x = 1
        ```

        Closing paragraph.
        """)
        XCTAssertTrue(
            attributed.string.contains("let x = 1\nClosing paragraph."),
            "exactly one newline between a code block and the next paragraph, got: \(attributed.string.debugDescription)"
        )
    }

    /// An intentional blank line INSIDE a fenced block is content, not block
    /// plumbing — only the block's final trailing newline is at issue.
    func test_codeBlock_keepsInteriorBlankLines() {
        let attributed = convert("""
        ```swift
        let a = 1

        let b = 2
        ```
        """)
        XCTAssertTrue(
            attributed.string.contains("let a = 1\n\nlet b = 2"),
            "interior blank line inside a code block must survive, got: \(attributed.string.debugDescription)"
        )
    }

    // MARK: - Cache

    func test_sameSource_returnsCachedInstance() {
        let source = "A cached body with `code` and **bold**."
        let first = convert(source)
        let second = convert(source)
        XCTAssertTrue(first === second, "same source should hit the NSCache")
    }

    // MARK: - Size measurement

    /// `size(for:source:width:)` through the same conversion path the view uses.
    private func measure(_ source: String, width: CGFloat) -> CGSize {
        MarkdownAttributed.size(for: convert(source), source: source, width: width)
    }

    func test_size_shortMessage_hugsContentWidth() {
        let size = measure("hi", width: 600)
        XCTAssertLessThan(size.width, 60, "a two-character message must not claim the pane width")
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func test_size_longMessage_wrapsAtProposalWidth() {
        let paragraph = Array(repeating: "wrap me across many lines", count: 20).joined(separator: " ")
        let size = measure(paragraph, width: 300)
        XCTAssertLessThanOrEqual(size.width, 300)
        XCTAssertGreaterThan(size.width, 250, "a wrapping paragraph should use (nearly) the full proposal")
        let narrower = measure(paragraph, width: 200)
        XCTAssertGreaterThan(narrower.height, size.height, "less width must mean more height")
    }

    func test_size_isDeterministic_acrossRepeatedCalls() {
        // The memo must not change the answer: heights that move for a fixed
        // input are the timeline's historical failure mode (blank-chat saga).
        let source = "Some **body** with `code`\n\nand a second paragraph."
        XCTAssertEqual(measure(source, width: 420), measure(source, width: 420))
    }

    func test_size_cacheKeyedOnSource_notRenderedText() {
        // `**hi**` and `hi` render the same plain characters with different
        // fonts — a rendered-text cache key would let one reuse the other's
        // size (bugbot, PR #37). Bold must measure wider than regular.
        let bold = measure("**hi**", width: 600)
        let plain = measure("hi", width: 600)
        XCTAssertGreaterThan(bold.width, plain.width)
    }
}
#endif
