import XCTest
@testable import MatronChat
@testable import MatronModels

/// Test-only fake. Mirrors `FakeChatService` in `ChatServiceFakeTests.swift`
/// but adds the `createChat` recording surface for Task 6, and is declared
/// here separately so its existence doesn't disrupt the existing test fake.
actor FakeChatServiceForCreate: ChatService {
    var createdWith: [String] = []
    var nextRoomID: String = "!new:server"

    nonisolated func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { $0.finish() }
    }

    func createChat(with botID: String) async throws -> String {
        createdWith.append(botID)
        return nextRoomID
    }
}

final class CreateChatTests: XCTestCase {
    func test_recordsBotID_andReturnsRoomID() async throws {
        let fake = FakeChatServiceForCreate()
        // Pin to the protocol type so this test fails if `createChat` is
        // removed from the protocol surface (rather than just present on
        // the concrete fake).
        let service: any ChatService = fake
        let id = try await service.createChat(with: "@bot:s")
        XCTAssertEqual(id, "!new:server")
        let recorded = await fake.createdWith
        XCTAssertEqual(recorded, ["@bot:s"])
    }

    func test_recordsMultipleCallsInOrder() async throws {
        let fake = FakeChatServiceForCreate()
        let service: any ChatService = fake
        _ = try await service.createChat(with: "@one:s")
        _ = try await service.createChat(with: "@two:s")
        let recorded = await fake.createdWith
        XCTAssertEqual(recorded, ["@one:s", "@two:s"])
    }
}
