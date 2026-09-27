import XCTest
import UIKit
import MatronDesignSystem

/// Spec §4 renderer tests: the UIKit build of the shared `MarkdownAttributed`
/// renders the same structure the Mac does (headings, lists, quotes, code,
/// tables, the `[label]:` escape) with UIKit fonts/colours, and routes links
/// through the shared `MatronItemLink` policy.
final class MarkdownAttributedPhoneTests: XCTestCase {
    private let style = MarkdownAttributed.Style.phoneChat(bodySize: 17)

    private func render(_ source: String) -> NSAttributedString {
        MarkdownAttributed.rendered(for: source, style: style, cache: false).attributed
    }

    private func attributes(_ string: NSAttributedString, at substring: String,
                            file: StaticString = #filePath, line: UInt = #line) -> [NSAttributedString.Key: Any] {
        let range = (string.string as NSString).range(of: substring)
        guard range.location != NSNotFound else {
            XCTFail("\(substring.debugDescription) not in \(string.string.debugDescription)", file: file, line: line)
            return [:]
        }
        return string.attributes(at: range.location, effectiveRange: nil)
    }

    func test_body_usesThePhoneMetrics() {
        let attrs = attributes(render("Hello world.\n\nSecond."), at: "Hello")
        XCTAssertEqual((attrs[.font] as? UIFont)?.pointSize, 17)
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineSpacing, 4)
        XCTAssertEqual(paragraph?.paragraphSpacing, 8)
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, UIColor.label)
    }

    func test_inlineStyles_mapToUIKitTraits() {
        let string = render("A **bold** and *italic* and ~~gone~~ and `code`.")
        let bold = attributes(string, at: "bold")[.font] as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let italic = attributes(string, at: "italic")[.font] as? UIFont
        XCTAssertTrue(italic?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        XCTAssertNotNil(attributes(string, at: "gone")[.strikethroughStyle])
        let code = attributes(string, at: "code")
        XCTAssertTrue((code[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
        XCTAssertEqual(code[.backgroundColor] as? UIColor, UIColor.systemGray6)
    }

    func test_headings_scaleAndBold() {
        let string = render("# Big\n\nBody")
        let font = attributes(string, at: "Big")[.font] as? UIFont
        XCTAssertEqual(font?.pointSize ?? 0, 17 * 1.3, accuracy: 0.01)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    func test_lists_getTheSameMarkersAsTheMac() {
        let string = render("- alpha\n- beta\n\n1. first\n2. second").string
        XCTAssertTrue(string.contains("\u{2022} alpha"))
        XCTAssertTrue(string.contains("1. first"))
        XCTAssertTrue(string.contains("2. second"))
    }

    func test_quote_isSecondaryAndIndented() {
        let attrs = attributes(render("> quoted\n\nafter"), at: "quoted")
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, UIColor.secondaryLabel)
        XCTAssertEqual((attrs[.paragraphStyle] as? NSParagraphStyle)?.headIndent, 12)
    }

    func test_links_followTheSharedPolicy() {
        let string = render("[web](https://example.com) [#5](matron://item/5) [room](matron://convo/c-1) [mx](matrix:r/x:s)")
        XCTAssertEqual(attributes(string, at: "web")[.link] as? URL, URL(string: "https://example.com"))
        XCTAssertEqual(attributes(string, at: "#5")[.link] as? URL, URL(string: "matron://item/5"))
        XCTAssertEqual(attributes(string, at: "room")[.link] as? URL, URL(string: "matron://convo/c-1"))
        let swallowed = attributes(string, at: "mx")
        XCTAssertNil(swallowed[.link], "matrix: links are swallowed, never clickable")
        XCTAssertEqual(swallowed[.foregroundColor] as? UIColor, UIColor.tintColor)
    }

    func test_referenceDefinitionShapedBody_rendersAsText() {
        let string = render("[Voice note transcription]: Hello.").string
        XCTAssertTrue(string.contains("Hello."))
        XCTAssertTrue(string.contains("[Voice note transcription]:"))
    }

    func test_tableCells_renderAsAlignedParagraphs() {
        let string = render("| L | R |\n|:--|--:|\n| a | b |")
        XCTAssertEqual((attributes(string, at: "b")[.paragraphStyle] as? NSParagraphStyle)?.alignment, .right)
        XCTAssertEqual((attributes(string, at: "a")[.paragraphStyle] as? NSParagraphStyle)?.alignment, .left)
    }

    func test_output_neverEndsWithNewline() {
        for source in ["para\n\n```swift\nlet x = 1\n```", "para\n\n- a\n- b", "Closing.\n\n\n"] {
            XCTAssertFalse(render(source).string.hasSuffix("\n"), source.debugDescription)
        }
    }

    func test_cacheFlag_controlsMemoisation() {
        let source = "memo probe \(UUID().uuidString)"
        let a = MarkdownAttributed.rendered(for: source, style: style, cache: false)
        let b = MarkdownAttributed.rendered(for: source, style: style, cache: false)
        XCTAssertFalse(a === b, "cache: false (streaming rows) must not store")
        let c = MarkdownAttributed.rendered(for: source, style: style, cache: true)
        let d = MarkdownAttributed.rendered(for: source, style: style, cache: true)
        XCTAssertTrue(c === d)
    }
}
