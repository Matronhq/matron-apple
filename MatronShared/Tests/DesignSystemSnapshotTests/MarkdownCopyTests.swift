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
}
#endif
