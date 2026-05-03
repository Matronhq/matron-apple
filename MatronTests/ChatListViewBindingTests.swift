import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import Matron

/// Local fake mirroring `LocalFakeChatActions` from `MatronMacTests` —
/// each test target file is self-contained so the iOS chat-list test
/// reuses the same shape without cross-target imports.
private final class FakeChatActionsForList: ChatService, @unchecked Sendable {
    private let snapshots: [[ChatSummary]]
    init(snapshots: [[ChatSummary]]) { self.snapshots = snapshots }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { continuation in
            for s in snapshots { continuation.yield(s) }
            continuation.finish()
        }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor
final class ChatListViewBindingTests: XCTestCase {

    /// Bugbot finding: `NavigationLink(value: summary)` passed the full
    /// `ChatSummary` struct, so the destination column received a snapshot
    /// frozen at navigation time. `ChatSummary` auto-synthesises
    /// `Hashable` from *all* stored properties — including `lastActivity`
    /// and `unreadCount` — so when the underlying snapshot updated those
    /// fields the destination kept the stale struct. The fix navigates
    /// by `summary.id` (a stable `String`) and looks up the current
    /// `ChatSummary` from `viewModel.groups` via `currentSummary(for:)`.
    /// Mirrors the round-3 `MacChatListView` fix.
    ///
    /// This test pins the lookup contract: after two snapshots arrive
    /// with the same id but different fields, `currentSummary(for: id)`
    /// must return the *latest* snapshot's value.
    func test_currentSummary_resolvesLatestSnapshot_acrossUpdates() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let initial = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now.addingTimeInterval(-3600), unreadCount: 0)
        ]
        // Same id, but `lastActivity` and `unreadCount` updated — the
        // exact diff shape that broke struct-keyed navigation.
        let updated = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now, unreadCount: 7)
        ]
        let fake = FakeChatActionsForList(snapshots: [initial, updated])
        let vm = ChatListViewModel(chat: fake)
        let view = ChatListView(viewModel: vm)

        vm.start()
        // Drain both snapshots. The fake's stream finishes after yielding
        // both, so a short bounded wait is enough to observe the second
        // snapshot land on the @MainActor.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(vm.groups.isEmpty)
        let resolved = view.currentSummary(for: "!1:s")
        XCTAssertNotNil(resolved, "lookup must succeed for a live id")
        XCTAssertEqual(resolved?.unreadCount, 7,
                       "destination must see the latest snapshot's fields, not the one frozen at navigation time")
    }

    /// Lookup returns nil when the room has been removed from the latest
    /// snapshot (e.g. user left from another device). The destination
    /// gracefully renders the same `Session unavailable` placeholder as
    /// the missing-environment branch.
    func test_currentSummary_returnsNil_whenRoomIsGone() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let initial = [
            ChatSummary(id: "!1:s", title: "First", bot: bot, lastActivity: .now, unreadCount: 0)
        ]
        // Second snapshot drops the room entirely.
        let withoutRoom: [ChatSummary] = []
        let fake = FakeChatActionsForList(snapshots: [initial, withoutRoom])
        let vm = ChatListViewModel(chat: fake)
        let view = ChatListView(viewModel: vm)

        vm.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(view.currentSummary(for: "!1:s"),
                     "lookup must return nil for a room removed from the latest snapshot")
    }

    /// The destination view-builder doesn't crash when called with an
    /// id whose room has been removed from the snapshot. Renders the
    /// `Session unavailable`-style placeholder via the `else` branch.
    func test_chatDestination_handlesMissingRoom_withoutCrashing() async throws {
        let fake = FakeChatActionsForList(snapshots: [[]])
        let vm = ChatListViewModel(chat: fake)
        let view = ChatListView(viewModel: vm)
        vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        // The body resolves even when the lookup returns nil — the
        // ViewBuilder branch falls through to the placeholder.
        let _ = view.chatDestination(for: "!ghost:s")
    }
}
