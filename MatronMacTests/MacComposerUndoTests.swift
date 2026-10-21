#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import MatronMac

/// ⌘Z crashed the app after a conversation switch. The composer
/// text view is rebuilt per conversation (`MacChatView` is `.id`-keyed),
/// and with `allowsUndo` but no undo manager of its own every edit
/// registered on the WINDOW's shared undo stack with the text view as the
/// target. The next ⌘Z after the switch invoked an entry whose target had
/// been freed (crash report 2026-09-10 12:44:37, `_NSUndoStack popAndInvoke`
/// → `objc_msgSend` pointer-auth failure). The composer must own its undo
/// stack so it dies with the view.
///
/// Owning the stack then left ⌘Z dead while typing: `NSWindow` answers
/// `undo:` with the window's own (empty) stack, so the composer handles
/// Undo/Redo itself, and drops its stack whenever the draft is replaced
/// from outside (sending, recall), so ⌘Z can't bring a sent message back.
@MainActor @Observable
private final class UndoTestTextBox {
    var text = ""
}

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


    // MARK: - Edit ▸ Undo / ⌘Z reach the composer's stack

    // ⌘Z and Edit ▸ Undo send `undo:` up the responder chain, and `NSWindow`
    // answers it with the window's own undo manager. With the composer
    // owning its stack that was always empty, so ⌘Z did nothing while typing.

    private static let undoAction = Selector(("undo:"))
    private static let redoAction = Selector(("redo:"))

    /// Runs `edit` as its own undo group, as a separate key press or menu
    /// command would be. In the app the undo manager closes a group per
    /// event; a test has no events, so everything would land in one group.
    private static func asOwnEvent(_ textView: NSTextView, _ edit: () -> Void) {
        let undo = textView.undoManager!
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        edit()
        textView.breakUndoCoalescing()
        undo.endUndoGrouping()
    }

    func testUndoActionUndoesTypingAndRedoActionRedoesIt() {
        let (_, textView) = makeWindowWithComposer()
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.tryToPerform(Self.undoAction, with: nil))
        XCTAssertEqual(textView.string, "")
        XCTAssertTrue(textView.tryToPerform(Self.redoAction, with: nil))
        XCTAssertEqual(textView.string, "hello")
    }

    func testUndoActionUndoesAPaste() {
        let (_, textView) = makeWindowWithComposer()
        Self.asOwnEvent(textView) {
            textView.insertText("hi ", replacementRange: NSRange(location: 0, length: 0))
        }
        // A private pasteboard: tests must never touch the user's clipboard.
        let pasteboard = NSPasteboard(name: .init("MacComposerUndoTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("pasted", forType: .string)
        Self.asOwnEvent(textView) { XCTAssertTrue(textView.readSelection(from: pasteboard)) }
        XCTAssertEqual(textView.string, "hi pasted")
        textView.tryToPerform(Self.undoAction, with: nil)
        XCTAssertEqual(textView.string, "hi ")
    }

    func testUndoActionUndoesADeletionOfASelection() {
        let (_, textView) = makeWindowWithComposer()
        Self.asOwnEvent(textView) {
            textView.insertText("keep cut", replacementRange: NSRange(location: 0, length: 0))
        }
        // A cut is a copy plus this deletion; the copy half would touch the
        // user's clipboard.
        textView.setSelectedRange(NSRange(location: 4, length: 4))
        Self.asOwnEvent(textView) { textView.delete(nil) }
        XCTAssertEqual(textView.string, "keep")
        textView.tryToPerform(Self.undoAction, with: nil)
        XCTAssertEqual(textView.string, "keep cut")
    }

    func testEditMenuUndoAndRedoAreEnabledAndTitledFromTheComposersStack() {
        let (_, textView) = makeWindowWithComposer()
        let undoItem = NSMenuItem(title: "Undo", action: Self.undoAction, keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Self.redoAction, keyEquivalent: "Z")
        XCTAssertFalse(textView.validateMenuItem(undoItem), "nothing typed yet")

        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.validateMenuItem(undoItem))
        XCTAssertEqual(undoItem.title, textView.undoManager?.undoMenuItemTitle)
        XCTAssertNotEqual(undoItem.title, "Undo", "the action name should show, e.g. Undo Typing")
        XCTAssertFalse(textView.validateMenuItem(redoItem))

        textView.tryToPerform(Self.undoAction, with: nil)
        XCTAssertTrue(textView.validateMenuItem(redoItem))
        XCTAssertEqual(redoItem.title, textView.undoManager?.redoMenuItemTitle)
    }

    func testOtherEditMenuItemsStillValidateNormally() {
        let (_, textView) = makeWindowWithComposer()
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        XCTAssertTrue(textView.validateMenuItem(selectAll))
    }

    /// The app's own Edit menu: its Undo/Redo items own ⌘Z and ⇧⌘Z, and
    /// their actions, sent up the responder chain from the composer as
    /// AppKit sends them, undo and redo the composer's edits.
    func testTheAppsEditMenuUndoAndRedoItemsReachTheComposer() throws {
        func item(_ action: Selector) -> NSMenuItem? {
            func walk(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.action == action { return item }
                    if let sub = item.submenu, let found = walk(sub) { return found }
                }
                return nil
            }
            return NSApp.mainMenu.flatMap(walk)
        }
        let undoItem = try XCTUnwrap(item(Self.undoAction), "the app's Edit menu has no Undo")
        let redoItem = try XCTUnwrap(item(Self.redoAction), "the app's Edit menu has no Redo")
        XCTAssertEqual(undoItem.keyEquivalent, "z")
        XCTAssertEqual(undoItem.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(redoItem.keyEquivalent.lowercased(), "z")
        XCTAssertEqual(redoItem.keyEquivalentModifierMask, [.command, .shift])

        let (_, textView) = makeWindowWithComposer()
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.tryToPerform(try XCTUnwrap(undoItem.action), with: undoItem))
        XCTAssertEqual(textView.string, "")
        XCTAssertTrue(textView.tryToPerform(try XCTUnwrap(redoItem.action), with: redoItem))
        XCTAssertEqual(textView.string, "hello")
    }

    // MARK: - A replaced draft leaves no undo stack behind

    private struct Host: View {
        let box: UndoTestTextBox
        var body: some View {
            MacComposerTextEditor(text: Bindable(box).text, onHeightChange: { _ in },
                                  onMoveUp: { false }, onMoveDown: { false }, onCommit: { true },
                                  onPasteAttachments: { false }, onAttachablePasteboardTypes: { [] })
                .frame(width: 300, height: 60)
        }
    }

    private static func composerTextView(in view: NSView) -> ComposerTextView? {
        if let found = view as? ComposerTextView { return found }
        for sub in view.subviews {
            if let found = composerTextView(in: sub) { return found }
        }
        return nil
    }

    private static func spin(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// Sending clears the field by writing the binding. The typing entries
    /// still on the stack would bring the sent message back on ⌘Z.
    func testClearingTheDraftFromOutsideDropsTheUndoStack() async throws {
        let box = UndoTestTextBox()
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: Host(box: box))
        window.orderFront(nil)
        await Self.spin(seconds: 0.3)
        let textView = try XCTUnwrap(window.contentView.flatMap(Self.composerTextView(in:)))
        window.makeFirstResponder(textView)

        textView.insertText("sent message", replacementRange: NSRange(location: 0, length: 0))
        await Self.spin(seconds: 0.2)
        XCTAssertEqual(box.text, "sent message", "typing writes the binding")
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        box.text = ""   // what the post-send clear does
        await Self.spin(seconds: 0.3)
        XCTAssertEqual(textView.string, "")
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        textView.tryToPerform(Self.undoAction, with: nil)
        XCTAssertEqual(textView.string, "", "⌘Z after sending must not bring the message back")
        XCTAssertEqual(box.text, "")
    }

    /// Typing after the clear is undoable again, from the new text.
    func testTypingAfterAnOutsideWriteIsUndoable() async throws {
        let box = UndoTestTextBox()
        box.text = "draft"
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: Host(box: box))
        window.orderFront(nil)
        await Self.spin(seconds: 0.3)
        let textView = try XCTUnwrap(window.contentView.flatMap(Self.composerTextView(in:)))
        window.makeFirstResponder(textView)

        box.text = "recalled"   // e.g. ↑ history recall
        await Self.spin(seconds: 0.3)
        textView.insertText("!", replacementRange: textView.selectedRange())
        await Self.spin(seconds: 0.2)
        XCTAssertEqual(box.text, "recalled!")
        textView.tryToPerform(Self.undoAction, with: nil)
        await Self.spin(seconds: 0.2)
        XCTAssertEqual(textView.string, "recalled")
        XCTAssertEqual(box.text, "recalled", "undo writes back through the binding")
    }
}
#endif
