#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class PanelTimeline: TimelineService, @unchecked Sendable {
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

private final class PanelMedia: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

private final class PanelChat: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

private func headerProps(_ roomID: String, strip: SubChatStripViewModel) -> MacChatToolbarProps {
    MacChatToolbarProps(
        roomID: roomID, publisher: UUID(), title: roomID, boxName: nil, styledTitle: nil,
        accessibilityTitle: nil, status: nil, stripViewModel: strip, missionID: nil,
        needsYouCount: 0, itemsAvailable: true,
        actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                       showMediaBrowser: .constant(false), showItemsPane: .constant(false)))
}

private final class ShellModel: ObservableObject {
    /// `false` = the detail shows no chat (Missions, Decisions, "Select a chat").
    @Published var detailHasChat = false
    @Published var panelWidth: Double = 380
}

/// Reports key whatever the test host's activation state.
private final class AlwaysKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private final class Captured { var panelProps: MacChatToolbarProps? }

private final class VoiceHarnessModel: ObservableObject {
    @Published var panelOpen = false
    @Published var mainShown = true
}

private struct VoiceHarness: View {
    @ObservedObject var model: VoiceHarnessModel
    let main: MacChatView
    let panel: MacChatView

    var body: some View {
        HStack(spacing: 0) {
            if model.mainShown {
                main.environment(\.macComposerSoleInWindow, !model.panelOpen)
            } else {
                Text("Missions")
            }
            if model.panelOpen { panel }
        }
        .frame(width: 1000, height: 500)
    }
}

/// App-shaped detail: the header host over the panel container, the panel
/// holding a chat that publishes its own header props.
private struct PanelShellHarness: View {
    @ObservedObject var model: ShellModel
    let strip: SubChatStripViewModel
    let captured: Captured
    let detailWidth: (CGFloat) -> Void

