import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Test fake mirroring the Phase 2.5 long-lived chat-list streaming
/// surface. Each `chatSummaries()` call returns a long-lived stream that
/// yields every queued snapshot in order, then optionally finishes with
/// `streamError` if set. Mirrors the production `ChatSummaryBroadcaster`
/// shape: one stream, multiple yields. Local to this test file so the
/// error-flow assertion (QA finding #10) doesn't leak through to the
/// production protocol's other test consumers.
final class FakeStreamingChatService: ChatService, @unchecked Sendable {
    /// Snapshots the next `chatSummaries()` stream yields in order before
    /// finishing (with `streamError` if set, otherwise cleanly). Mutated
    /// in place by `forceSnapshot()` — tests that exercise refresh push
    /// onto this queue between yields.
    var snapshotsToEmit: [[ChatSummary]] = []
    var streamError: Error?
    private(set) var callCount = 0
    private(set) var forceSnapshotCalls = 0
    /// Holds the active stream's continuation so `forceSnapshot()` can
    /// drive an extra yield through the same pipe (mirrors the live
    /// broadcaster's fan-out shape).
    private var activeContinuation: AsyncThrowingStream<[ChatSummary], Error>.Continuation?

    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        callCount += 1
        let queued = snapshotsToEmit
        snapshotsToEmit.removeAll()
        let err = streamError
        return AsyncThrowingStream { continuation in
            self.activeContinuation = continuation
            for snapshot in queued {
                continuation.yield(snapshot)
            }
            if let err {
                continuation.finish(throwing: err)
                self.activeContinuation = nil
            }
            // No `finish()` on the success path — the stream stays open
            // so subsequent `forceSnapshot()` calls can deliver more
            // yields. Tests that need the stream to terminate cleanly
            // can call `finishStream()`.
        }
    }

    /// Drives one extra yield through the active stream, taking the
    /// next entry from `snapshotsToEmit` if any. No-op if no stream is
    /// active or the queue is empty.
    func forceSnapshot() async throws {
        forceSnapshotCalls += 1
        guard let continuation = activeContinuation,
              !snapshotsToEmit.isEmpty
        else { return }
        let snapshot = snapshotsToEmit.removeFirst()
        continuation.yield(snapshot)
    }

    /// Closes the active stream cleanly. Tests that assert on
    /// post-finish behaviour call this; the default success path leaves
    /// the stream open so multi-yield matches production semantics.
    func finishStream() {
        activeContinuation?.finish()
        activeContinuation = nil
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

    /// Phase 2.5 multi-yield contract: the long-lived broadcaster yields
    /// every snapshot through ONE stream, so the VM iterates the stream
    /// without re-subscribing. Pre-Phase-2.5 the VM masked an empty
    /// first yield with a 30×1s retry loop that re-called
    /// `chatSummaries()`; that's now dead code — an empty first yield
    /// just means the next yield will arrive when sliding sync warms up.
    @MainActor
    func test_consumesMultipleYieldsThroughSingleStream() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [
            [],  // 1st yield: empty (sliding sync still warming up)
            [ChatSummary(id: "!1:s", title: "ok", bot: bot, lastActivity: .now, unreadCount: 0)],
        ]
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        let start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.groups.isEmpty, "VM must land on the populated second yield")
        XCTAssertEqual(fake.callCount, 1, "long-lived stream means exactly one chatSummaries() call")
        XCTAssertNil(vm.error, "no upstream error means error stays nil")
    }

    /// `refresh()` calls `forceSnapshot()` on the underlying service; the
    /// fake broadcasts the next queued snapshot through the active
    /// stream so the VM observes it as an additional yield.
    @MainActor
    func test_refresh_drivesForceSnapshot_andUpdatesGroups() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        let initial = [ChatSummary(id: "!1:s", title: "first", bot: bot, lastActivity: .now, unreadCount: 0)]
        let refreshed = [
            ChatSummary(id: "!1:s", title: "first", bot: bot, lastActivity: .now, unreadCount: 0),
            ChatSummary(id: "!2:s", title: "second", bot: bot, lastActivity: .now, unreadCount: 0),
        ]
        fake.snapshotsToEmit = [initial]
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        // Wait for the initial yield to land on the VM.
        var start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.groups.flatMap(\.summaries).count, 1, "initial yield should populate one summary")

        // Queue a second snapshot then call refresh — the fake's
        // forceSnapshot drains the queue through the active stream.
        fake.snapshotsToEmit = [refreshed]
        await vm.refresh()
        XCTAssertEqual(fake.forceSnapshotCalls, 1, "refresh() must call forceSnapshot()")
        start = Date()
        while vm.groups.flatMap(\.summaries).count < 2 && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.groups.flatMap(\.summaries).count, 2, "refresh-driven yield must reach the VM through the live stream")
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
