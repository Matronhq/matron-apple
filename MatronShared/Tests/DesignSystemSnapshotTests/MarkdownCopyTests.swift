#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

/// Tests for the copy-time markdown pipeline: run annotation
/// (`MarkdownRunSemantics`), reconstruction (`MarkdownReconstruction`), and
/// the pasteboard override (`MessageCopyTextView`).
final class MarkdownCopyTests: XCTestCase {

    private func convert(_ source: String) -> NSAttributedString {
        MarkdownAttributed.attributedString(for: source)
    }

    private func semantics(
        of attributed: NSAttributedString,
        atFirst substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MarkdownRunSemantics? {
        let range = (attributed.string as NSString).range(of: substring)
        guard range.location != NSNotFound else {
            XCTFail("substring \(substring.debugDescription) not found in \(attributed.string.debugDescription)", file: file, line: line)
            return nil
        }
        return attributed.attribute(
            MarkdownAttributed.semanticsKey, at: range.location, effectiveRange: nil
        ) as? MarkdownRunSemantics
    }

    // MARK: - Annotation

    func test_annotation_paragraphAndBoldFlags() {
        let attributed = convert("plain **bold** text")
        let plain = semantics(of: attributed, atFirst: "plain")
        let bold = semantics(of: attributed, atFirst: "bold")
        XCTAssertEqual(plain?.block, .paragraph)
        XCTAssertEqual(plain?.inline, [])
        XCTAssertEqual(bold?.inline, .bold)
        XCTAssertEqual(plain?.blockIdentity, bold?.blockIdentity)
    }

    func test_annotation_blockIdentityIncrementsPerBlock() {
        let attributed = convert("First.\n\nSecond.")
        let first = semantics(of: attributed, atFirst: "First")
        let second = semantics(of: attributed, atFirst: "Second")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.blockIdentity, second?.blockIdentity)
    }

    func test_annotation_codeBlockCarriesLanguage() {
        let attributed = convert("```swift\nlet x = 1\n```")
        let code = semantics(of: attributed, atFirst: "let x")
        XCTAssertEqual(code?.block, .codeBlock(language: "swift"))
    }

    func test_annotation_linkCarriesURL() {
        let attributed = convert("see [docs](https://example.com)")
        let link = semantics(of: attributed, atFirst: "docs")
        XCTAssertEqual(link?.link, URL(string: "https://example.com"))
    }

    func test_annotation_everyCharacterAnnotated() {
        let attributed = convert("# H\n\npara `code`\n\n- item\n\n> quote")
        var uncovered = 0
        attributed.enumerateAttribute(
            MarkdownAttributed.semanticsKey,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if value == nil { uncovered += 1 }
        }
        XCTAssertEqual(uncovered, 0)
    }

    /// `updateNSView` short-circuits on `isEqual(to:)`; semantics must
    /// compare by VALUE — the conversion cache can be evicted between a
    /// build and a streaming re-emit, yielding fresh objects for identical
    /// content. (Comparing two `convert` results would pass trivially via
    /// the cache's pointer equality, so construct directly.)
    func test_semantics_valueEqualityAndHash() {
        let a = MarkdownRunSemantics(
            block: .listItem(ordinal: 2), blockIdentity: 3,
            inline: [.bold], link: URL(string: "https://e.com")
        )
        let b = MarkdownRunSemantics(
            block: .listItem(ordinal: 2), blockIdentity: 3,
            inline: [.bold], link: URL(string: "https://e.com")
        )
        let c = MarkdownRunSemantics(
            block: .paragraph, blockIdentity: 3, inline: [.bold], link: nil
        )
        XCTAssertTrue(a.isEqual(b))
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertFalse(a.isEqual(c))
        XCTAssertFalse(a.isEqual("not semantics"))
    }

    // MARK: - Reconstruction

    private func reconstruct(_ source: String) -> String {
        let attributed = convert(source)
        return MarkdownReconstruction.markdown(
            from: attributed, in: NSRange(location: 0, length: attributed.length)
        )
    }

    func test_reconstruct_paragraphsSeparatedByBlankLine() {
        XCTAssertEqual(reconstruct("First one.\n\nSecond one."), "First one.\n\nSecond one.")
    }

    func test_reconstruct_inlineStyles() {
        XCTAssertEqual(
            reconstruct("a **bold** b *ital* c `code` d ~~gone~~"),
            "a **bold** b *ital* c `code` d ~~gone~~"
        )
    }

    func test_reconstruct_nestedBoldItalic_noBrokenDelimiters() {
        let out = reconstruct("**bold *both* bold**")
        XCTAssertFalse(out.contains("****"))
        XCTAssertEqual(out, "**bold *both* bold**")
    }

