import SwiftUI
import XCTest
@testable import MatronDesignSystem

#if os(macOS)
/// Pointer → character index for the cross-message drag, measured on a real
/// hosted `MessageCopyTextView` (TextKit 2).
@MainActor
final class MessageCopyTextViewPointerTests: XCTestCase {
    private func hostedTextView() -> (MessageCopyTextView, NSWindow)? {
        let controller = MessageSelectionController()
        let text = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."
        let host = NSHostingView(rootView:
            SelectableMessageText(text, itemID: "a").environment(controller)
                .frame(width: 300, alignment: .topLeading).padding(20).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func find(_ v: NSView) -> MessageCopyTextView? {
            if let t = v as? MessageCopyTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return find(host).map { ($0, window) }
    }

    /// A pointer in the gap ABOVE a message resolves to its start, not its
    /// end. TextKit 2 answers "end" for both overshoots; the head of a drag
    /// is resolved by nearest row while the pointer is still in that gap.
    func test_pointAboveTheTextResolvesToStart_belowToEnd() {
        guard let (tv, _) = hostedTextView() else { return XCTFail("no text view") }
        let frame = tv.frameInWindow
        XCTAssertGreaterThan(frame.height, 40, "expected a multi-line message")
        let x = frame.minX + 40
        XCTAssertEqual(tv.characterIndex(atWindowPoint: NSPoint(x: x, y: frame.maxY + 6)), 0)
        let firstLine = tv.characterIndex(atWindowPoint: NSPoint(x: x, y: frame.maxY - 6))
        XCTAssertGreaterThan(firstLine, 0)
        XCTAssertLessThan(firstLine, 20)
        let lastLine = tv.characterIndex(atWindowPoint: NSPoint(x: x, y: frame.minY + 6))
        XCTAssertGreaterThan(lastLine, firstLine + 40)
        XCTAssertEqual(tv.characterIndex(atWindowPoint: NSPoint(x: x, y: frame.minY - 6)), tv.storageLength)
    }

    /// The within-message drag uses the same clamped lookup: a pointer a few
    /// points above the first line (inside the escalation slop) is the start.
    func test_viewPointAboveTheTextResolvesToStart() {
        guard let (tv, _) = hostedTextView() else { return XCTFail("no text view") }
        XCTAssertEqual(tv.characterIndex(atViewPoint: NSPoint(x: 40, y: -3)), 0)
        XCTAssertLessThan(tv.characterIndex(atViewPoint: NSPoint(x: 40, y: 3)), 20)
        XCTAssertEqual(tv.characterIndex(atViewPoint: NSPoint(x: 40, y: tv.bounds.maxY + 3)), tv.storageLength)
    }

    /// A highlight change marks every descendant view dirty (the TextKit 2
    /// text is drawn two levels down), not just the text view's own layer.
    func test_highlightChangeDirtiesEveryDescendantView() {
        guard let (tv, window) = hostedTextView() else { return XCTFail("no text view") }
        window.displayIfNeeded()
        XCTAssertFalse(tv.subviews.isEmpty)
        tv.setCrossSelection(NSRange(location: 4, length: 20))
        var notDirty: [String] = []
        func walk(_ v: NSView) {
            if !(v.layer?.needsDisplay() ?? true) { notDirty.append(String(describing: type(of: v))) }
            for s in v.subviews { walk(s) }
        }
        walk(tv)
        XCTAssertTrue(notDirty.isEmpty, "descendants not dirty: \(notDirty)")
    }
}
#endif
