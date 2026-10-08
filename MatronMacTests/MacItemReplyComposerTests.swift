#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MatronDesignSystem
import MatronModels
import MatronViewModels
import MatronChat
@testable import MatronMac

/// Minimal timeline for hosting a real chat composer beside the reply field.
private final class FakeTimelineForReply: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> { AsyncThrowingStream { $0.finish() } }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

/// A tracker item's reply composer on the Mac is the chat composer's input
/// (`MacItemDetailHost.replyField` → `MacComposerField`), so it must behave
/// like it: Shift+Return inserts a newline, plain Return sends, ⌘V of an
/// image and a dropped file land in the reply's tray rather than posting on
/// their own.
///
/// These host the REAL `ItemCommentComposer` with the factory the host
/// installs, and drive the `NSTextView` inside it. Pasteboards are private
/// and uniquely named — never `NSPasteboard.general`, which is the
/// developer's own clipboard.
@MainActor
final class MacItemReplyComposerTests: XCTestCase {
    /// Records what the composer staged instead of copying anything.
    private final class FakeStager: AttachmentStaging {
        /// Files the caller keeps (a Finder file, a picked original).
        var attached: [URL] = []
        /// Temp files the caller wrote and handed over.
        var temporaries: [URL] = []
        var errors: [String] = []
        func attachFiles(_ urls: [URL]) async { attached += urls }
        func attachTemporaryFiles(_ urls: [URL]) async { temporaries += urls }
        func reportAttachmentError(_ message: String) { errors.append(message) }
    }

    /// Reference box for the composer's draft binding.
    private final class Draft { var text = "" }

