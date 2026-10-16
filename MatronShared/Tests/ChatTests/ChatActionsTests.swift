import XCTest
@testable import MatronChat
@testable import MatronModels

/// Drives the chat-list actions that Task 13 added to the `ChatService`
/// protocol — `refresh()`, `mute(roomID:)`, `setArchived(_:archived:)` —
/// against the existing `FakeChatServiceForCreate` actor fake (extended
/// with `refreshCalls`, `mutedRooms`, `archivedRooms`).
///
/// Pinning the call to `any ChatService` ensures regressions of the
/// protocol surface (renames, accidental method removal) are caught here
/// rather than only at the live impl call sites.
final class ChatActionsTests: XCTestCase {
    func test_refresh_recordsCall() async throws {
        let fake = FakeChatServiceForCreate()
        let service: any ChatService = fake
        try await service.refresh()
        let calls = await fake.refreshCalls
        XCTAssertEqual(calls, 1)
    }

    func test_mute_recordsRoomID() async throws {
        let fake = FakeChatServiceForCreate()
        let service: any ChatService = fake
        try await service.mute(roomID: "!a:s")
        let muted = await fake.mutedRooms
        XCTAssertEqual(muted, ["!a:s"])
    }

    func test_setArchived_reachesTheServiceThroughTheProtocol() async throws {
        let fake = FakeChatServiceForCreate()
        let service: any ChatService = fake
        await service.setArchived(["!a:s", "!b:s"], archived: true)
        await service.setArchived(["!a:s"], archived: false)
        let archived = await fake.archivedRooms
        XCTAssertEqual(archived, ["!b:s"])
    }


    func test_refresh_isCounted_acrossMultipleCalls() async throws {
        let fake = FakeChatServiceForCreate()
        let service: any ChatService = fake
        try await service.refresh()
        try await service.refresh()
        try await service.refresh()
        let calls = await fake.refreshCalls
        XCTAssertEqual(calls, 3)
    }
}