    var body: some View {
        NavigationSplitView {
            List { Text("sidebar") }
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 472, ideal: 472, max: 472)
                .toolbar {
                    MacCoordinatorToolbarToggle(isOpen: true, toggle: {})
                    ToolbarItem(placement: .primaryAction) { Button("New") {} }
                }
        } detail: {
            MacChatHeaderHost {
                MacCoordinatorPanelContainer(isOpen: true, width: $model.panelWidth) {
                    detail
                } panel: {
                    Color.gray
                        .preference(key: MacChatToolbarPreference.self, value: headerProps("coord", strip: strip))
                        .coordinatorPanelHeaderScope { captured.panelProps = $0 }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        GeometryReader { geo in
            Group {
                if model.detailHasChat {
                    Color.clear.preference(key: MacChatToolbarPreference.self, value: headerProps("main", strip: strip))
                } else {
                    Text("Select a mission")
                }
            }
            .onAppear { detailWidth(geo.size.width) }
            .onChange(of: geo.size.width) { _, width in detailWidth(width) }
        }
    }
}

@MainActor
final class MacCoordinatorPanelTests: XCTestCase {
    private var window: NSWindow?
    private var otherWindow: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        otherWindow?.close()
        otherWindow = nil
        try await super.tearDown()
    }

    private func chat(_ roomID: String, respondsToMenuCommands: Bool) -> (MacChatView, ComposerViewModel) {
        let timeline = PanelTimeline()
        let chatVM = ChatViewModel(roomID: roomID, timeline: timeline, media: PanelMedia())
        let composer = ComposerViewModel(roomID: roomID, timeline: timeline, commands: [])
        let strip = SubChatStripViewModel(chat: PanelChat(), parentConvoID: roomID)
        let view = MacChatView(viewModel: chatVM, composerVM: composer, stripViewModel: strip,
                               subChatProvider: { _ in (chatVM, strip) }, chatTitle: roomID,
                               respondsToMenuCommands: respondsToMenuCommands)
        return (view, composer)
    }

    /// Review focus: with the panel open two chats are on screen; the menu
    /// bus (⌘K Slash Command, ⌘R) must reach the main chat only.
    func test_panelChat_ignoresMenuBusCommands_mainChatStillAnswers() async {
        let (main, mainComposer) = chat("main", respondsToMenuCommands: true)
        let (panel, panelComposer) = chat("coord", respondsToMenuCommands: false)
        let host = NSHostingController(rootView: HStack { main; panel }.frame(width: 1000, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)
        self.window = window
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 2 }
        XCTAssertTrue(mounted, "both chats' composers must be on screen")

        NotificationCenter.default.post(name: .matronCommand(.slashCommand), object: nil)
        let answered = await Self.poll(seconds: 5) { mainComposer.palettePinnedOpen }

        XCTAssertTrue(answered)
        XCTAssertFalse(panelComposer.palettePinnedOpen)
    }

    /// Fix round 1 (I1): two composers in one window, both with a sendable
    /// draft. Return sends the FOCUSED composer's draft only — the send
    /// button's window-level Return shortcut used to claim the key for
    /// whichever composer SwiftUI picked, whatever had focus.
    func test_return_sendsOnlyTheFocusedComposersDraft() async throws {
        let (main, mainComposer) = chat("main", respondsToMenuCommands: true)
        let (panel, panelComposer) = chat("coord", respondsToMenuCommands: false)
        mainComposer.input = "main draft"
        panelComposer.input = "panel draft"
        // Panel open: as `MacChatListView` does, the main chat is told it
        // shares the window.
        let window = mountKey(HStack(spacing: 0) {
            main.environment(\.macComposerSoleInWindow, false)
            panel
        }.frame(width: 1000, height: 500))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 2 }
        XCTAssertTrue(mounted)
        let views = Self.composerTextViews(in: window)
        let (mainText, panelText) = (views[0], views[1])

        // Neither composer focused, two in the window: Return is no
        // composer's to take.
        window.makeFirstResponder(nil)
        await Self.spin(seconds: 0.3)
        Self.pressReturn(in: window)
        await Self.spin(seconds: 0.5)
        XCTAssertEqual(mainComposer.input, "main draft", "an unfocused composer must not send on Return")
        XCTAssertEqual(panelComposer.input, "panel draft", "an unfocused composer must not send on Return")

        XCTAssertTrue(window.makeFirstResponder(panelText))
        await Self.spin(seconds: 0.3)
        Self.pressReturn(in: window)
        let panelSent = await Self.poll(seconds: 3) { panelComposer.input.isEmpty }
        XCTAssertTrue(panelSent, "Return in the panel composer sends the panel's draft")
        XCTAssertEqual(mainComposer.input, "main draft", "…and never the main chat's")

        panelComposer.input = "panel draft 2"
        XCTAssertTrue(window.makeFirstResponder(mainText))
        await Self.spin(seconds: 0.3)
        Self.pressReturn(in: window)
        let mainSent = await Self.poll(seconds: 3) { mainComposer.input.isEmpty }
        XCTAssertTrue(mainSent, "Return in the main composer sends the main draft")
        XCTAssertEqual(panelComposer.input, "panel draft 2", "…and never the panel's")
    }

