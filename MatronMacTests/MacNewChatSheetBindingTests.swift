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
    /// Held so `tearDown()` can stop the session's background maintenance
    /// sweeper (review Major: a leaked `JournalMaintenance` 10 s timer
    /// otherwise outlives the test method and can fire against the shared
    /// `MATRON_APP_SUPPORT_OVERRIDE` directory after a later test deletes
    /// or recreates the store there). See
    /// `AppDependencies.stopMaintenanceForTests()`.
    private var deps: AppDependencies!

    override func tearDown() async throws {
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    func test_view_compiles_andOnCreatedClosure_isInvocable() {
        deps = AppDependencies()
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
