#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

/// Perf follow-ups S4/S5: the stable paragraph prefix a streaming delta
/// leaves alone, shared by the message body's storage edit and the
/// streaming row's measuring TextKit stack.
final class StreamingTextEditTests: XCTestCase {
    private func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 13)])
    }

    private func rendered(_ source: String) -> NSAttributedString {
        MarkdownAttributed.rendered(for: source, style: .chat, cache: false).attributed
    }

    /// What a full replace leaves in a storage: NOT `new` itself, because a
    /// text storage fixes attributes as it processes an edit (the render's
    /// attribute-less paragraph separators gain a font and their
    /// paragraph's style). The edit must match this, character and
    /// attribute for attribute.
    private func fullyReplaced(_ new: NSAttributedString) -> NSTextStorage {
        NSTextStorage(attributedString: new)
    }

    func test_appendWithinTheLastParagraphKeepsEveryEarlierParagraph() {
        let old = plain("one\ntwo\nthr")
        let new = plain("one\ntwo\nthree")
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: old, new: new), 8)
    }

    func test_identicalStringsKeepAllButTheLastParagraph() {
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: plain("a\nb\nc"), new: plain("a\nb\nc")), 4)
    }

    func test_aChangeInTheFirstParagraphReusesNothing() {
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: plain("abc\ndef"), new: plain("abX\ndef")), 0)
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: plain(""), new: plain("abc")), 0)
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: plain("abc"), new: plain("")), 0)
    }

    /// Ending a paragraph appends its terminator INSIDE it: that paragraph
    /// is re-laid out, the ones before it are not.
    func test_endingTheLastParagraphRestartsAtItsStart() {
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: plain("a\nb"), new: plain("a\nb\nc")), 2)
    }

    func test_anEarlierAttributeChangeMovesThePrefixBackToItsParagraph() {
        let old = plain("one\ntwo\nthree\nfour")
        let new = NSMutableAttributedString(attributedString: plain("one\ntwo\nthree\nfourth"))
        new.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 5, length: 1))
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: old, new: new), 4)
    }

    /// Equal attributes split into differently placed runs are not a
    /// difference.
    func test_differentRunBoundariesWithEqualAttributesAreNotADifference() {
        let old = NSMutableAttributedString(string: "one two\nthree\nfo")
        old.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: 16))
        let new = NSMutableAttributedString(string: "one two\nthree\nfour")
        new.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: 4))
        new.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 4, length: 14))
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: old, new: new), 14)
    }

    /// A difference inside a surrogate pair still lands on a paragraph start.
    func test_aDifferenceInsideASurrogatePairStaysOnAParagraphStart() {
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: plain("p\nx😀"), new: plain("p\nx😃")), 2)
    }

    func test_commonPrefixSpansChunks() {
        let long = String(repeating: "a", count: 3000)
        XCTAssertEqual(StreamingTextEdit.commonPrefixLength(long + "b" as NSString, long + "c" as NSString), 3000)
        XCTAssertEqual(StreamingTextEdit.commonPrefixLength(long as NSString, long + "c" as NSString), 3000)
    }

    /// A setext underline restyles the paragraph above it: the prefix moves
    /// back to that paragraph, and the storage ends as a full replace leaves it.
    func test_setextHeadingMovesThePrefixBackToTheRestyledParagraph() {
        let old = rendered("Intro text.\n\nTitle")
        let new = rendered("Intro text.\n\nTitle\n---")
        let titleStart = (new.string as NSString).range(of: "Title").location
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: old, new: new), titleStart)
        let storage = NSTextStorage(attributedString: old)
        XCTAssertEqual(StreamingTextEdit.apply(from: old, to: new, in: storage), titleStart)
        XCTAssertTrue(storage.isEqual(to: fullyReplaced(new)))
    }

    /// The real markdown case the attribute walk exists for: every build
    /// makes new `NSTextBlock`s, which compare by identity, so a growing
    /// table differs from its first cell on — though its characters agree
    /// further on — and the prefix stops before the table.
    func test_aGrowingTableMovesThePrefixBackToItsFirstCell() {
        let old = rendered("Intro.\n\n| A | B |\n|---|---|\n| 1")
        let new = rendered("Intro.\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        let tableStart = (new.string as NSString).range(of: "A").location
        let common = StreamingTextEdit.commonPrefixLength(old.string as NSString, new.string as NSString)
        XCTAssertGreaterThan(common, tableStart + 2, "characters agree past the header row")
        XCTAssertEqual(StreamingTextEdit.stablePrefix(old: old, new: new), tableStart)
        let storage = NSTextStorage(attributedString: old)
        StreamingTextEdit.apply(from: old, to: new, in: storage)
        XCTAssertTrue(storage.isEqual(to: fullyReplaced(new)))
    }

    func test_applyWithNothingReusableReplacesTheWholeString() {
        let old = plain("abc")
        let new = plain("xyz\nmore")
        let storage = NSTextStorage(attributedString: old)
        XCTAssertEqual(StreamingTextEdit.apply(from: old, to: new, in: storage), 0)
        XCTAssertTrue(storage.isEqual(to: fullyReplaced(new)))
    }

    /// Every prefix step of a mixed reply: the storage always ends as a full
    /// replace leaves it, and most steps reuse a prefix.
    func test_applyOverEveryPrefixStepEqualsTheNewRender() {
        let source = "# Plan\n\nSome **bold** and a [link](https://example.com).\n\n- one\n- two\n\n- loose\n\n```swift\nlet x = 1\n```\n\nDone."
        var old = rendered("")
        let storage = NSTextStorage(attributedString: old)
        var reused = 0
        for end in stride(from: 1, through: source.count, by: 3) {
            let new = rendered(String(source.prefix(end)))
            if StreamingTextEdit.apply(from: old, to: new, in: storage) > 0 { reused += 1 }
            XCTAssertTrue(storage.isEqual(to: fullyReplaced(new)), "prefix \(end)")
            old = new
        }
        XCTAssertGreaterThan(reused, 10)
    }
}
#endif