    /// Fix round 2: with the panel closed the main composer is alone in the
    /// window, and Return sends its draft wherever the caret is — as it
    /// always did.
    func test_return_panelClosed_sendsTheMainDraftWithNothingFocused() async throws {
        let (main, mainComposer) = chat("main", respondsToMenuCommands: true)
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

    /// Fix round 2: with the caret in the panel composer, the window
    /// re-keying (⌘-Tab away and back) must not hand the hotkey back to the
    /// main chat.
    func test_voiceHotkey_windowReKey_keepsTheFocusedPanelsClaim() async throws {
        let bus = VoiceNoteCommandBus()
        let model = VoiceHarnessModel()
        model.panelOpen = true
        let (main, _) = chat("main", respondsToMenuCommands: true)
        let (panel, _) = chat("coord", respondsToMenuCommands: false)
        let window = mountKey(VoiceHarness(model: model, main: main, panel: panel).environment(bus))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 2 && bus.activeComposerID != nil }
        XCTAssertTrue(mounted)
        // Deterministic ids, whatever order the composers mounted in (CI):
        // focusing each composer makes it the claimant.
        let mainClaim = await Self.claimant(focusing: Self.composerTextViews(in: window)[0], in: window, bus: bus)
        let panelClaim = await Self.claimant(focusing: Self.composerTextViews(in: window)[1], in: window, bus: bus)
        XCTAssertNotNil(mainClaim)
        XCTAssertNotEqual(panelClaim, mainClaim, "the caret in the panel composer takes the hotkey")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await Self.spin(seconds: 0.5)
        XCTAssertEqual(bus.activeComposerID, panelClaim, "re-keying the window keeps the focused composer's claim")
    }

    /// CI (PR #234): a re-render of the main composer (its `WindowAccessor`
    /// reports the key window again) must not take the hotkey from the
    /// panel composer — the main composer claims only when it first learns
    /// its window. The window is forced key: under `xcodebuild test` the
    /// host app is not frontmost, `isKeyWindow` stays false and
    /// `claimIfKey` can never steal, so without it this test passed with
    /// the fix reverted (#2852). The second leg moves the caret off the
    /// panel: with the caret still in it, the focused-composer check hides
    /// a missing first-learn guard.
    func test_voiceHotkey_mainComposerRerender_keepsTheFocusedPanelsClaim() async throws {
        let bus = VoiceNoteCommandBus()
        let model = VoiceHarnessModel()
        model.panelOpen = true
        let (main, mainComposer) = chat("main", respondsToMenuCommands: true)
        let (panel, _) = chat("coord", respondsToMenuCommands: false)
        let window = mountKey(VoiceHarness(model: model, main: main, panel: panel).environment(bus), forceKey: true)
        XCTAssertTrue(window.isKeyWindow, "the re-render path only steals in a key window")
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 2 && bus.activeComposerID != nil }
        XCTAssertTrue(mounted)
        let mainClaim = await Self.claimant(focusing: Self.composerTextViews(in: window)[0], in: window, bus: bus)
        let panelClaim = await Self.claimant(focusing: Self.composerTextViews(in: window)[1], in: window, bus: bus)
        XCTAssertNotEqual(panelClaim, mainClaim)

        await Self.rerender(mainComposer, model: model, texts: ["a", "ab", "abc"])
        XCTAssertEqual(bus.activeComposerID, panelClaim, "a main-composer update never steals the focused panel's hotkey")

