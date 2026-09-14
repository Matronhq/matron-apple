#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// Item #102: ⌘Z crashed the app after a conversation switch. The composer
/// text view is rebuilt per conversation (`MacChatView` is `.id`-keyed),
/// and with `allowsUndo` but no undo manager of its own every edit
/// registered on the WINDOW's shared undo stack with the text view as the
/// target. The next ⌘Z after the switch invoked an entry whose target had
/// been freed (crash report 2026-09-10 12:44:37, `_NSUndoStack popAndInvoke`
/// → `objc_msgSend` pointer-auth failure). The composer must own its undo
/// stack so it dies with the view.
@MainActor
final class MacComposerUndoTests: XCTestCase {
    private func makeWindowWithComposer() -> (NSWindow, ComposerTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.allowsUndo = true
        textView.isRichText = false
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        return (window, textView)
    }

    func testTypingRegistersUndoOnTheComposerNotTheWindow() {
        let (window, textView) = makeWindowWithComposer()
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.string, "hello")
        XCTAssertTrue(textView.undoManager?.canUndo == true, "the composer's own undo stack should hold the edit")
        XCTAssertFalse(window.undoManager?.canUndo == true, "the window's shared undo stack must never hold composer edits")
        XCTAssertFalse(textView.undoManager === window.undoManager, "the composer must not share the window's undo manager")
    }

    func testUndoAfterTheComposerIsGoneIsANoOp() {
        let (window, textView) = makeWindowWithComposer()
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        window.makeFirstResponder(nil)
        textView.removeFromSuperview()
        // The window's undo manager is what ⌘Z reaches once the composer is
        // gone; it must have nothing to pop.
        XCTAssertFalse(window.undoManager?.canUndo == true)
        window.undoManager?.undo()   // must not crash
    }

    func testUndoInsideTheComposerStillWorks() {
        let (_, textView) = makeWindowWithComposer()
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "")
    }
}
#endif
