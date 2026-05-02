import XCTest
@testable import MatronChat
@testable import MatronModels

final class FakeChatService: ChatService, @unchecked Sendable {
    var snapshotsToEmit: [[ChatSummary]] = []
    var createCalls: [String] = []
    var nextCreatedRoomID: String = "!fake:server"
    var refreshCalls: Int = 0
    var mutedRooms: [String] = []
    var leftRooms: [String] = []

    func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            for snapshot in snapshotsToEmit {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
    }

    func createChat(with botID: String) async throws -> String {
        createCalls.append(botID)
        return nextCreatedRoomID
    }

    func refresh() async throws { refreshCalls += 1 }
    func mute(roomID: String) async throws { mutedRooms.append(roomID) }
    func leave(roomID: String) async throws { leftRooms.append(roomID) }
}

final class ChatServiceFakeTests: XCTestCase {
    func test_emitsSnapshotsInOrder() async throws {
        let bot = BotIdentity(matrixID: "@bot:s", displayName: "Bot", avatarURL: nil)
        let s1 = [ChatSummary(id: "!1:s", title: "A", bot: bot, lastActivity: .distantPast, unreadCount: 0)]
        let s2 = [
            ChatSummary(id: "!1:s", title: "A", bot: bot, lastActivity: .distantPast, unreadCount: 0),
            ChatSummary(id: "!2:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 1),
        ]
        let fake = FakeChatService()
        fake.snapshotsToEmit = [s1, s2]
        var received: [[ChatSummary]] = []
        for await snap in fake.chatSummaries() {
            received.append(snap)
        }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].count, 1)
        XCTAssertEqual(received[1].count, 2)
    }
}
