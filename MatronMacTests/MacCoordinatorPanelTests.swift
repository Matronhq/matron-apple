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

private final class Captured { var panelProps: MacChatToolbarProps? }

private final class VoiceHarnessModel: ObservableObject {
    @Published var panelOpen = false
}

private struct VoiceHarness: View {
    @ObservedObject var model: VoiceHarnessModel
    let main: MacChatView
    let panel: MacChatView

    var body: some View {
        HStack(spacing: 0) {
            main
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

    override func tearDown() async throws {
        window?.close()
        window = nil
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
        let window = mountKey(HStack(spacing: 0) { main; panel }.frame(width: 1000, height: 500))
        let mounted = await Self.poll(seconds: 5) { Self.composerTextViews(in: window).count == 2 }
        XCTAssertTrue(mounted)
        let views = Self.composerTextViews(in: window)
        let (mainText, panelText) = (views[0], views[1])

        // Neither composer focused: Return is no composer's to take (it
        // used to send the main chat's draft from anywhere in the window).
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

    private static func spin(seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
#endif
