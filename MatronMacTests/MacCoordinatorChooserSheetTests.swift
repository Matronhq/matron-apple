#if os(macOS)
import XCTest
import MatronChat
import MatronModels
@testable import MatronMac

/// App shell (spec §5b), Mac chooser: same filter contract as iOS and an
/// invocable `onPick`.
@MainActor
final class MacCoordinatorChooserSheetTests: XCTestCase {
    func test_filter_matchesTitle_caseInsensitively() {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let chats = [
            ChatSummary(id: "!1:s", title: "Auth refactor", bot: bot, lastActivity: .now, unreadCount: 0),
            ChatSummary(id: "!2:s", title: "Release notes", bot: bot, lastActivity: .now, unreadCount: 0),
        ]
        XCTAssertEqual(MacCoordinatorChooserSheet.filtered(chats, query: "").count, 2)
        XCTAssertEqual(MacCoordinatorChooserSheet.filtered(chats, query: "release").map(\.id), ["!2:s"])
    }

    func test_onPick_isInvocable() {
        let deps = AppDependencies()
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        var picked: String?
        let sheet = MacCoordinatorChooserSheet(deps: deps, session: session) { picked = $0 }
        XCTAssertNotNil(sheet.body)
        sheet.onPick("!2:s")
        XCTAssertEqual(picked, "!2:s")
    }
}
#endif