    private var pasteboards: [NSPasteboard] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func makePasteboard(_ flavours: [(NSPasteboard.PasteboardType, Data)], function: String = #function) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MatronTest-\(function)-\(UUID())"))
        pasteboards.append(pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in flavours { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
        return pasteboard
    }

    private var pngData: Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    /// Hosts the reply composer with the host's field factory and returns
    /// the text view inside it.
    private func hostComposer(draft: Draft, attachments: [StagedAttachment] = [], stager: FakeStager,
                              pasteboard: NSPasteboard, onSubmit: @escaping () -> Void) throws -> ComposerTextView {
        let composer = ItemCommentComposer(
            draft: Binding(get: { draft.text }, set: { draft.text = $0 }),
            attachments: attachments, isBusy: false,
            onSubmit: onSubmit, onAttach: {}, onVoiceNote: {}
        )
        .environment(\.itemCommentField, MacItemDetailHost.replyField(stagingInto: stager, pasteboard: pasteboard))
        let hosting = NSHostingView(rootView: composer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        // Closed in tearDown while this test still holds it: without this,
        // `close()` releases it a second time.
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = hosting
        hosting.frame = window.contentRect(forFrameRect: window.frame)
        hosting.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(Self.firstComposerTextView(in: hosting), "the reply field is the chat composer's NSTextView")
        window.makeFirstResponder(textView)
        return textView
    }

    private static func firstComposerTextView(in view: NSView) -> ComposerTextView? {
        if let found = view as? ComposerTextView { return found }
        for sub in view.subviews {
            if let found = firstComposerTextView(in: sub) { return found }
        }
        return nil
    }

    /// Presses Return (optionally with Shift) in `textView`. The event is
    /// posted and dequeued first so it is `NSApp.currentEvent` — which is
    /// what the editor reads the Shift modifier from — then delivered to the
    /// text view directly (test-host windows are never key, so the
    /// application would not route it there itself).
    private func pressReturn(in textView: NSTextView, shift: Bool) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: textView.window?.windowNumber ?? 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.postEvent(event, atStart: true)
        let current = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true))
        XCTAssertEqual(NSApp.currentEvent?.modifierFlags.contains(.shift), shift)
        textView.keyDown(with: current)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: - Keys

    func test_shiftReturn_insertsANewline_andDoesNotSend() throws {
        let draft = Draft(); var sends = 0
        let textView = try hostComposer(draft: draft, stager: FakeStager(), pasteboard: makePasteboard([])) { sends += 1 }
        textView.insertText("first", replacementRange: textView.selectedRange())
        try pressReturn(in: textView, shift: true)
        textView.insertText("second", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "first\nsecond")
        XCTAssertEqual(draft.text, "first\nsecond", "the newline reaches the reply's draft")
        XCTAssertEqual(sends, 0)
    }

    func test_return_sends_andInsertsNoNewline() throws {
        let draft = Draft(); var sends = 0
        let textView = try hostComposer(draft: draft, stager: FakeStager(), pasteboard: makePasteboard([])) { sends += 1 }
        textView.insertText("ship it", replacementRange: textView.selectedRange())
        try pressReturn(in: textView, shift: false)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(textView.string, "ship it", "plain Return is the send gesture, never a newline")
    }

    /// A staged attachment on its own is a sendable reply, as in chat.
    func test_return_withOnlyAStagedAttachment_sends() throws {
        let staged = StagedAttachment(url: URL(fileURLWithPath: "/tmp/x.png"), filename: "x.png", mimeType: "image/png", sizeBytes: 1)
        var sends = 0
        let textView = try hostComposer(draft: Draft(), attachments: [staged], stager: FakeStager(),
                                        pasteboard: makePasteboard([])) { sends += 1 }
        try pressReturn(in: textView, shift: false)
        XCTAssertEqual(sends, 1)
    }

    func test_return_withNothingToSend_doesNothing() throws {
        var sends = 0
        let textView = try hostComposer(draft: Draft(), stager: FakeStager(), pasteboard: makePasteboard([])) { sends += 1 }
        try pressReturn(in: textView, shift: false)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(textView.string, "", "an unsendable Return is swallowed, not a stray newline")
    }

    // MARK: - Voice hotkey ownership

    /// Review, PR #274: the chat composer decides who owns the F5 voice
    /// hotkey by asking whether ANOTHER composer's text view has the caret.
    /// The reply field is the same `ComposerTextView` class but has no
    /// voice-bus identity — it must not count, or the claim sticks with
    /// another window's composer. Both fields live in one window here, as
    /// they do when the items pane sits beside a chat.
    func test_replyFieldWithTheCaret_doesNotCountAsAChatComposer() throws {
        let chatVM = ComposerViewModel(roomID: "!r:s", timeline: FakeTimelineForReply(), commands: [])
        let root = VStack {
            MacComposerView(viewModel: chatVM)
            ItemCommentComposer(draft: .constant(""), isBusy: false, onSubmit: {}, onAttach: {}, onVoiceNote: {})
                .environment(\.itemCommentField, MacItemDetailHost.replyField(stagingInto: FakeStager(),
                                                                              pasteboard: makePasteboard([])))
        }
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = hosting
        hosting.frame = window.contentRect(forFrameRect: window.frame)
        hosting.layoutSubtreeIfNeeded()
        let fields = Self.composerTextViews(in: hosting)
        XCTAssertEqual(fields.count, 2)
        let chatField = try XCTUnwrap(fields.first { $0.isChatComposer }, "the chat composer marks itself")
        let replyField = try XCTUnwrap(fields.first { !$0.isChatComposer }, "the reply field does not")

        window.makeFirstResponder(replyField)
        XCTAssertFalse(MacComposerView.chatComposerHasCaret(in: window))
        window.makeFirstResponder(chatField)
        XCTAssertTrue(MacComposerView.chatComposerHasCaret(in: window))
    }

    private static func composerTextViews(in view: NSView) -> [ComposerTextView] {
        ((view as? ComposerTextView).map { [$0] } ?? []) + view.subviews.flatMap { composerTextViews(in: $0) }
    }

    // MARK: - Paste

    /// ⌘V of a screenshot: AppKit must OFFER Paste (the gate that made ⌘V
    /// beep in chat until PR #110), and the paste must land in the tray,
    /// not the text.
    func test_pastingAnImage_stagesItInTheTray() async throws {
        let stager = FakeStager()
        let pasteboard = makePasteboard([(.png, pngData)])
        let textView = try hostComposer(draft: Draft(), stager: stager, pasteboard: pasteboard) {}
        XCTAssertNotNil(pasteboard.availableType(from: textView.readablePasteboardTypes),
                        "Paste must be enabled for an image-only pasteboard")
        textView.paste(nil)
        await waitUntil { stager.temporaries.count == 1 }
        XCTAssertEqual(stager.temporaries.first?.pathExtension, "png", "the paste's temp file is handed over, not copied")
        XCTAssertEqual(stager.attached, [])
        XCTAssertEqual(textView.string, "", "nothing lands in the text field")
        XCTAssertEqual(stager.errors, [])
    }

    /// Text on the pasteboard is not claimed: the text view pastes it
    /// itself. (Asserted at the claim, which is the decision the text view's
    /// `paste(_:)` acts on — `super.paste` reads the real clipboard.)
    func test_pastingText_isNotClaimed() {
        let stager = FakeStager()
        let pasteboard = makePasteboard([(.string, Data("hello".utf8))])
        XCTAssertFalse(PasteboardAttachmentBridge.claimAttachments(on: pasteboard, into: stager))
        XCTAssertEqual(PasteboardAttachmentBridge.readableTypesToOffer(on: pasteboard), [])
        XCTAssertEqual(stager.attached, [])
    }

    // MARK: - Drop

    /// A file dropped on the item pane goes to the tray (through the chat
    /// column's loader), not straight out as its own comment.
    func test_droppingAFile_stagesItInTheTray() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID()).txt")
        try Data("notes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        let stager = FakeStager()
        await ComposerDropDelegate.attach([provider], into: stager)
        XCTAssertEqual(stager.attached.map(\.lastPathComponent), [file.lastPathComponent])
        XCTAssertEqual(stager.temporaries, [], "the user's own dropped file is copied, never handed over")
        XCTAssertEqual(stager.errors, [])
    }
}
#endif