    /// A selection that is nothing but one code block copies the bare code —
    /// the fences are block chrome, not content, and the paste target is
    /// almost always a terminal or editor (Dan, 2026-08-26).
    func test_reconstruct_soleCodeBlock_bareText() {
        XCTAssertEqual(
            reconstruct("```swift\nlet a = 1\nlet b = 2\n```"),
            "let a = 1\nlet b = 2"
        )
    }

    func test_reconstruct_partialSelectionInsideCodeBlock_bareText() {
        let attributed = convert("Before.\n\n```bash\ncd /var/www\nls -la\n```\n\nAfter.")
        let start = (attributed.string as NSString).range(of: "cd /var/www").location
        let end = (attributed.string as NSString).range(of: "ls -la")
        let range = NSRange(location: start, length: end.location + end.length - start)
        XCTAssertEqual(
            MarkdownReconstruction.markdown(from: attributed, in: range),
            "cd /var/www\nls -la"
        )
    }

    /// Selecting a code block INCLUDING its trailing newline (the natural
    /// result of a drag past the last line) still counts as code-only.
    func test_reconstruct_codeBlockWithTrailingNewline_bareText() {
        let attributed = convert("```bash\ncd /tmp\n```\n\nAfter.")
        let range = (attributed.string as NSString).range(of: "cd /tmp\n")
        XCTAssertEqual(
            MarkdownReconstruction.markdown(from: attributed, in: range),
            "cd /tmp"
        )
    }

    func test_reconstruct_codeBlockBetweenParagraphs() {
        XCTAssertEqual(
            reconstruct("Before.\n\n```\nx\n```\n\nAfter."),
            "Before.\n\n```\nx\n```\n\nAfter."
        )
    }

    func test_reconstruct_unorderedList() {
        XCTAssertEqual(
            reconstruct("- one\n- two\n\nAfter."),
            "- one\n- two\n\nAfter."
        )
    }

    func test_reconstruct_orderedList() {
        XCTAssertEqual(reconstruct("1. one\n2. two"), "1. one\n2. two")
    }

    func test_reconstruct_header() {
        XCTAssertEqual(reconstruct("## Title\n\nBody."), "## Title\n\nBody.")
    }

    func test_reconstruct_blockQuote() {
        XCTAssertEqual(reconstruct("> quoted line"), "> quoted line")
    }

    /// A block ENDING in styled text, followed by another block: the
    /// synthesized separator "\n" must not inherit the trailing run's inline
    /// flags, or the newline lands inside the delimiters (`**docs\n**`).
    /// (Code-review finding, PR #127.)
    func test_reconstruct_blockEndingInBold_beforeNextBlock() {
        XCTAssertEqual(
            reconstruct("Check the **docs**\n\nMore text."),
            "Check the **docs**\n\nMore text."
        )
    }

    /// Same shape for a trailing link: the separator must not coalesce into
    /// the link run and mint a bogus `[\n](url)` second link.
    func test_reconstruct_blockEndingInLink_beforeNextBlock() {
        XCTAssertEqual(
            reconstruct("See [docs](https://example.com)\n\nMore text."),
            "See [docs](https://example.com)\n\nMore text."
        )
    }

    func test_reconstruct_link() {
        XCTAssertEqual(
            reconstruct("see [docs](https://example.com) now"),
            "see [docs](https://example.com) now"
        )
    }

    func test_reconstruct_partialRangeMidParagraph_plainFragment() {
        let attributed = convert("hello plain world")
        let range = (attributed.string as NSString).range(of: "plain")
        XCTAssertEqual(
            MarkdownReconstruction.markdown(from: attributed, in: range),
            "plain"
        )
    }

    func test_reconstruct_partialRange_listItemWithoutMarker_noSynthesizedMarker() {
        let attributed = convert("- alpha bravo")
        let range = (attributed.string as NSString).range(of: "bravo")
        XCTAssertEqual(
            MarkdownReconstruction.markdown(from: attributed, in: range),
            "bravo"
        )
    }

    func test_reconstruct_unannotatedString_identity() {
        let plain = NSAttributedString(string: "raw\ntext, untouched")
        XCTAssertEqual(
            MarkdownReconstruction.markdown(
                from: plain, in: NSRange(location: 0, length: plain.length)
            ),
            "raw\ntext, untouched"
        )
    }

    /// Fixed-point: reconstructing the full range and re-rendering yields the
    /// same rendered string (byte-identity with the source is the fast path's
    /// job, not reconstruction's).
    func test_reconstruct_fullMessage_fixedPoint() {
        let source = "# H\n\npara **bold** and [l](https://e.com)\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n\n> bye"
        let rendered = convert(source)
        let rebuilt = MarkdownReconstruction.markdown(
            from: rendered, in: NSRange(location: 0, length: rendered.length)
        )
        XCTAssertEqual(convert(rebuilt).string, rendered.string)
    }