        // The caret leaves the panel (a click in the timeline): the panel
        // keeps the hotkey it was last given, and re-renders of the main
        // composer still leave it there.
        window.makeFirstResponder(nil)
        await Self.spin(seconds: 0.3)
        XCTAssertEqual(bus.activeComposerID, panelClaim)
        await Self.rerender(mainComposer, model: model, texts: ["abcd", "abcde", "abcdef"])
        XCTAssertEqual(bus.activeComposerID, panelClaim, "a main-composer update never steals the panel's hotkey")
    }

    /// Re-renders the main composer: draft edits, then the harness itself.
    private static func rerender(_ composer: ComposerViewModel, model: VoiceHarnessModel, texts: [String]) async {
        for text in texts {
            composer.input = text
            await spin(seconds: 0.2)
        }
        model.objectWillChange.send()
        await spin(seconds: 0.3)
    }

    /// Re-review #2852 item 1: window A shows Missions with the panel open
    /// (the panel composer holds A's hotkey, unfocused); window B becomes
    /// key and claims; back in A the panel composer takes it back.
    func test_voiceHotkey_reKeyingAPanelOnlyWindow_takesTheHotkeyBack() async throws {
        let bus = VoiceNoteCommandBus()
        let model = VoiceHarnessModel()
        model.panelOpen = true
        model.mainShown = false
        let (main, _) = chat("main", respondsToMenuCommands: true)
        let (panel, _) = chat("coord", respondsToMenuCommands: false)
        let windowA = mountKey(VoiceHarness(model: model, main: main, panel: panel).environment(bus))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: windowA).count == 1 }
        XCTAssertTrue(mounted)
        windowA.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowA)
        let panelHeld = await Self.poll(seconds: 3) { bus.activeComposerID != nil }
        XCTAssertTrue(panelHeld)
        await Self.spin(seconds: 0.3)
        let panelClaim = bus.activeComposerID

        let (other, _) = chat("other", respondsToMenuCommands: true)
        let windowB = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 800, height: 500),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        windowB.isReleasedWhenClosed = false
        windowB.contentViewController = NSHostingController(rootView: other.frame(width: 800, height: 500).environment(bus))
        otherWindow = windowB
        windowB.makeKeyAndOrderFront(nil)
        let bMounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: windowB).count == 1 }
        XCTAssertTrue(bMounted)
        await Self.spin(seconds: 0.3)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowB)
        let bClaimed = await Self.poll(seconds: 5) { bus.activeComposerID != panelClaim && bus.activeComposerID != nil }
        XCTAssertTrue(bClaimed, "window B's composer takes the hotkey while B is key")

        windowA.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowA)
        let back = await Self.poll(seconds: 3) { bus.activeComposerID == panelClaim }
        XCTAssertTrue(back, "window A key again: its only composer, the panel's, holds the hotkey")
    }

    /// Fix round 1 (I2): the global voice-note hotkey stays with the main
    /// chat. Opening the panel must not steal the bus, and closing it must
    /// not leave the window with no claimant.
    func test_voiceHotkey_staysWithTheMainChat_whenThePanelOpensAndCloses() async throws {
        let bus = VoiceNoteCommandBus()
        let model = VoiceHarnessModel()
        let (main, _) = chat("main", respondsToMenuCommands: true)
        let (panel, _) = chat("coord", respondsToMenuCommands: false)
        let window = mountKey(VoiceHarness(model: model, main: main, panel: panel).environment(bus))
        let claimed = await Self.poll(seconds: 5) { bus.activeComposerID != nil }
        XCTAssertTrue(claimed, "the main composer claims the bus on mount")
        let mainClaim = bus.activeComposerID

        model.panelOpen = true
        let panelMounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 2 }
        XCTAssertTrue(panelMounted)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await Self.spin(seconds: 0.5)
        XCTAssertEqual(bus.activeComposerID, mainClaim, "opening the panel (or the window re-keying) must not steal the hotkey")

        model.panelOpen = false
        let panelGone = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 1 }
        XCTAssertTrue(panelGone)
        await Self.spin(seconds: 0.3)
        XCTAssertEqual(bus.activeComposerID, mainClaim, "closing the panel leaves the hotkey live on the main chat")
    }

    /// Final review I1: caret in window A's panel composer, window B
    /// becomes key and claims, then A is key again — A's panel composer
    /// must take the hotkey back (the main composer declines because
    /// another composer is focused), or F5 records into B's chat.
    func test_voiceHotkey_reKeyingAWindow_returnsTheHotkeyToItsFocusedPanel() async throws {
        let bus = VoiceNoteCommandBus()
        let model = VoiceHarnessModel()
        model.panelOpen = true
        let (main, _) = chat("main", respondsToMenuCommands: true)
        let (panel, _) = chat("coord", respondsToMenuCommands: false)
        let windowA = mountKey(VoiceHarness(model: model, main: main, panel: panel).environment(bus))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: windowA).count == 2 && bus.activeComposerID != nil }
        XCTAssertTrue(mounted)
        XCTAssertTrue(windowA.makeFirstResponder(Self.composerTextViews(in: windowA)[1]))
        let panelClaimed = await Self.poll(seconds: 3) { bus.activeComposerID != nil }
        XCTAssertTrue(panelClaimed)
        await Self.spin(seconds: 0.3)
        let panelClaim = bus.activeComposerID

        let (other, _) = chat("other", respondsToMenuCommands: true)
        let windowB = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 800, height: 500),
                               styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        windowB.isReleasedWhenClosed = false
        windowB.contentViewController = NSHostingController(rootView: other.frame(width: 800, height: 500).environment(bus))
        otherWindow = windowB
        windowB.makeKeyAndOrderFront(nil)
        let bMounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: windowB).count == 1 }
        XCTAssertTrue(bMounted)
        await Self.spin(seconds: 0.3)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowB)
        let bClaimed = await Self.poll(seconds: 5) { bus.activeComposerID != panelClaim && bus.activeComposerID != nil }
        XCTAssertTrue(bClaimed, "window B's composer takes the hotkey while B is key")

        windowA.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowA)
        let back = await Self.poll(seconds: 3) { bus.activeComposerID == panelClaim }
        XCTAssertTrue(back, "window A key again: its focused panel composer holds the hotkey")
    }

    /// Bugbot B1 (PR #234): the main chat unmounting (Missions, Decisions)
    /// while the panel composer is on screen must not leave the window's
    /// hotkey dead — the panel composer inherits it.
    func test_voiceHotkey_mainChatUnmounting_handsTheHotkeyToThePanel() async throws {
        let bus = VoiceNoteCommandBus()
        let model = VoiceHarnessModel()
        model.panelOpen = true
        let (main, _) = chat("main", respondsToMenuCommands: true)
        let (panel, _) = chat("coord", respondsToMenuCommands: false)
        let window = mountKey(VoiceHarness(model: model, main: main, panel: panel).environment(bus))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 2 && bus.activeComposerID != nil }
        XCTAssertTrue(mounted)
        let mainClaim = await Self.claimant(focusing: Self.composerTextViews(in: window)[0], in: window, bus: bus)
        XCTAssertNotNil(mainClaim)

        model.mainShown = false
        let handedOver = await Self.poll(seconds: 5) {
            Self.composerTextViews(in: window).count == 1 && bus.activeComposerID != nil && bus.activeComposerID != mainClaim
        }
        XCTAssertTrue(handedOver, "the panel composer holds the hotkey once the main chat is gone")
    }

    /// Final review I4: the Coordinator is hidden from Conversations, so the
    /// toolbar toggle carries its unread signal — the dot iOS's floating
    /// button has.
    func test_toolbarToggle_showsTheHiddenCoordinatorsUnread() {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "B", avatarURL: nil)
        let unread = ChatSummary(id: "coord", title: "C", bot: bot, lastActivity: nil, unreadCount: 3)
        let read = ChatSummary(id: "coord", title: "C", bot: bot, lastActivity: nil, unreadCount: 0)
        XCTAssertTrue(MacCoordinatorToolbarToggle.hasUnread(unread))
        XCTAssertFalse(MacCoordinatorToolbarToggle.hasUnread(read))
        XCTAssertFalse(MacCoordinatorToolbarToggle.hasUnread(nil))
        XCTAssertEqual(MacCoordinatorToolbarToggle.accessibilityLabel(isOpen: false, hasUnread: true),
                       "Show Coordinator, unread messages")
        XCTAssertEqual(MacCoordinatorToolbarToggle.accessibilityLabel(isOpen: true, hasUnread: false),
                       "Hide Coordinator")
    }

    /// The dot is drawn: the icon with unread renders red pixels, without
    /// it none.
    func test_toolbarToggleIcon_drawsTheDotOnlyWithUnread() throws {
        func redPixels(_ hasUnread: Bool) throws -> Int {
            let view = NSHostingView(rootView: MacCoordinatorToggleIcon(hasUnread: hasUnread).padding(4))
            view.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            var count = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.8, c.greenComponent < 0.35, c.blueComponent < 0.35, c.alphaComponent > 0.8 { count += 1 }
            } }
            return count
        }
        XCTAssertGreaterThan(try redPixels(true), 10)
        XCTAssertEqual(try redPixels(false), 0)
    }

    /// Bugbot B2 (PR #234): a panel restored open by @SceneStorage must not
    /// flash "Choose a conversation…" while the `.task` has yet to read the
    /// cached setting — until then the panel reads the cache itself.
    func test_restoredPanel_readsTheCachedCoordinatorBeforeTheFirstRead() {
        XCTAssertEqual(MacChatListView.resolvedCoordinatorID(state: nil, resolved: false, cached: { "coord" }), "coord")
        XCTAssertNil(MacChatListView.resolvedCoordinatorID(state: nil, resolved: true, cached: { "coord" }),
                     "once read, a cleared Coordinator is really cleared")
        XCTAssertEqual(MacChatListView.resolvedCoordinatorID(state: "new", resolved: true, cached: { "old" }), "new")
    }

    /// Bugbot (PR #238): on a cold start a notification tap or search hit
    /// for the Coordinator can run before the `.task` reads the cached
    /// setting. Routing must key off the same id the restored panel shows,
    /// or the detail mounts a second MacChatView of the Coordinator on the
    /// other view-model cache.
    func test_coldStart_routingKeysOffTheSameIDAsThePanel() {
        let id = MacChatListView.resolvedCoordinatorID(state: nil, resolved: false, cached: { "coord" })
        XCTAssertEqual(MacChatListView.conversationTarget("coord", coordinatorConvoID: id), .panel)
        XCTAssertFalse(MacChatListView.detailShowsChat("coord", coordinatorConvoID: id, isStaleRestore: false))
    }

    /// The wiring half of the test above: the raw `@State` mirror of the
    /// setting is read in exactly one place — the resolver every consumer
    /// (panel, `showConversation`, `chatCache`, the detail, restores, the
    /// list filter) goes through. Declaration + write + that one read.
    func test_theRawCoordinatorSettingIsReadOnlyThroughTheResolver() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MatronMac/Features/ChatList/MacChatListView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let uses = text.components(separatedBy: .newlines).filter { $0.contains("coordinatorSettingID") }
        XCTAssertEqual(uses.count, 3, uses.joined(separator: "\n"))
    }

    func test_panelHeaderTitle_fallsBackToCoordinator() {
        XCTAssertEqual(MacCoordinatorPanelHeader.title(for: nil), "Coordinator")
        let strip = SubChatStripViewModel(chat: PanelChat(), parentConvoID: "p")
        XCTAssertEqual(MacCoordinatorPanelHeader.title(for: headerProps("Plan the week", strip: strip)), "Plan the week")
    }

    /// Controller ruling (Task 13 review): the window has one header and it
    /// belongs to the main detail. The panel's chat publishes header props
    /// too; they reach the panel's own header and never the window's —
    /// not even while the detail shows no chat (the preference keeps the
    /// first value it sees, which would otherwise be the panel's).
    func test_panelChat_neverTakesTheWindowHeader() async throws {
        let model = ShellModel()
        let captured = Captured()
        let strip = SubChatStripViewModel(chat: PanelChat(), parentConvoID: "p")
        let window = mount(PanelShellHarness(model: model, strip: strip, captured: captured, detailWidth: { _ in }))
        await Self.spin(seconds: 1.5)

        let header = try XCTUnwrap(MacChatHeaderAccessory.existing(in: window))
        XCTAssertEqual(captured.panelProps?.roomID, "coord", "the panel header still gets its chat's props")
        XCTAssertNil(header.model.props, "no chat in the detail: the window header stays empty")

        model.detailHasChat = true
        let shown = await Self.poll(seconds: 5) { header.model.props?.roomID == "main" }
        XCTAssertTrue(shown, "the main chat owns the window header (got \(header.model.props?.roomID ?? "nil"))")
    }

    /// Controller ruling (Task 13 review): the header's trailing inset is
    /// the width the container actually draws — under an overlay that is
    /// the clipped width, not the stored one.
    func test_headerInset_isTheDrawnWidth_underAnOverlay() async throws {
        let model = ShellModel()
        model.panelWidth = 720
        var detail: CGFloat = 0
        let strip = SubChatStripViewModel(chat: PanelChat(), parentConvoID: "p")
        let window = mount(PanelShellHarness(model: model, strip: strip, captured: Captured(),
                                             detailWidth: { detail = $0 }), width: 1100)
        await Self.spin(seconds: 1.5)

        let header = try XCTUnwrap(MacChatHeaderAccessory.existing(in: window))
        XCTAssertGreaterThan(detail, 0)
        XCTAssertLessThan(detail, 720, "the harness must leave the detail column narrower than the stored width")
        XCTAssertEqual(header.model.trailingInset, detail, accuracy: 1,
                       "overlaid, the panel covers the whole detail column — and no more")

        model.panelWidth = 380
        await Self.spin(seconds: 0.5)
        XCTAssertEqual(header.model.trailingInset, 380, accuracy: 0.5)
    }

    /// Focuses `textView` and returns the bus claimant once it settles —
    /// focus is a claim, so this names a composer's id without depending
    /// on mount order.
    private static func claimant(focusing textView: ComposerTextView, in window: NSWindow,
                                 bus: VoiceNoteCommandBus) async -> UUID? {
        window.makeFirstResponder(nil)
        let before = bus.activeComposerID
        _ = window.makeFirstResponder(textView)
        _ = await poll(seconds: 1) { bus.activeComposerID != before }
        await spin(seconds: 0.2)
        return bus.activeComposerID
    }

    /// A window made key, so focus and key equivalents behave as in the app.
    /// `forceKey`: the window reports `isKeyWindow` whether or not the test
    /// host is frontmost (it usually is not under `xcodebuild test`).
    private func mountKey<V: View>(_ view: V, forceKey: Bool = false) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 500)
        let window = forceKey
            ? AlwaysKeyWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        return window
    }

    /// The composers' text views, leftmost (main) first.
    private static func composerTextViews(in window: NSWindow) -> [ComposerTextView] {
        func collect(_ view: NSView) -> [ComposerTextView] {
            (view as? ComposerTextView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        guard let root = window.contentView else { return [] }
        return collect(root).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
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

    private func mount<V: View>(_ view: V, width: CGFloat = 1300) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: 600))
        window.orderFront(nil)
        self.window = window
        return window
    }

    private static func poll(seconds: TimeInterval, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return done()
    }


    /// #2849: the sub-chat pane is a read-only viewer — it has NO composer
    /// (see `MacSubChatPane`), so opening one beside the chat never puts a
    /// second composer in the window and the main composer stays alone:
    /// Return still sends its draft with nothing focused, and the voice
    /// hotkey has one claimant. If a composer is ever added to the pane,
    /// this fails — set `macComposerSoleInWindow` false while it is open,
    /// as `MacChatListView` does for the Coordinator panel.
    func test_subChatPaneOpen_leavesTheMainComposerAloneInTheWindow() async throws {
        let bus = VoiceNoteCommandBus()
        let timeline = PanelTimeline()
        let childTimeline = SubscribedTimeline()
        let chatVM = ChatViewModel(roomID: "main", timeline: timeline, media: PanelMedia())
        let childVM = ChatViewModel(roomID: "child", timeline: childTimeline, media: PanelMedia())
        let composer = ComposerViewModel(roomID: "main", timeline: timeline, commands: [])
        composer.input = "main draft"
        let strip = SubChatStripViewModel(chat: PanelChat(), parentConvoID: "main")
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

    private static func spin(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
#endif
