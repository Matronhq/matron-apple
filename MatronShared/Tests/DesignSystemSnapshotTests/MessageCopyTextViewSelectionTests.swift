#if os(macOS)
import AppKit
import XCTest
@testable import MatronDesignSystem

/// `MessageCopyTextView`'s side of the cross-message selection: target
/// conformance, highlight application, and the three copy entry points.
/// The tracking loop itself is exercised manually (see manual-tests.md) —
/// AppKit press paths cannot be driven deterministically headless.
@MainActor
final class MessageCopyTextViewSelectionTests: XCTestCase {

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private var window: NSWindow!
    private var controller: MessageSelectionController!
    private var textView: MessageCopyTextView!

    override func setUp() {
        super.setUp()
        controller = MessageSelectionController()
        controller.orderedIDs = ["m1", "m2"]
        textView = MessageCopyTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.markdownSource = "plain **bold** text"
        textView.textStorage?.setAttributedString(MarkdownAttributed.attributedString(for: "plain **bold** text"))
        textView.selectionItemID = "m1"
        textView.selectionController = controller
        window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = textView
    }

    override func tearDown() {
        window.contentView = nil
        window = nil
        super.tearDown()
    }

    // MARK: Registration

    func test_registersOnWindowAttach_unregistersOnDetach() {
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 10, y: 10), window: nil)
        XCTAssertNotNil(textView.crossSelectionRange, "attached view must be registered and receive a range")
        controller.clear()
        window.contentView = nil
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 10, y: 10), window: nil)
        XCTAssertNil(textView.crossSelectionRange, "a detached view must no longer be registered")
    }

    /// `updateNSView` mutates `selectionItemID` in place when SwiftUI reuses
    /// a body view for a different timeline item. The old registration must
    /// not survive that — a leak would let a later drag over the OLD row
    /// resolve to this view, painting the wrong message and copying its text
    /// under the old id.
    func test_changingItemID_unregistersOldID_registersNewID() {
        textView.selectionItemID = "m2"

        // The id it no longer has must not reach this view.
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.finish()
        XCTAssertNil(textView.crossSelectionRange, "must not be reachable under the id it no longer has")
        controller.clear()

        // Its current id must reach this view.
        controller.beginCrossMessage(anchorID: "m2", charIndex: 0)
        controller.finish()
        XCTAssertNotNil(textView.crossSelectionRange, "must be reachable under its current id")
    }

    /// Same failure mode as above, for the opt-out path: setting the id to
    /// nil must unregister, not merely skip registering under a new id.
    func test_changingItemIDToNil_unregistersOldID() {
        textView.selectionItemID = nil

        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.finish()
        XCTAssertNil(textView.crossSelectionRange, "a nil id must unregister the view, not just leave the old entry stranded")
    }

    // MARK: Highlight

    func test_setCrossSelection_appliesAndRemovesBackgroundRenderingAttribute() throws {
        let layoutManager = try XCTUnwrap(textView.textLayoutManager, "message bodies use TextKit 2")
        textView.setCrossSelection(NSRange(location: 0, length: 5))
        XCTAssertEqual(textView.crossSelectionRange, NSRange(location: 0, length: 5))
        XCTAssertNotNil(backgroundRenderingColor(in: layoutManager, at: 2))
        XCTAssertNil(backgroundRenderingColor(in: layoutManager, at: 10))
        textView.setCrossSelection(nil)
        XCTAssertNil(textView.crossSelectionRange)
        XCTAssertNil(backgroundRenderingColor(in: layoutManager, at: 2))
    }

    func test_setCrossSelection_clampsToStorageLength() {
        let length = textView.textStorage!.length
        textView.setCrossSelection(NSRange(location: 3, length: length + 50))
        XCTAssertEqual(textView.crossSelectionRange, NSRange(location: 3, length: length - 3))
    }

    // MARK: Markdown for the span

    func test_crossSelectionMarkdown_wholeStorage_isVerbatimSource() {
        textView.setCrossSelection(NSRange(location: 0, length: textView.textStorage!.length))
        XCTAssertEqual(textView.crossSelectionMarkdown(), "plain **bold** text")
    }

    func test_crossSelectionMarkdown_partial_reconstructs() {
        let boldRange = (textView.textStorage!.string as NSString).range(of: "bold")
        textView.setCrossSelection(boldRange)
        XCTAssertEqual(textView.crossSelectionMarkdown(), "**bold**")
    }

    func test_crossSelectionMarkdown_empty_isEmptyString() {
        textView.setCrossSelection(NSRange(location: 2, length: 0))
        XCTAssertEqual(textView.crossSelectionMarkdown(), "")
        textView.setCrossSelection(nil)
        XCTAssertEqual(textView.crossSelectionMarkdown(), "")
    }

    // MARK: Copy routing

    func test_copy_routesToTranscript_whenControllerHasSelection() {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.transcriptProvider = { Transcript(text: "[t] Me: hi", messageCount: 2) }
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        textView.copy(nil)
        XCTAssertEqual(written, ["[t] Me: hi"])
    }

    func test_copy_fallsBackToMarkdownCopy_withoutCrossSelection() {
        NSPasteboard.general.clearContents()
        textView.setSelectedRange(NSRange(location: 0, length: textView.textStorage!.length))
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "plain **bold** text")
    }

    func test_validateCopy_trueWhileSelected_evenWithEmptyTextSelection() {
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(textView.validateUserInterfaceItem(item))
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        XCTAssertTrue(textView.validateUserInterfaceItem(item))
    }

    // MARK: Context menu

    func test_menuTitle_pluralises() {
        XCTAssertEqual(MessageCopyTextView.menuTitle(forMessageCount: 1), "Copy 1 Message")
        XCTAssertEqual(MessageCopyTextView.menuTitle(forMessageCount: 3), "Copy 3 Messages")
    }

    func test_menu_prependsCopyMessages_onlyWhileSelected() {
        controller.transcriptProvider = { Transcript(text: "x", messageCount: 3) }
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        let before = textView.menu(for: event)
        XCTAssertFalse((before?.items ?? []).contains { $0.title == "Copy 3 Messages" })

        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        let menu = try! XCTUnwrap(textView.menu(for: event))
        XCTAssertEqual(menu.items.first?.title, "Copy 3 Messages")
        XCTAssertEqual(menu.items.first?.action, #selector(MessageCopyTextView.copyCrossSelection(_:)))
        XCTAssertTrue(menu.items.count >= 2 && menu.items[1].isSeparatorItem)
    }

    // MARK: Helpers

    private func backgroundRenderingColor(in layoutManager: NSTextLayoutManager, at offset: Int) -> NSColor? {
        let content = layoutManager.textContentManager!
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        var color: NSColor?
        layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attrs, _ in
            color = attrs[.backgroundColor] as? NSColor
            return false
        }
        return color
    }
}
#endif
