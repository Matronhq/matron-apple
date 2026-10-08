import XCTest
@testable import MatronChat
@testable import MatronModels

/// Drives the chat-list actions that Task 13 added to the `ChatService`
/// protocol — `refresh()`, `mute(roomID:)`, `leave(roomID:)` — against the
/// existing `FakeChatServiceForCreate` actor fake (now extended with
/// `refreshCalls`, `mutedRooms`, `leftRooms`).
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

    func test_leave_recordsRoomID() async throws {
        let fake = FakeChatServiceForCreate()
        let service: any ChatService = fake
        try await service.leave(roomID: "!a:s")
        let left = await fake.leftRooms
        XCTAssertEqual(left, ["!a:s"])
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
