#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class StubTimeline: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> { AsyncThrowingStream { _ in } }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

/// Records that a timeline VM subscribed — proof its view mounted.
private final class SubscribedTimeline: TimelineService, @unchecked Sendable {
    private(set) var subscribed = false
    func items() -> AsyncThrowingStream<[TimelineItem], Error> { subscribed = true; return AsyncThrowingStream { _ in } }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

private final class StubMedia: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

private final class StubChat: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

/// A Mac window holds one chat, so one composer: it answers the menu bus
/// and sends on Return wherever the caret is.
@MainActor
final class MacChatWindowComposerTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    private func chat(_ roomID: String) -> (MacChatView, ComposerViewModel) {
        let timeline = StubTimeline()
        let chatVM = ChatViewModel(roomID: roomID, timeline: timeline, media: StubMedia())
        let composer = ComposerViewModel(roomID: roomID, timeline: timeline, commands: [])
        let strip = SubChatStripViewModel(chat: StubChat(), parentConvoID: roomID)
        let view = MacChatView(viewModel: chatVM, composerVM: composer, stripViewModel: strip,
                               subChatProvider: { _ in (chatVM, strip) }, chatTitle: roomID)
        return (view, composer)
    }

    /// The menu bus (⌘K Slash Command) reaches the window's chat.
    func test_chat_answersMenuBusCommands() async {
        let (main, mainComposer) = chat("main")
        let window = mountKey(main.frame(width: 800, height: 500))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 1 }
        XCTAssertTrue(mounted, "the chat's composer must be on screen")

        NotificationCenter.default.post(name: .matronCommand(.slashCommand), object: nil)
        let answered = await Self.poll(seconds: 5) { mainComposer.palettePinnedOpen }
        XCTAssertTrue(answered)
    }

    /// The composer is alone in its window, and Return sends its draft
    /// wherever the caret is.
    func test_return_sendsTheDraftWithNothingFocused() async throws {
        let (main, mainComposer) = chat("main")
        mainComposer.input = "main draft"
        let window = mountKey(main.frame(width: 800, height: 500))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 1 }
        XCTAssertTrue(mounted)
        window.makeFirstResponder(nil)
        await Self.spin(seconds: 0.3)
        Self.pressReturn(in: window)
        let sent = await Self.poll(seconds: 3) { mainComposer.input.isEmpty }
        XCTAssertTrue(sent, "the sole composer sends on Return with nothing focused")
    }

    /// #2849: the sub-chat pane is a read-only viewer — it has NO composer
    /// (see `MacSubChatPane`), so opening one beside the chat never puts a
    /// second composer in the window and the main composer stays alone:
    /// Return still sends its draft with nothing focused, and the voice
    /// hotkey has one claimant. If a composer is ever added to the pane,
    /// this fails — Return would then have two composers to choose from.
    func test_subChatPaneOpen_leavesTheMainComposerAloneInTheWindow() async throws {
        let bus = VoiceNoteCommandBus()
        let timeline = StubTimeline()
        let childTimeline = SubscribedTimeline()
        let chatVM = ChatViewModel(roomID: "main", timeline: timeline, media: StubMedia())
        let childVM = ChatViewModel(roomID: "child", timeline: childTimeline, media: StubMedia())
        let composer = ComposerViewModel(roomID: "main", timeline: timeline, commands: [])
        composer.input = "main draft"
        let strip = SubChatStripViewModel(chat: StubChat(), parentConvoID: "main")
        let view = MacChatView(viewModel: chatVM, composerVM: composer, stripViewModel: strip,
                               subChatProvider: { _ in (childVM, strip) },
                               paneRoute: .constant(.subChat(id: "child")), chatTitle: "main")
        // Wider than `sideBySideMinWidth`: parent and child side by side.
        let window = mountKey(view.frame(width: 1000, height: 500).environment(bus))
        let paneMounted = await Self.poll(seconds: 5) { childTimeline.subscribed && bus.activeComposerID != nil }
        XCTAssertTrue(paneMounted, "the sub-chat pane is on screen, its timeline started")
        await Self.spin(seconds: 0.3)
        XCTAssertEqual(Self.composerTextViews(in: window).count, 1, "the sub-chat pane adds no composer")
        let claimant = bus.activeComposerID

        window.makeFirstResponder(nil)
        await Self.spin(seconds: 0.3)
        Self.pressReturn(in: window)
        let sent = await Self.poll(seconds: 3) { composer.input.isEmpty }
        XCTAssertTrue(sent, "alone in the window, the main composer still sends on Return")
        XCTAssertEqual(bus.activeComposerID, claimant, "the voice hotkey stays with the only composer")
    }

    /// A window made key, so focus and key equivalents behave as in the app.
    private func mountKey<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        return window
    }

    /// The composers' text views in the window.
    private static func composerTextViews(in window: NSWindow) -> [ComposerTextView] {
        func collect(_ view: NSView) -> [ComposerTextView] {
            (view as? ComposerTextView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        guard let root = window.contentView else { return [] }
        return collect(root)
    }

    /// A plain Return through the app's own dispatch, key equivalents first.
    private static func pressReturn(in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func poll(seconds: TimeInterval, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return done()
    }

    private static func spin(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
#endif
