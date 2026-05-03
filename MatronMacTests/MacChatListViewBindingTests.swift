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
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(vm.groups.isEmpty)
        XCTAssertEqual(vm.groups.first?.summaries.first?.title, "First chat")
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
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}
