#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

@MainActor
final class MacBotProfileSheetTests: XCTestCase {

    /// Mac sheet should reuse the shared `BotProfileViewModel` unchanged —
    /// no Mac-specific data model. Constructing the sheet exercises the
    /// SwiftUI body composition at compile time.
    func test_usesSharedViewModel() {
        let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let summaries: [ChatSummary] = []
        let vm = BotProfileViewModel(bot: bot, allSummaries: summaries)
        let sheet = MacBotProfileSheet(
            viewModel: vm,
            onSelectChat: { _ in },
            onStartNewChat: {},
            onDismiss: {}
        )
        XCTAssertNotNil(sheet.body)
    }

    /// All four callbacks plumb through to their respective Buttons. We
    /// invoke them directly so the test doesn't depend on rendering the
    /// SwiftUI hierarchy.
    func test_callbacks_areInvokedAsClosures() {
        let bot = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let now = Date(timeIntervalSince1970: 1745000000)
        let summary = ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: now, unreadCount: 0)
        let vm = BotProfileViewModel(bot: bot, allSummaries: [summary])

        var selectCount = 0
        var newChatCount = 0
        var dismissCount = 0
        let sheet = MacBotProfileSheet(
            viewModel: vm,
            onSelectChat: { _ in selectCount += 1 },
            onStartNewChat: { newChatCount += 1 },
            onDismiss: { dismissCount += 1 }
        )
        sheet.onSelectChat(summary)
        sheet.onStartNewChat()
        sheet.onDismiss()
        XCTAssertEqual(selectCount, 1)
        XCTAssertEqual(newChatCount, 1)
        XCTAssertEqual(dismissCount, 1)

        // The shared view-model surface — bot + filtered chats — is the
        // contract the Mac sheet renders. Verify the filtered list is
        // accessible without poking SwiftUI internals.
        XCTAssertEqual(vm.bot.matrixID, "@claude:s")
        XCTAssertEqual(vm.chatsForBot.map(\.id), ["!a:s"])
    }
}
#endif
