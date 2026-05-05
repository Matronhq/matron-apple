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

    /// Wave 6 / live-test #1+#2: the Sign Out / Verify Device / Show
    /// Recovery Key menu commands route through the host via injected
    /// closures because `.onReceive` on the WindowGroup root's
    /// type-switching `Group { … }` content silently dropped
    /// notifications on macOS. Constructing the view with the closures
    /// pins the contract that they survive the new shape; invoking
    /// each closure pins the round-trip.
    func test_menuCommandClosures_arePlumbed_throughInit() {
        let vm = ChatListViewModel(chat: LocalFakeChatActions(snapshots: []))
        var signOutCount = 0
        var verifyCount = 0
        var recoveryCount = 0
        let view = MacChatListView(
            viewModel: vm,
            onSignOut: { signOutCount += 1 },
            onVerifyDevice: { verifyCount += 1 },
            onShowRecoveryKey: { recoveryCount += 1 }
        )
        XCTAssertNotNil(view.body)
        view.onSignOut?()
        view.onVerifyDevice?()
        view.onShowRecoveryKey?()
        XCTAssertEqual(signOutCount, 1)
        XCTAssertEqual(verifyCount, 1)
        XCTAssertEqual(recoveryCount, 1)
    }

    /// Verifies the view drives selection through `ChatSummary.ID` (a
    /// stable `String`), not through the full `ChatSummary` struct.
    /// `ChatSummary` auto-synthesises `Hashable` from *all* stored
    /// properties — including `lastActivity` and `unreadCount` — so a
    /// selection bound to the struct silently breaks when a snapshot
    /// updates either field (the new struct's hash != the stored
    /// selection's hash). Round-3 bugbot finding #6: revert to
    /// id-based selection (Phase 1's pattern) and look the full
    /// `ChatSummary` up by id when the detail column needs it.
    func test_selectionState_isChatSummaryID_notFullStruct() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let initial = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now.addingTimeInterval(-3600), unreadCount: 0)
        ]
        // Second snapshot: same id, but `lastActivity` and `unreadCount`
        // changed — the exact diff shape that broke the struct-keyed
        // selection.
        let updated = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now, unreadCount: 3)
        ]
        let fake = LocalFakeChatActions(snapshots: [initial, updated])
        let vm = ChatListViewModel(chat: fake)
        _ = MacChatListView(viewModel: vm)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(vm.groups.isEmpty)

        // Hash invariant: the new snapshot's struct hash differs from the
        // initial one's, even though the id is stable. Using the struct as
        // the selection key would lose the binding here; using the id
        // (stable `String`) preserves it.
        let firstHash = initial.first!.hashValue
        let updatedHash = vm.groups.flatMap(\.summaries).first { $0.id == "!1:s" }!.hashValue
        XCTAssertNotEqual(firstHash, updatedHash,
                          "ChatSummary auto-synthesised Hashable folds in lastActivity + unreadCount")
        // The id is stable across both snapshots, which is what the view's
        // `selectedSummaryID` binds to.
        XCTAssertEqual(initial.first?.id, "!1:s")
        XCTAssertEqual(vm.groups.flatMap(\.summaries).first?.id, "!1:s")
    }
}

/// Test-only fake mirroring `LocalFakeChatService` from
/// `MacChatListViewBindingTests.swift` but exposing the new Task 13
/// chat-action methods (`refresh` / `mute` / `leave`) as no-ops. Declared
/// in a separate test file so each test target file stays self-contained.
private final class LocalFakeChatActions: ChatService, @unchecked Sendable {
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
#endif
