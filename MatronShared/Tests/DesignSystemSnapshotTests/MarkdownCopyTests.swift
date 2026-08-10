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

    func test_reconstruct_codeBlockFencesAndNewlines() {
        XCTAssertEqual(
            reconstruct("```swift\nlet a = 1\nlet b = 2\n```"),
            "```swift\nlet a = 1\nlet b = 2\n```"
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
