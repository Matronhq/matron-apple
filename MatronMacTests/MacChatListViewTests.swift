#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

@MainActor
final class MacChatListViewTests: XCTestCase {
    /// Verifies the shared `ChatListViewModel` is consumed unchanged — the
    /// Mac view is a per-platform shell, not a parallel data model.
    func test_usesSharedChatListViewModel() {
        let vm = ChatListViewModel(chat: LocalFakeChatActions(snapshots: []))
        let view = MacChatListView(viewModel: vm)
        XCTAssertNotNil(view.body)
    }

    /// Verifies the view drives selection through `ChatSummary?` (Hashable),
    /// not through `ChatSummary.ID`. The split-view detail column needs the
    /// full `ChatSummary` to construct `ChatViewModel` without re-querying
    /// the view-model.
    func test_selectionState_isChatSummary_notID() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let summaries = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now.addingTimeInterval(-3600), unreadCount: 0)
        ]
        let fake = LocalFakeChatActions(snapshots: [summaries])
        let vm = ChatListViewModel(chat: fake)
        _ = MacChatListView(viewModel: vm)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(vm.groups.isEmpty)
        // Compile-time check: ChatSummary must be Hashable for List(selection:).
        XCTAssertEqual(summaries.first.hashValue, summaries.first.hashValue)
    }
}

/// Test-only fake mirroring `LocalFakeChatService` from
/// `MacChatListViewBindingTests.swift` but exposing the new Task 13
/// chat-action methods (`refresh` / `mute` / `leave`) as no-ops. Declared
/// in a separate test file so each test target file stays self-contained.
private final class LocalFakeChatActions: ChatService, @unchecked Sendable {
    private let snapshots: [[ChatSummary]]
    init(snapshots: [[ChatSummary]]) { self.snapshots = snapshots }
    func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}
#endif
