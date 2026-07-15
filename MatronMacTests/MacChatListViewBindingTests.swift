import XCTest
import MatronChat
import MatronModels
import MatronViewModels
@testable import MatronMac

final class MacChatListViewBindingTests: XCTestCase {

    @MainActor
    func test_view_observesViewModelGroups_afterStreamYield() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let summaries = [
            ChatSummary(id: "!1:s", title: "First chat", bot: bot,
                        lastActivity: .now.addingTimeInterval(-3600), unreadCount: 0)
        ]
        let fake = LocalFakeChatService(snapshots: [summaries])
        let vm = ChatListViewModel(chat: fake)

        let _ = MacChatListView(viewModel: vm)

        vm.start()
        // Same de-flake shape as MacChatListViewTests.waitUntil (session
        // 12): a fixed 50ms sleep raced the stream's first yield under
        // suite load — passed alone, failed in the full bundle. Poll
        // exits the moment the snapshot lands; the 2s ceiling only
        // burns on a real stall.
        await waitUntil(timeout: 2.0) { !vm.groups.isEmpty }

        XCTAssertFalse(vm.groups.isEmpty)
        XCTAssertEqual(vm.groups.first?.summaries.first?.title, "First chat")
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private final class LocalFakeChatService: ChatService, @unchecked Sendable {
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
