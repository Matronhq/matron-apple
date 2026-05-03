import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Tests for the cross-platform `BotProfileViewModel`, which is consumed by
/// both `BotProfileView` (iOS, Task 15) and `MacBotProfileSheet` (Mac, Task
/// 15b). The view-model is purely a derivation over a snapshot of
/// `[ChatSummary]`, so these tests cover filtering + sort order without
/// touching `ChatService`.
final class BotProfileViewModelTests: XCTestCase {
    @MainActor
    func test_filtersChatsByBotID_andSortsByRecencyDescending() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let linear = BotIdentity(matrixID: "@linear:s", displayName: "Linear", avatarURL: nil)
        let now = Date(timeIntervalSince1970: 1745000000)
        let summaries: [ChatSummary] = [
            // Mixed bots so we can prove the filter discards "linear".
            ChatSummary(id: "!a:s", title: "A", bot: claude, lastActivity: now,                              unreadCount: 0),
            ChatSummary(id: "!b:s", title: "B", bot: linear, lastActivity: now,                              unreadCount: 0),
            // Older claude chat — should sort *after* "!a:s".
            ChatSummary(id: "!c:s", title: "C", bot: claude, lastActivity: now.addingTimeInterval(-86_400), unreadCount: 0),
        ]
        let vm = BotProfileViewModel(bot: claude, allSummaries: summaries)
        XCTAssertEqual(vm.chatsForBot.map(\.id), ["!a:s", "!c:s"])
    }

    @MainActor
    func test_sortsChatsWithoutLastActivity_byTitleAsTiebreaker() {
        // Mirrors `ChatListViewModel.byRecencyDescending`'s contract — chats
        // without lastActivity sort by title so the order is deterministic.
        let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let summaries: [ChatSummary] = [
            ChatSummary(id: "!z:s", title: "Zebra", bot: bot, lastActivity: nil, unreadCount: 0),
            ChatSummary(id: "!a:s", title: "Apple", bot: bot, lastActivity: nil, unreadCount: 0),
        ]
        let vm = BotProfileViewModel(bot: bot, allSummaries: summaries)
        XCTAssertEqual(vm.chatsForBot.map(\.id), ["!a:s", "!z:s"])
    }

    @MainActor
    func test_chatsWithKnownActivity_sortAheadOfNilActivity() {
        let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let now = Date(timeIntervalSince1970: 1745000000)
        let summaries: [ChatSummary] = [
            ChatSummary(id: "!nil:s", title: "Pending hydration", bot: bot, lastActivity: nil, unreadCount: 0),
            ChatSummary(id: "!hot:s", title: "Hydrated",          bot: bot, lastActivity: now, unreadCount: 0),
        ]
        let vm = BotProfileViewModel(bot: bot, allSummaries: summaries)
        XCTAssertEqual(vm.chatsForBot.map(\.id), ["!hot:s", "!nil:s"])
    }

    @MainActor
    func test_emptyResult_whenNoChatsMatchBot() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let linear = BotIdentity(matrixID: "@linear:s", displayName: "Linear", avatarURL: nil)
        let now = Date()
        let summaries: [ChatSummary] = [
            ChatSummary(id: "!b:s", title: "B", bot: linear, lastActivity: now, unreadCount: 0),
        ]
        let vm = BotProfileViewModel(bot: claude, allSummaries: summaries)
        XCTAssertTrue(vm.chatsForBot.isEmpty)
    }
}
