#if os(macOS)
import AppKit
import XCTest
@testable import MatronDesignSystem

/// Pointer → character mapping under a drag (tracker #2533 follow-up:
/// "the selection jumps back and forth a little"). TextKit 2 maps a point
/// in the paragraph-spacing gap below a paragraph to that paragraph's
/// START (the first gap in a message maps to 0), so a drag moving down
/// through a gap snapped the selection back a whole paragraph and then
/// forward again. The item style's 14 pt gap made it easy to hit; the
/// chat style's 8 pt gap has the same fault.
@MainActor
final class MessageCopyTextViewHitTests: XCTestCase {
    private static let markdown = """
        First paragraph with enough words that it wraps over a couple of lines at this width for sure.

        Second paragraph also long enough to wrap onto a second line in the probe.

        - a list item
        - another list item
        """

    private var window: NSWindow?

    override func tearDown() {
        window?.contentView = nil
        window = nil
        super.tearDown()
    }

    private func makeTextView(style: MarkdownAttributed.Style) -> MessageCopyTextView {
        let textView = MessageCopyTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(MarkdownAttributed.attributedString(for: Self.markdown, style: style))
        let window = NSWindow(contentRect: textView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = textView
        self.window = window
        return textView
    }

    /// Moving the pointer steadily down the text must never move the
    /// insertion index backwards: every backward step is a visible jump of
    /// the selection's moving end.
    private func assertMonotonicDownTheView(style: MarkdownAttributed.Style, file: StaticString = #filePath, line: UInt = #line) {
        let textView = makeTextView(style: style)
        for x in [CGFloat(20), 150, 290] {
            var previous = 0
            var y: CGFloat = 0
            while y < 200 {
                let index = textView.characterIndex(atViewPoint: NSPoint(x: x, y: y))
                XCTAssertGreaterThanOrEqual(index, previous, "x=\(x) y=\(y): index went back from \(previous) to \(index)",
                                            file: file, line: line)
                previous = max(previous, index)
                y += 0.5
            }
        }
    }

    func test_characterIndex_neverGoesBackwardsDownAnItemCard() {
        assertMonotonicDownTheView(style: .item)
    }

    func test_characterIndex_neverGoesBackwardsDownAChatBubble() {
        assertMonotonicDownTheView(style: .chat)
    }

    /// A point in the gap below a paragraph lands at the end of that
    /// paragraph's last line (at the pointer's x), not its start.
    func test_characterIndex_inAParagraphGap_mapsToTheParagraphAbove() throws {
        let textView = makeTextView(style: .item)
        let firstBreak = (textView.string as NSString).range(of: "\n").location
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let fragment = try XCTUnwrap(layoutManager.textLayoutFragment(for: NSPoint(x: 10, y: 1)))
        let lastLine = try XCTUnwrap(fragment.textLineFragments.last)
        let textBottom = fragment.layoutFragmentFrame.minY + lastLine.typographicBounds.maxY
        let inGap = NSPoint(x: 290, y: textBottom + 3)
        XCTAssertEqual(textView.characterIndex(atViewPoint: inGap), firstBreak,
                       "a point right of the first paragraph's last line, in the gap, is the paragraph's end")
    }
}
#endif
