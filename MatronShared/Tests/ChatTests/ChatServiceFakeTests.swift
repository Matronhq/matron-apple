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
    /// Children snapshots keyed by parent id, emitted in order by
    /// `children(of:)`. Absent parent → an empty stream.
    var childrenByParent: [String: [[SubChatSummary]]] = [:]

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

    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        let snapshots = childrenByParent[parentConvoID] ?? []
        return AsyncStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }
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

    // MARK: firstSnapshotRoomIDs (PushBootstrap.bootstrapHost's
    // joinedRoomIDs source — extracted in the PR #5 fourth-pass dedup)

    func test_firstSnapshotRoomIDs_mapsFirstNonEmptyYield() async {
        let bot = BotIdentity(matrixID: "@bot:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeChatService()
        fake.snapshotsToEmit = [
            [ChatSummary(id: "!1:s", title: "A", bot: bot, lastActivity: .distantPast, unreadCount: 0),
             ChatSummary(id: "!2:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 1)],
            [ChatSummary(id: "!3:s", title: "C", bot: bot, lastActivity: .now, unreadCount: 0)],
        ]
        let ids = await fake.firstSnapshotRoomIDs()
        XCTAssertEqual(ids, ["!1:s", "!2:s"], "first non-empty yield — later snapshots belong to other consumers")
    }

    func test_firstSnapshotRoomIDs_waitsThroughEmptyWarmupSnapshot() async {
        // The race the push-rules-miss-late-rooms fix targets: sliding
        // sync is still warming, so the first snapshot is [] and the
        // rooms land on a later one. The old one-shot read returned []
        // (no rooms got .allMessages); the wait must skip the empty
        // warm-up snapshot and use the first populated one.
        let bot = BotIdentity(matrixID: "@bot:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeChatService()
        fake.snapshotsToEmit = [
            [],
            [ChatSummary(id: "!1:s", title: "A", bot: bot, lastActivity: .now, unreadCount: 0)],
        ]
        let ids = await fake.firstSnapshotRoomIDs()
        XCTAssertEqual(ids, ["!1:s"])
    }

    func test_firstSnapshotRoomIDs_emptyOnImmediateFinish() async {
        let fake = FakeChatService()
        fake.snapshotsToEmit = []
        let ids = await fake.firstSnapshotRoomIDs()
        XCTAssertEqual(ids, [])
    }

    func test_firstSnapshotRoomIDs_emptyOnStreamError() async {
        let fake = FakeChatService()
        fake.streamError = URLError(.notConnectedToInternet)
        let ids = await fake.firstSnapshotRoomIDs()
        XCTAssertEqual(ids, [], "throwing stream maps to [] — bootstrap shouldn't fail on a cold chat list")
    }

    func test_firstSnapshotRoomIDs_timesOutToEmpty_whenStreamStaysEmpty() async {
        // A genuinely room-less account: the stream yields [] and then
        // nothing (no diffs ever arrive), so there's no non-empty
        // snapshot to wait for. The bound must return [] rather than
        // hang the push bootstrap forever.
        let fake = HangingEmptyChatService()
        let ids = await fake.firstSnapshotRoomIDs(timeout: .milliseconds(200))
        XCTAssertEqual(ids, [])
    }
}

/// `chatSummaries()` yields a single `[]` and never finishes — mimics a
/// room-less account whose sliding-sync stream stays open with no diffs.
/// Used to pin `firstSnapshotRoomIDs`'s timeout bound.
private final class HangingEmptyChatService: ChatService, @unchecked Sendable {
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield([])
            // Deliberately never finished.
        }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
}
