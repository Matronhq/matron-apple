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
}
#endif
