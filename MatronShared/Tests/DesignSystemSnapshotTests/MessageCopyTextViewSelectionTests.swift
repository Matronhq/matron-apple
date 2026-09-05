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
        // A span painted under the OLD id is unreachable by the controller
        // once the view answers to a new one, so the id change must drop it
        // itself or the highlight is stranded on screen forever.
        textView.setCrossSelection(NSRange(location: 0, length: 5))
        textView.selectionItemID = "m2"
        XCTAssertNil(textView.crossSelectionRange,
                     "an id change must drop the span painted under the previous id")

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

    /// A drag pushes a range to every view in the span on every mouse event,
    /// and the middles' ranges never change — repainting them all is pure
    /// waste. `force` exists for the one case that needs it: a streaming
    /// delta swaps the storage, the range still matches, but the rendering
    /// attributes died with the old storage.
    func test_setCrossSelection_unchangedRangeEarlyOuts_forceReappliesAfterStorageSwap() throws {
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let range = NSRange(location: 0, length: 5)
        textView.setCrossSelection(range)
        XCTAssertNotNil(backgroundRenderingColor(in: layoutManager, at: 2))

        // Streaming delta: the storage is replaced and the rendering
        // attributes die with it, while `crossSelectionRange` still matches.
        textView.textStorage?.setAttributedString(
            MarkdownAttributed.attributedString(for: "plain **bold** text and more"))
        XCTAssertNil(backgroundRenderingColor(in: layoutManager, at: 2),
                     "a storage swap drops rendering attributes")

        textView.setCrossSelection(range)
        XCTAssertNil(backgroundRenderingColor(in: layoutManager, at: 2),
                     "an unchanged range must early-out — a drag pushes it to every view every event")

        textView.setCrossSelection(range, force: true)
        XCTAssertEqual(textView.crossSelectionRange, range)
        XCTAssertNotNil(backgroundRenderingColor(in: layoutManager, at: 2),
                        "force must repaint the span onto the new storage")
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
        controller.transcriptProvider = { SelectionTranscript(text: "[t] Me: hi", messageCount: 2) }
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

    /// NSTextView's answer for an action it does not know is not contractual,
    /// so the AppKit "Copy N Messages" item must be validated explicitly or it
    /// can ship greyed out.
    func test_validateCopyCrossSelection_trueWhileSelected() {
        let item = NSMenuItem(
            title: "Copy 2 Messages",
            action: #selector(MessageCopyTextView.copyCrossSelection(_:)), keyEquivalent: "")
        XCTAssertFalse(textView.validateUserInterfaceItem(item))
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        XCTAssertTrue(textView.validateUserInterfaceItem(item))
    }

    // MARK: Context menu

    func test_menuTitle_pluralises() {
        XCTAssertEqual(MessageCopyTextView.menuTitle(forMessageCount: 1), "Copy 1 Message")
        XCTAssertEqual(MessageCopyTextView.menuTitle(forMessageCount: 3), "Copy 3 Messages")
    }

    private func rightClick() -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func test_menu_prependsCopyMessages_onlyWhileSelected() throws {
        controller.transcriptProvider = { SelectionTranscript(text: "[t] Me: hi", messageCount: 3) }
        let event = rightClick()
        let before = textView.menu(for: event)
        XCTAssertFalse((before?.items ?? []).contains { $0.title == "Copy 3 Messages" })

        // The item is built from the FINISHED snapshot, so the selection has
        // to have been finished — a live drag offers no context menu anyway.
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.finish()
        let menu = try XCTUnwrap(textView.menu(for: event))
        XCTAssertEqual(menu.items.first?.title, "Copy 3 Messages")
        XCTAssertEqual(menu.items.first?.action, #selector(MessageCopyTextView.copyCrossSelection(_:)))
        XCTAssertTrue(menu.items.count >= 2 && menu.items[1].isSeparatorItem)
    }

    /// The item carries its text, and the action copies THAT — not whatever
    /// the controller still holds by the time the click lands (the click is a
    /// left mouse down, which the clear-monitor answers by clearing).
    func test_menuItem_carriesTranscriptText_andCopiesItAfterTheSelectionIsGone() throws {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.transcriptProvider = { SelectionTranscript(text: "[t] Me: hi", messageCount: 2) }
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        controller.finish()

        let item = try XCTUnwrap(textView.menu(for: rightClick())?.items.first)
        XCTAssertEqual(item.representedObject as? String, "[t] Me: hi")

        controller.clear()   // the click that opens the item also clears
        textView.copyCrossSelection(item)
        XCTAssertEqual(written, ["[t] Me: hi"])
    }

    func test_menu_withoutASnapshot_returnsSuperMenuUntouched() {
        controller.transcriptProvider = { SelectionTranscript(text: "x", messageCount: 3) }
        // A selection exists but was never finished: no snapshot, no item.
        controller.beginCrossMessage(anchorID: "m1", charIndex: 0)
        let menu = textView.menu(for: rightClick())
        XCTAssertFalse((menu?.items ?? []).contains { $0.title == "Copy 3 Messages" })
        XCTAssertFalse(menu?.items.first?.isSeparatorItem ?? false)
    }

    // MARK: Takeover decisions

    func test_shouldEscalate_onlyOutsideVerticalBandWithSlop() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 60)
        XCTAssertFalse(MessageCopyTextView.shouldEscalate(pointY: 30, bounds: bounds, slop: 4))
        XCTAssertFalse(MessageCopyTextView.shouldEscalate(pointY: -4, bounds: bounds, slop: 4), "inside slop above")
        XCTAssertFalse(MessageCopyTextView.shouldEscalate(pointY: 64, bounds: bounds, slop: 4), "inside slop below")
        XCTAssertTrue(MessageCopyTextView.shouldEscalate(pointY: -4.5, bounds: bounds, slop: 4))
        XCTAssertTrue(MessageCopyTextView.shouldEscalate(pointY: 64.5, bounds: bounds, slop: 4))
    }

    func test_takesOverPress_plainSingleClickOnly() {
        func press(clicks: Int, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: clicks, pressure: 1)!
        }
        XCTAssertTrue(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: [])))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 2, flags: [])), "double-click = word selection stays AppKit's")
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .shift)))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .command)))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .option)))
        XCTAssertFalse(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .control)), "ctrl-click is a context menu")
        XCTAssertTrue(MessageCopyTextView.takesOverPress(press(clicks: 1, flags: .capsLock)), "lock keys are not modifiers here")
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
