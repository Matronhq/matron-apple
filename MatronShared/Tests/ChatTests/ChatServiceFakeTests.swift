import XCTest
@testable import MatronChat
@testable import MatronModels

final class FakeChatService: ChatService, @unchecked Sendable {
    var snapshotsToEmit: [[ChatSummary]] = []
    /// When non-nil, `chatSummaries()` finishes by throwing this error
    /// after yielding all queued snapshots. Lets tests pin the error-flow
    /// added in QA finding #10.
    var streamError: Error?
    var createCalls: [String] = []
    var nextCreatedRoomID: String = "!fake:server"
    var refreshCalls: Int = 0
    var forceSnapshotCalls: Int = 0
    var mutedRooms: [String] = []
    var leftRooms: [String] = []

    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { continuation in
            for snapshot in snapshotsToEmit {
                continuation.yield(snapshot)
            }
            if let streamError {
                continuation.finish(throwing: streamError)
            } else {
                continuation.finish()
            }
        }
    }

    func createChat(with botID: String) async throws -> String {
        createCalls.append(botID)
        return nextCreatedRoomID
    }

    func refresh() async throws { refreshCalls += 1 }
    func forceSnapshot() async throws { forceSnapshotCalls += 1 }
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
        for try await snap in fake.chatSummaries() {
            received.append(snap)
        }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].count, 1)
        XCTAssertEqual(received[1].count, 2)
    }
}
