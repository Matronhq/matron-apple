import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Test fake mirroring the chat-list streaming surface. Local to this
/// test file so the error-flow assertion (QA finding #10) doesn't need
/// to leak through to the production protocol's other test consumers.
final class FakeStreamingChatService: ChatService, @unchecked Sendable {
    var snapshotsToEmit: [[ChatSummary]] = []
    var streamError: Error?
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        let snapshots = snapshotsToEmit
        let err = streamError
        return AsyncThrowingStream { continuation in
            for s in snapshots { continuation.yield(s) }
            if let err {
                continuation.finish(throwing: err)
            } else {
                continuation.finish()
            }
        }
    }
    func createChat(with botID: String) async throws -> String { "!stub:server" }
    func refresh() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

/// Minimal error type for routing through `chatSummaries()` in the
/// error-flow assertion below.
struct FakeStreamError: LocalizedError { let errorDescription: String? }

final class ChatListViewModelTests: XCTestCase {
    @MainActor
    func test_groupsSummariesByRecency() {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let now = Date(timeIntervalSince1970: 1745000000)
        let summaries = [
            ChatSummary(id: "!t:s", title: "Today chat",     bot: bot, lastActivity: now.addingTimeInterval(-3600),    unreadCount: 0),
            ChatSummary(id: "!y:s", title: "Yesterday chat", bot: bot, lastActivity: now.addingTimeInterval(-86_400),  unreadCount: 0),
            ChatSummary(id: "!w:s", title: "Earlier chat",   bot: bot, lastActivity: now.addingTimeInterval(-86_400 * 30), unreadCount: 0),
        ]
        let groups = ChatListViewModel.group(summaries: summaries, now: now)
        XCTAssertEqual(groups.first?.group, .today)
        XCTAssertEqual(groups.first?.summaries.count, 1)
        XCTAssertEqual(groups.last?.group, .earlier)
    }

    @MainActor
    func test_emptyState_isReflected() {
        let groups = ChatListViewModel.group(summaries: [])
        XCTAssertTrue(groups.isEmpty)
    }

    @MainActor
    func test_upstreamStreamError_populates_errorField() async throws {
        // QA finding #10: when sliding-sync readiness fails (timeout /
        // errored / terminated), `chatSummaries()` previously
        // `continuation.finish()`'d silently → "infinite spinner then
        // empty list." The View needs a meaningful error to surface.
        // Now the live stream rethrows, the VM catches, and `error` is
        // populated.
        let fake = FakeStreamingChatService()
        fake.streamError = FakeStreamError(errorDescription: "sliding sync timed out")
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        // The fake's stream finishes (with error) immediately; bound the
        // wait so a regression surfaces as a failure rather than hang.
        let start = Date()
        while vm.error == nil && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.error, "sliding sync timed out",
                       "upstream stream error must populate error field")
        XCTAssertFalse(vm.isLoading, "isLoading must clear so the View renders the error")
    }

    @MainActor
    func test_successfulSnapshot_clears_priorError() async throws {
        // After an error, a fresh successful snapshot should clear the
        // error banner. Verifies the recovery path.
        let fake = FakeStreamingChatService()
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        fake.snapshotsToEmit = [
            [ChatSummary(id: "!1:s", title: "ok", bot: bot, lastActivity: .now, unreadCount: 0)]
        ]
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        let start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(vm.error, "successful snapshot must keep error nil")
        XCTAssertFalse(vm.groups.isEmpty)
    }
}
