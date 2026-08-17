#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Inert `ChatService` stub — the toolbar tests only need a strip VM to
/// exist; its observation is never started.
private final class FakeChatForToolbar: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor
final class MacChatToolbarTests: XCTestCase {

    private func makeStripVM() -> SubChatStripViewModel {
        SubChatStripViewModel(chat: FakeChatForToolbar(), parentConvoID: "p1")
    }

    func testToolbarCarriesTitleAndStatus() {
        let status = SessionStatus(
            model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27),
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: nil, resetsAt: nil)])
        let toolbar = MacChatToolbar(
            title: "Chat", status: status,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertEqual(toolbar.title, "Chat")
        XCTAssertEqual(toolbar.status?.context?.pct, 27)
        XCTAssertEqual(toolbar.status?.limits?.count, 1)

        // Nil status is valid — header renders the title alone.
        XCTAssertNil(MacChatToolbar(
            title: "Chat", status: nil,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {}).status)
    }

    /// The under-title line joins the home-abbreviated workdir and the
    /// account email with a middle dot; either alone stands by itself, and
    /// with neither the line disappears (nil, not an empty Text).
    func testTitleSubtitleJoinsWorkdirAndEmail() {
        func toolbar(workdir: String? = nil, email: String? = nil) -> MacChatToolbar {
            MacChatToolbar(
                title: "Chat",
                status: SessionStatus(email: email, workdir: workdir),
                stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        }
        XCTAssertEqual(
            toolbar(workdir: "/Users/dan/Dev/matron-bridge", email: "dan@example.com").titleSubtitle,
            "~/Dev/matron-bridge · dan@example.com")
        XCTAssertEqual(toolbar(workdir: "/opt/matron").titleSubtitle, "/opt/matron")
        XCTAssertEqual(toolbar(email: "dan@example.com").titleSubtitle, "dan@example.com")
        XCTAssertNil(toolbar().titleSubtitle)
    }


    /// The title cluster's tap target is a real binding, not a fire-and-
    /// forget closure — flipping `showSummaries.wrappedValue` on the
    /// struct must reach back to the caller's `@State` through the
    /// binding, the same way `MacChatView` wires it to its popover.
    func testToolbarCarriesSummariesBinding() {
        let status = SessionStatus(model: "claude-fable-5")
        var shown = false
        let toolbar = MacChatToolbar(
            title: "Chat", status: status,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {},
            showSummaries: Binding(get: { shown }, set: { shown = $0 }))
        XCTAssertFalse(toolbar.showSummaries.wrappedValue)
        toolbar.showSummaries.wrappedValue = true
        XCTAssertTrue(shown)
    }

    /// The sidebar-toggle button posts `.toggleSidebar` on the command
    /// bus. The toolbar tests the listener side; Task 14e tests the
    /// menu-bar `Button("Toggle Sidebar")` poster side. Verifying the
    /// `Notification.Name` exists and is distinct keeps the contract
    /// explicit before the menu item lands.
    func test_toggleSidebarNotificationName_isWired() {
        let name = Notification.Name.matronCommand(.toggleSidebar)
        XCTAssertEqual(name.rawValue, "chat.matron.command.toggleSidebar")
    }

    /// The box name leads the subtitle — "which machine am I talking to"
    /// outranks the path and the account. Nil (fewer than two boxes) leaves
    /// the line exactly as it was.
    func testTitleSubtitleLeadsWithTheBoxName() {
        let toolbar = MacChatToolbar(
            title: "Fix the parser", boxName: "dev-y",
            status: SessionStatus(email: "dan@example.com", workdir: "/Users/dan/proj"),
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertEqual(toolbar.titleSubtitle, "dev-y · ~/proj · dan@example.com")

        let boxOnly = MacChatToolbar(
            title: "Fix the parser", boxName: "dev-y", status: nil,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertEqual(boxOnly.titleSubtitle, "dev-y")

        let none = MacChatToolbar(
            title: "Fix the parser", boxName: nil, status: nil,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertNil(none.titleSubtitle)
    }
}
#endif
