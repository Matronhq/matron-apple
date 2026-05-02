#if os(macOS)
import XCTest
import MatronChat
import MatronModels
@testable import MatronMac

/// Mac mirror of `MatronTests/NewChatSheetBindingTests`. The Mac sheet
/// has its own `AppDependencies` per-target, so a separate binding test
/// covers the `(deps, session, onCreated)` shape the parent view depends on.
@MainActor
final class MacNewChatSheetBindingTests: XCTestCase {
    func test_view_compiles_andOnCreatedClosure_isInvocable() {
        let deps = AppDependencies()
        let session = UserSession(
            userID: "@a:s", deviceID: "D",
            homeserverURL: URL(string: "https://s")!, accessToken: "t"
        )

        var capturedRoomID: String?
        let sheet = MacNewChatSheet(deps: deps, session: session) { roomID in
            capturedRoomID = roomID
        }

        XCTAssertNotNil(sheet.body)
        sheet.onCreated("!new:server")
        XCTAssertEqual(capturedRoomID, "!new:server")
    }
}
#endif
