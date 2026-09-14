import XCTest
import MatronChat
import MatronModels
@testable import Matron

/// Binding-shape coverage for `NewChatSheet`. The full sheet body
/// observes `ChatService.chatSummaries()` to derive the unique-bot list,
/// but here we only need to prove the closure plumbing — `onCreated` runs
/// when invoked and `body` resolves so the @State fields compile clean.
@MainActor
final class NewChatSheetBindingTests: XCTestCase {
    /// Held so `tearDown()` can stop the session's background maintenance
    /// sweeper (M1 — the identical Mac defect fixed in
    /// `MacNewChatSheetBindingTests`: a leaked `JournalMaintenance` 10 s
    /// timer otherwise outlives the test method). See
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
        let sheet = NewChatSheet(deps: deps, session: session) { roomID in
            capturedRoomID = roomID
        }

        // Compile-time check: instantiating the View exercises @State /
        // binding wiring. The body itself isn't rendered in this unit
        // test (no host scene).
        XCTAssertNotNil(sheet.body)

        // Plumbing check — the closure parameter is what the Mac and
        // iOS chat-list sheets use to dismiss + navigate after a room
        // is created.
        sheet.onCreated("!new:server")
        XCTAssertEqual(capturedRoomID, "!new:server")
    }
}
