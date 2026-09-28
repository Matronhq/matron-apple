#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

@MainActor final class MessageBodyViewTests: XCTestCase {
    func test_codeButtonsSitAtCodeBlockFrames() {
        let source = "Before\n\n```\nmake test\n```\n\nAfter"
        let rendered = MarkdownAttributed.rendered(for: source, style: .chat)
        let view = MessageBodyView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: rendered.size(width: 400).height)
        view.configure(source: source, rendered: rendered, itemID: "m1", selectionController: nil)
        view.layoutSubtreeIfNeeded()
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        let frames = rendered.codeBlockFrames(width: 400)
        XCTAssertEqual(buttons.count, frames.count)
        // Same centre rule as the SwiftUI overlay: x = min(maxX + 12, width - 12), y = minY + 12.
        XCTAssertEqual(buttons[0].frame.midX, min(frames[0].rect.maxX + 12, 400 - 12), accuracy: 0.5)
        XCTAssertEqual(buttons[0].frame.midY, frames[0].rect.minY + 12, accuracy: 0.5)
    }

    func test_reconfigureWithSameRenderedDoesNotRewriteStorage() {
        let rendered = MarkdownAttributed.rendered(for: "Hi", style: .chat)
        let view = MessageBodyView()
        view.configure(source: "Hi", rendered: rendered, itemID: "m1", selectionController: nil)
        let storage = view.textView.textStorage
        view.textView.setSelectedRange(NSRange(location: 0, length: 1))
        view.configure(source: "Hi", rendered: rendered, itemID: "m1", selectionController: nil)
        XCTAssertTrue(view.textView.textStorage === storage)
        XCTAssertEqual(view.textView.selectedRange().length, 1)
    }

    func test_prepareForReuseClearsSelectionAndId() {
        let rendered = MarkdownAttributed.rendered(for: "Hello there", style: .chat)
        let view = MessageBodyView()
        view.configure(source: "Hello there", rendered: rendered, itemID: "m1", selectionController: nil)
        view.textView.setSelectedRange(NSRange(location: 0, length: 5))
        view.prepareForReuse()
        XCTAssertEqual(view.textView.selectedRange().length, 0)
        XCTAssertNil(view.itemID)
    }

    /// Final review minor 2: a recycled body registers with the selection
    /// AFTER its storage is replaced, so a mid-selection span is sized to
    /// the NEW message, not the one the view showed before.
    func test_recycledBodyTakesTheSpanOfItsNewLength() throws {
        final class Edge: CrossSelectionTarget {
            let selectionItemID: String?
            let frameInWindow: NSRect
            init(_ id: String, y: CGFloat) { selectionItemID = id; frameInWindow = NSRect(x: 0, y: y, width: 100, height: 20) }
            var storageLength: Int { 4 }
            func characterIndex(atWindowPoint point: NSPoint) -> Int { 2 }
            func setCrossSelection(_ range: NSRange?) {}
            func crossSelectionMarkdown() -> String { "" }
        }
        let selection = MessageSelectionController()
        selection.orderedIDs = ["a", "m1", "m2", "z"]
        // `m2` is unmounted when the selection is made: the provider sizes it.
        selection.contentProvider = { id in id == "m2" ? (NSAttributedString(string: "x"), "x") : nil }
        let a = Edge("a", y: 200), z = Edge("z", y: 0)
        selection.register(a); selection.register(z)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = MessageBodyView()
        view.frame = NSRect(x: 0, y: 100, width: 400, height: 40)
        window.contentView?.addSubview(view)
        let short = MarkdownAttributed.rendered(for: "short", style: .chat)
        view.configure(source: "short", rendered: short, itemID: "m1", selectionController: selection)

        XCTAssertTrue(selection.beginCrossMessage(anchorID: "a", charIndex: 2))
        selection.hitTester = { _, _ in z }
        selection.extend(toWindowPoint: .zero, window: nil)      // a → z: m2 fully selected, unmounted

        let longSource = "A much longer message body that the recycled view now shows instead"
        let long = MarkdownAttributed.rendered(for: longSource, style: .chat)
        view.configure(source: longSource, rendered: long, itemID: "m2", selectionController: selection)
        let textView = try XCTUnwrap(view.textView as? MessageCopyTextView)
        XCTAssertEqual(textView.crossSelectionRange, NSRange(location: 0, length: long.attributed.length))
        XCTAssertNotEqual(long.attributed.length, short.attributed.length)
    }
}
#endif