    // MARK: - Reconstruction: tables

    func test_reconstruct_fullTable_roundTripsPipesAndAlignment() {
        let source = """
        | Repo | PR |
        | :--- | ---: |
        | bridge | **215** |
        | apple | 133 |
        """
        let attributed = MarkdownAttributed.attributedString(for: source)
        let rebuilt = MarkdownReconstruction.markdown(
            from: attributed, in: NSRange(location: 0, length: attributed.length))
        XCTAssertEqual(rebuilt, """
        | Repo | PR |
        | --- | ---: |
        | bridge | **215** |
        | apple | 133 |
        """)
    }

    func test_reconstruct_tableBetweenParagraphs_blankLineSeparated() {
        let source = "Before.\n\n| A | B |\n| --- | --- |\n| c | d |\n\nAfter."
        let attributed = MarkdownAttributed.attributedString(for: source)
        let rebuilt = MarkdownReconstruction.markdown(
            from: attributed, in: NSRange(location: 0, length: attributed.length))
        XCTAssertEqual(rebuilt, "Before.\n\n| A | B |\n| --- | --- |\n| c | d |\n\nAfter.")
    }

    func test_reconstruct_partialTableSelection_bestEffortRows() {
        let source = "| A | B |\n| --- | --- |\n| cc | dd |\n| ee | ff |"
        let attributed = MarkdownAttributed.attributedString(for: source)
        // Select from "cc" to the end — body rows only, no header.
        let start = (attributed.string as NSString).range(of: "cc").location
        let rebuilt = MarkdownReconstruction.markdown(
            from: attributed, in: NSRange(location: start, length: attributed.length - start))
        XCTAssertEqual(rebuilt, "| cc | dd |\n| ee | ff |")
    }

    func test_reconstruct_adjacentTables_stayTwoTables() {
        // Back-to-back tables: the renderer starts a second `NSTextTable` when
        // cell coordinates step backward, so reconstruction must split there
        // too — otherwise the copy is one table with a delimiter row wedged
        // into the middle of its body.
        let source = "| A | B |\n| --- | --- |\n| c | d |\n\n| X | Y |\n| --- | --- |\n| p | q |"
        let attributed = MarkdownAttributed.attributedString(for: source)
        let rebuilt = MarkdownReconstruction.markdown(
            from: attributed, in: NSRange(location: 0, length: attributed.length))
        XCTAssertEqual(
            rebuilt,
            "| A | B |\n| --- | --- |\n| c | d |\n\n| X | Y |\n| --- | --- |\n| p | q |"
        )
    }

    func test_reconstruct_partialHeaderSelection_delimiterMatchesSelectedCells() {
        // Only part of the header row is selected: the delimiter row must carry
        // one entry per EMITTED header cell (and each one's own alignment), or
        // the header and delimiter rows disagree and the output is not a table.
        let source = "| A | B | C |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |"
        let attributed = MarkdownAttributed.attributedString(for: source)
        let start = (attributed.string as NSString).range(of: "B").location
        let rebuilt = MarkdownReconstruction.markdown(
            from: attributed, in: NSRange(location: start, length: attributed.length - start))
        XCTAssertEqual(rebuilt, "| B | C |\n| :---: | ---: |\n| 1 | 2 | 3 |")
    }

    // MARK: - Code-block frames

    func test_codeBlockFrames_noCode_empty() {
        let source = "just a paragraph with `inline code`"
        let frames = MarkdownAttributed.rendered(for: source).codeBlockFrames(width: 400)
        XCTAssertEqual(frames, [])
    }

    func test_codeBlockFrames_twoBlocks_bareCodeAndStackedRects() {
        let source = "Intro.\n\n```bash\ncd /tmp\nls\n```\n\nMiddle.\n\n```\necho hi\n```"
        let frames = MarkdownAttributed.rendered(for: source).codeBlockFrames(width: 400)
        XCTAssertEqual(frames.map(\.code), ["cd /tmp\nls", "echo hi"])
        XCTAssertEqual(frames.count, 2)
        // Rects are laid out (non-empty), within the wrap width, and in
        // document order top to bottom.
        for frame in frames {
            XCTAssertGreaterThan(frame.rect.height, 0)
            XCTAssertGreaterThan(frame.rect.width, 0)
            XCTAssertLessThanOrEqual(frame.rect.maxX, 400)
        }
        XCTAssertGreaterThan(frames[1].rect.minY, frames[0].rect.maxY - 1)
    }

