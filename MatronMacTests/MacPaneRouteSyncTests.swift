#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

private final class EmptyTimeline: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> { AsyncThrowingStream { _ in } }
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

/// Stands in for `MacChatListView`: owns the window's route and hands
/// each chat a binding through `MacOwnedPaneRoute.route(for:)`, logging
/// every write a chat makes.
@MainActor @Observable
private final class RouteShell {
    var convoID: String
    var owned: MacOwnedPaneRoute
    var writes: [(owner: String, route: MacChatPaneRoute?)] = []

    init(convoID: String, owned: MacOwnedPaneRoute) {
        self.convoID = convoID
        self.owned = owned
    }

    func binding(for id: String) -> Binding<MacChatPaneRoute?> {
        Binding(
            get: { self.owned.route(for: id) },
            set: { route in
                self.writes.append((id, route))
                let next = MacOwnedPaneRoute(owner: id, route: route)
                if self.owned != next { self.owned = next }
            }
        )
    }
}

private struct RouteHarness: View {
    let shell: RouteShell

    var body: some View {
        let id = shell.convoID
        let timeline = EmptyTimeline()
        MacChatView(
            viewModel: ChatViewModel(roomID: id, timeline: timeline, media: NoMedia()),
            composerVM: ComposerViewModel(roomID: id, timeline: timeline, commands: []),
            stripViewModel: SubChatStripViewModel(chat: NoChat(), parentConvoID: id),
            subChatProvider: { child in
                (ChatViewModel(roomID: child, timeline: timeline, media: NoMedia()),
                 SubChatStripViewModel(chat: NoChat(), parentConvoID: child))
            },
            paneRoute: shell.binding(for: id), chatTitle: "Chat \(id)")
        .id(id)
    }
}

/// PR #233 review C1: the chat view's local pane states and the window's
/// route binding must agree after a conversation switch and after a
/// restore. Mounted for real, because the bug was in how the two
/// `onChange`s interleave, which the pure helpers can't show. No session
/// is in the environment, so the pane's content never mounts. The sync
/// still runs, and that's what's under test.
@MainActor
final class MacPaneRouteSyncTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    func test_switch_withAPushedItem_newChatShowsTheListAndNeverWritesTheOldItem() async {
        let shell = RouteShell(convoID: "c1", owned: MacOwnedPaneRoute(owner: "c1", route: .items(path: ["it_9"])))
        await mount(shell)
        XCTAssertEqual(shell.owned, MacOwnedPaneRoute(owner: "c1", route: .items(path: ["it_9"])),
                       "a mount applies the route it's handed without rewriting it")

        shell.convoID = "c2"
        await Self.spin(seconds: 1)

        XCTAssertEqual(shell.owned.route(for: "c2"), .items(path: []))
        XCTAssertFalse(shell.writes.contains { $0.owner == "c2" && $0.route != .items(path: []) },
                       "c2 wrote \(shell.writes): the old chat's item leaked into the new chat")
    }

    func test_switch_withASubChat_newChatNeverOpensIt() async {
        let shell = RouteShell(convoID: "c1", owned: MacOwnedPaneRoute(owner: "c1", route: .subChat(id: "s1")))
        await mount(shell)

        shell.convoID = "c2"
        await Self.spin(seconds: 1)

        XCTAssertNil(shell.owned.route(for: "c2"))
        XCTAssertFalse(shell.writes.contains { $0.owner == "c2" && $0.route != nil },
                       "c2 wrote \(shell.writes): the old chat's sub-chat leaked into the new chat")
    }

    /// A Back/Forward restore onto the mounted chat lands and stays: the
    /// chat never writes a different route back over it.
    func test_restore_ontoTheMountedChat_isNotOverwritten() async {
        let shell = RouteShell(convoID: "c1", owned: MacOwnedPaneRoute(owner: "c1", route: nil))
        await mount(shell)

        for restored: MacChatPaneRoute? in [.items(path: ["it_9", "it_12"]), .subChat(id: "s1"), .items(path: []), nil] {
            shell.writes.removeAll()
            shell.owned = MacOwnedPaneRoute(owner: "c1", route: restored)
            await Self.spin(seconds: 0.5)
            XCTAssertEqual(shell.owned.route, restored, "writes after restoring \(String(describing: restored)): \(shell.writes)")
            XCTAssertFalse(shell.writes.contains { $0.route != restored },
                           "the chat wrote \(shell.writes) over the restored \(String(describing: restored))")
        }
    }

    private func mount(_ shell: RouteShell) async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: RouteHarness(shell: shell))
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.orderFront(nil)
        self.window = window
        await Self.spin(seconds: 1)
    }

    private static func spin(seconds: Double) async {
        for _ in 0..<Int(seconds / 0.05) {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
#endif
