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
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
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

    /// Structural-identity pin (Dan's 2026-08-07 report: a chat showed one
    /// room's title over another room's timeline). `MatronApp.openChat`
    /// REPLACES the navigation path (`[A]` → `[B]`, the 2026-08-06
    /// back-button change), so the pushed destination keeps its structural
    /// position across a chat switch. Without an explicit `.id(id)` on the
    /// top-level `ChatView`, SwiftUI reuses the previous instance's
    /// `@State` (`viewModel`, `composerVM`, `stripViewModel` — still chat
    /// A's) while the plain-`let` `chatTitle` updates to chat B: B's title
    /// over A's messages. The `SubChatView` branch and the Mac panes carry
    /// the same key (f3eb091).
    ///
    /// The `ChatView` branch is unreachable from a unit test (it's gated
    /// on `@Environment` deps that only resolve inside a live hierarchy)
    /// and SwiftUI exposes no runtime probe for structural identity, so
    /// this pins the source contract instead: the `ChatView` construction
    /// inside `chatDestination` must carry `.id(id)`.
    func test_chatDestination_keysTopLevelChatViewIdentityToRoomID() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MatronTests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Matron/Features/ChatList/ChatListView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        guard let funcStart = source.range(of: "func chatDestination(") else {
            return XCTFail("chatDestination(for:) not found — move this pin alongside any rename")
        }
        let body = String(source[funcStart.upperBound...])

        // The top-level branch is the `ChatView(` construction that is NOT
        // the `SubChatView(` one.
        let topLevel = try NSRegularExpression(pattern: "(?<!Sub)ChatView\\(")
        let matches = topLevel.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard let match = matches.last, let start = Range(match.range, in: body) else {
            return XCTFail("top-level ChatView construction not found in chatDestination")
        }
        let branch = String(body[start.lowerBound...])
        // Scope the assertion to this branch (up to the destination's
        // else) so an `.id` elsewhere in the file can't satisfy the pin.
        let scoped = branch.range(of: "} else {").map { String(branch[..<$0.lowerBound]) } ?? branch
        XCTAssertTrue(
            scoped.contains(".id(id)"),
            """
            The top-level ChatView in chatDestination(for:) must be keyed \
            with .id(id): openChat replaces the path tail in place, and an \
            unkeyed destination keeps the previous chat's @State view models \
            under the new chat's title.
            """
        )
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