    /// A code block that is NOT the message's last block keeps its
    /// terminator newline, and `boundingRect(forGlyphRange:)` pulls such a
    /// range's line fragments to the full container width — which floated
    /// the copy button hundreds of points right of a narrow block (PR #170
    /// review). Frames must hug the code's natural width instead.
    func test_codeBlockFrames_midMessageNarrowBlock_hugsCodeWidth() {
        let source = "A deliberately long intro paragraph that wraps and spans the full bubble width easily.\n\n```bash\nls\n```\n\nAfter."
        let frames = MarkdownAttributed.rendered(for: source).codeBlockFrames(width: 500)
        XCTAssertEqual(frames.map(\.code), ["ls"])
        XCTAssertLessThan(frames[0].rect.width, 60)
    }

    func test_codeBlockFrames_multiLineBlock_hugsLongestLine() {
        let source = "```bash\ncd /tmp\nls\n```\n\nAfter."
        let frames = MarkdownAttributed.rendered(for: source).codeBlockFrames(width: 500)
        XCTAssertEqual(frames.map(\.code), ["cd /tmp\nls"])
        XCTAssertLessThan(frames[0].rect.width, 100)
        XCTAssertGreaterThan(frames[0].rect.height, 20)
    }

    /// A newline-only selection inside a code block (drag across a blank
    /// line) must copy the newlines — returning "" would flow into
    /// `setString("", …)` and wipe the clipboard's plain-text flavor.
    func test_reconstruct_newlineOnlySelectionInCodeBlock_copiesNewlines() {
        let attributed = convert("```\nfoo\n\n\nbar\n```")
        let start = (attributed.string as NSString).range(of: "foo")
        let end = (attributed.string as NSString).range(of: "bar")
        let range = NSRange(
            location: start.location + start.length,
            length: end.location - (start.location + start.length)
        )
        XCTAssertGreaterThan(range.length, 0)
        XCTAssertEqual(
            MarkdownReconstruction.markdown(from: attributed, in: range),
            (attributed.string as NSString).substring(with: range)
        )
    }

    func test_copy_newlineOnlySelectionInCodeBlock_pasteboardNotEmptied() {
        let view = makeCopyView("```\nfoo\n\n\nbar\n```")
        let full = view.textStorage!.string as NSString
        let start = full.range(of: "foo")
        let end = full.range(of: "bar")
        view.setSelectedRange(NSRange(
            location: start.location + start.length,
            length: end.location - (start.location + start.length)
        ))

        view.copy(nil)

        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertNotNil(pasted)
        XCTAssertFalse(pasted!.isEmpty)
    }

    // MARK: - Copy override

    private func makeCopyView(_ source: String) -> MessageCopyTextView {
        let view = MessageCopyTextView()
        view.markdownSource = source
        view.textStorage?.setAttributedString(MarkdownAttributed.attributedString(for: source))
        return view
    }

    func test_copy_fullSelection_copiesRawSourceVerbatim() {
        let source = "First **bold**.\n\nSecond with [l](https://e.com)."
        let view = makeCopyView(source)
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage!.length))

        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), source)
        XCTAssertNotNil(NSPasteboard.general.data(forType: .rtf))
    }

    func test_copy_partialSelection_reconstructsMarkdown() {
        let view = makeCopyView("plain **bold** tail")
        let full = view.textStorage!.string as NSString
        // Select from "bold" through "tail" — excludes the plain prefix.
        let start = full.range(of: "bold").location
        view.setSelectedRange(NSRange(location: start, length: full.length - start))

        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "**bold** tail")
    }

    /// The full-selection raw-source fast path must NOT win when the whole
    /// message is one code block — the user sees only code, so ⌘A⌘C should
    /// paste runnable code, not refenced markdown.
    func test_copy_fullSelection_codeBlockOnlyMessage_copiesBareCode() {
        let view = makeCopyView("```bash\ncd /var/www/yearbook.com/current\n```")
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage!.length))

        view.copy(nil)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "cd /var/www/yearbook.com/current"
        )
    }

    func test_copy_selectionSpanningTextAndCode_keepsFences() {
        let view = makeCopyView("Run this:\n\n```bash\nls\n```")
        let full = view.textStorage!.string as NSString
        let start = full.range(of: "Run").location
        view.setSelectedRange(NSRange(location: start, length: full.length - start))

        view.copy(nil)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "Run this:\n\n```bash\nls\n```"
        )
    }

    func test_copy_emptySelection_doesNotClearPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        let view = makeCopyView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 0))

        view.copy(nil)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "sentinel")
    }
}
#endif
