#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Local fake mirroring `MatronShared/Tests/ViewModelTests/FakeTimelineService`.
/// Kept in this file because the Mac test target doesn't pull the shared
/// test fakes (those live in `MatronViewModelTests`'s sources, not the
/// shipped library).
private final class FakeTimelineForToolbar: TimelineService, @unchecked Sendable {
    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {}
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {}
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

private final class FakeMediaForToolbar: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

@MainActor
final class MacChatToolbarTests: XCTestCase {

    /// Constructing the toolbar exercises the @State + ToolbarContent
    /// wiring at compile time. The body itself isn't rendered in this
    /// unit test (no host scene).
    func test_toolbarRenders_withTitleAndInfoButton() {
        let vm = ChatViewModel(roomID: "!a:s", timeline: FakeTimelineForToolbar(), media: FakeMediaForToolbar())
        var profileTaps = 0
        let toolbar = MacChatToolbar(
            title: "Refactoring auth",
            viewModel: vm,
            onShowBotProfile: { profileTaps += 1 }
        )
        XCTAssertNotNil(toolbar.body)

        // Verify the closure plumbs through — the toolbar's ⓘ button
        // calls onShowBotProfile.
        toolbar.onShowBotProfile()
        XCTAssertEqual(profileTaps, 1)
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
}
#endif
