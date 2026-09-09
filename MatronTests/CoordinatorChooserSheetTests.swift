import XCTest
import MatronChat
import MatronModels
@testable import Matron

/// App shell (spec §5b): the chooser lists the user's conversations with
/// a search box on top and hands the picked id back through `onPick`.
@MainActor
final class CoordinatorChooserSheetTests: XCTestCase {
    private let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)

    func test_filter_matchesTitleCaseInsensitively_andEmptyQueryKeepsAll() {
        let chats = [
            ChatSummary(id: "!1:s", title: "Auth refactor", bot: bot, lastActivity: .now, unreadCount: 0),
            ChatSummary(id: "!2:s", title: "Release notes", bot: bot, lastActivity: .now, unreadCount: 0),
        ]
        XCTAssertEqual(CoordinatorChooserSheet.filtered(chats, query: "").map(\.id), ["!1:s", "!2:s"])
        XCTAssertEqual(CoordinatorChooserSheet.filtered(chats, query: "  AUTH ").map(\.id), ["!1:s"])
        XCTAssertTrue(CoordinatorChooserSheet.filtered(chats, query: "zzz").isEmpty)
    }

    func test_onPick_isInvocable() {
        let deps = AppDependencies()
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        var picked: String?
        let sheet = CoordinatorChooserSheet(deps: deps, session: session) { picked = $0 }
        XCTAssertNotNil(sheet.body)
        sheet.onPick("!1:s")
        XCTAssertEqual(picked, "!1:s")
    }
}
