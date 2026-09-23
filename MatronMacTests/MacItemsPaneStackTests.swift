#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class RowsTimeline: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield((1...3).map {
                TimelineItem(id: "\($0)", sender: "agent:box", timestamp: Date(timeIntervalSince1970: Double($0)),
                             kind: .text(body: "row \($0)", formattedHTML: nil), isOwn: false)
            })
        }
    }
    func sendText(_ body: String, inReplyTo: String?) async throws {}
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { true }
    func markAsRead() async throws {}
}

private final class NoMedia: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

private final class NoChat: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor @Observable
private final class RouteBox {
    var route: MacChatPaneRoute?
    init(_ route: MacChatPaneRoute?) { self.route = route }
}

/// #2608: an item opened in the Tasks pane replaced the WHOLE detail column
/// of the window's `NavigationSplitView` — chat, composer and header gone, a
/// system Back in the toolbar — because SwiftUI pushed the pane's
/// `NavigationStack` destinations onto the column's own stack. The same push
/// outside a `NavigationSplitView` stayed in the pane. App-shaped on purpose:
/// Coordinator's 72 pt sidebar, the header host, the real `MacChatView`.
@MainActor
final class MacItemsPaneStackTests: XCTestCase {
    private var deps: AppDependencies!
    private var window: NSWindow?
    private var paneState: MacItemsPaneState?

    override func tearDown() async throws {
        window?.close()
        window = nil
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    func test_pushOntoAnOpenPane_staysInThePane() async throws {
        let box = RouteBox(nil)
        await mount(box)
        box.route = .items(path: [])
        await Self.spin(seconds: 1)
        box.route = .items(path: ["it_probe"])
        await Self.spin(seconds: 2)
        assertChatStillBesideThePane(pushed: "it_probe")
    }

    /// The Back/Forward restore of a pushed item, and a tracker link tapped
    /// with the pane closed: the pane mounts with the item already pushed.
    func test_mountWithAPushedItem_staysInThePane() async throws {
        let box = RouteBox(.items(path: ["it_probe"]))
        await mount(box)
        assertChatStillBesideThePane(pushed: "it_probe")
    }

    private func assertChatStillBesideThePane(pushed: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let window else { return XCTFail("no window", file: file, line: line) }
        XCTAssertTrue(Self.contains(ComposerTextView.self, in: window.contentView),
                      "the chat column (and its composer) must stay beside the pane", file: file, line: line)
        let header = MacChatHeaderAccessory.existing(in: window)
        XCTAssertEqual(header?.isHidden, false, "the chat header must stay up", file: file, line: line)
        XCTAssertEqual(header?.model.props?.roomID, "k", file: file, line: line)
        // The pane's own Back exists only while an item is pushed, so its
        // presence proves the item is showing in the pane (CodeRabbit, #233).
        // The pushed item's detail host is mounted on top of the pane: its
        // `.task` activated the item's slot (CodeRabbit, #233).
        XCTAssertNotNil(paneState?.slots[pushed], "the pane must show the pushed item", file: file, line: line)
        let toolbarIDs = (window.toolbar?.items ?? []).map(\.itemIdentifier.rawValue)
        XCTAssertFalse(toolbarIDs.contains { $0.contains("navigationStack.back") },
                       "no system Back may reach the toolbar: \(toolbarIDs)", file: file, line: line)
    }

    private func mount(_ box: RouteBox) async {
        deps = AppDependencies()
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        let timeline = RowsTimeline()
        let chatVM = ChatViewModel(roomID: "k", timeline: timeline, media: NoMedia())
        let composerVM = ComposerViewModel(roomID: "k", timeline: timeline, commands: [])
        let strip = SubChatStripViewModel(chat: NoChat(), parentConvoID: "k")
        let paneState = MacItemsPaneState()
        self.paneState = paneState
        let root = NavigationSplitView {
            List { Text("nav") }
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 72, ideal: 72, max: 72)
        } detail: {
            MacChatHeaderHost {
                MacChatView(viewModel: chatVM, composerVM: composerVM, stripViewModel: strip,
                            subChatProvider: { _ in (chatVM, strip) },
                            paneRoute: Binding(get: { box.route }, set: { box.route = $0 }),
                            itemsPaneState: paneState, chatTitle: "Coordinator")
            }
        }
        .environment(\.appDependencies, deps)
        .environment(\.currentSession, session)

        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        self.window = window
        await Self.spin(seconds: 2)
    }

    private static func contains<T: NSView>(_ type: T.Type, in view: NSView?) -> Bool {
        guard let view else { return false }
        if view is T { return true }
        return view.subviews.contains { contains(type, in: $0) }
    }

    private static func spin(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
#endif
