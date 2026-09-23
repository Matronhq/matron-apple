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
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
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

    /// `totalUnread` mirrors the running sum of `ChatSummary.unreadCount`
    /// across every snapshot. Drives the iOS app-icon badge and the
    /// macOS dock-tile badge — both consume the published value via
    /// `.onChange` so a regression here would silently break the badge.
    @MainActor
    func test_totalUnread_isSumOfUnreadCounts_acrossLatestSnapshot() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [[
            ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: .now, unreadCount: 3),
            ChatSummary(id: "!b:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 0),
            ChatSummary(id: "!c:s", title: "C", bot: bot, lastActivity: .now, unreadCount: 7),
        ]]
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        let start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.totalUnread, 10,
                       "totalUnread must sum unreadCount across every chat in the snapshot")
    }

    /// A subsequent yield with a different unread distribution must
    /// update `totalUnread` in lockstep — the host's `.onChange`
    /// listener depends on this for the badge to drop after the user
    /// reads a chat (which causes `markAsRead()` → next snapshot drops
    /// the count).
    @MainActor
    func test_totalUnread_updatesWith_eachSnapshot() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [
            [ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: .now, unreadCount: 5)],
            [ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: .now, unreadCount: 0)],
        ]
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        let start = Date()
        while vm.totalUnread != 0 && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.totalUnread, 0,
                       "second snapshot's zero-unread state must replace the prior 5")
    }

    @MainActor
    func test_totalUnread_isZero_forEmptySnapshot() async throws {
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [[]]
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        let start = Date()
        while vm.isLoading && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.totalUnread, 0, "empty snapshot must clear the badge")
    }

    /// While agents are live the service yields several snapshots a second
    /// and every applied one re-diffs the whole sidebar `List`; the VM holds
    /// snapshots to one per `coalesceInterval`, keeping only the newest.
    @MainActor
    func test_snapshotsInsideTheCoalesceInterval_collapseToTheLatest() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        func chats(_ n: Int) -> [ChatSummary] {
            (0..<n).map { ChatSummary(id: "!\($0):s", title: "c\($0)", bot: bot, lastActivity: .now, unreadCount: 1) }
        }
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [chats(1), chats(2), chats(3), chats(4)]
        let vm = ChatListViewModel(chat: fake, coalesceInterval: .milliseconds(1_500))
        vm.start()
        var start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.totalUnread, 1, "the first snapshot applies immediately")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(vm.totalUnread, 1, "snapshots inside the interval are held, not applied one by one")
        start = Date()
        while vm.totalUnread != 4 && Date().timeIntervalSince(start) < 4 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.totalUnread, 4, "the newest held snapshot lands once the interval is up")
        XCTAssertEqual(fake.callCount, 1)
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
    /// A snapshot identical to the last one must not write `groups`:
    /// `@Observable` notifies on every write, equal or not, and each
    /// notification re-evaluates the Mac sidebar and everything else that
    /// read it — up to four times a second while agents are live.
    @MainActor
    func test_identicalSnapshot_doesNotNotifyGroupsObservers() async throws {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let stamp = Date()
        let one = [ChatSummary(id: "!1:s", title: "first", bot: bot, lastActivity: stamp, unreadCount: 0)]
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [one]
        let vm = ChatListViewModel(chat: fake)
        vm.start()
        var start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(vm.hasChats)

        let groupsChanged = Flag()
        let hasChatsChanged = Flag()
        withObservationTracking { _ = vm.groups } onChange: { groupsChanged.set() }
        withObservationTracking { _ = vm.hasChats } onChange: { hasChatsChanged.set() }

        // Same content again, then a real change: the real change proves the
        // identical snapshot had been consumed by the time we assert.
        fake.snapshotsToEmit = [one]
        await vm.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(groupsChanged.value, "an identical snapshot must not write groups")

        let two = one + [ChatSummary(id: "!2:s", title: "second", bot: bot, lastActivity: stamp, unreadCount: 0)]
        fake.snapshotsToEmit = [two]
        await vm.refresh()
        start = Date()
        while !groupsChanged.value && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(groupsChanged.value, "a changed snapshot must still notify")
        XCTAssertFalse(hasChatsChanged.value, "hasChats is written only when it flips")
        XCTAssertEqual(vm.groups.flatMap(\.summaries).count, 2)
    }

    @MainActor
    private func waitForGroups(_ vm: ChatListViewModel) async {
        let start = Date()
        while vm.groups.isEmpty && Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Coordinator redesign §3b/§3c: the Coordinator's conversation is left
    /// out of the list but still counted and still findable.
    @MainActor
    func test_hiddenConversation_leavesTheList_butStaysCountedAndSearchable() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [[
            ChatSummary(id: "!coord:s", title: "Coordinator", bot: bot, lastActivity: .now, unreadCount: 2),
            ChatSummary(id: "!b:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 1),
        ]]
        let vm = ChatListViewModel(chat: fake, coalesceInterval: .zero)
        vm.hiddenConversationID = "!coord:s"
        vm.start()
        await waitForGroups(vm)
        XCTAssertEqual(vm.groups.flatMap(\.summaries).map(\.id), ["!b:s"])
        XCTAssertEqual(vm.hiddenSummary?.id, "!coord:s")
        XCTAssertEqual(vm.totalUnread, 3, "the badge still counts the Coordinator's unread")
        XCTAssertEqual(Set(vm.allSummaries.map(\.id)), ["!coord:s", "!b:s"])
    }

    /// Assigning or clearing re-partitions the latest snapshot at once, with
    /// no new snapshot needed.
    @MainActor
    func test_changingTheHiddenID_repartitionsImmediately() async {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let fake = FakeStreamingChatService()
        fake.snapshotsToEmit = [[
            ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: .now, unreadCount: 0),
            ChatSummary(id: "!b:s", title: "B", bot: bot, lastActivity: .now, unreadCount: 0),
        ]]
        let vm = ChatListViewModel(chat: fake, coalesceInterval: .zero)
        vm.start()
        await waitForGroups(vm)
        vm.hiddenConversationID = "!a:s"
        XCTAssertEqual(vm.groups.flatMap(\.summaries).map(\.id), ["!b:s"])
        XCTAssertEqual(vm.hiddenSummary?.id, "!a:s")
        vm.hiddenConversationID = nil
        XCTAssertEqual(Set(vm.groups.flatMap(\.summaries).map(\.id)), ["!a:s", "!b:s"])
        XCTAssertNil(vm.hiddenSummary)
    }

    func test_partition_isAPureSplit() {
        let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)
        let a = ChatSummary(id: "!a:s", title: "A", bot: bot, lastActivity: nil, unreadCount: 4)
        let result = ChatListViewModel.partition([a], hiding: "!a:s")
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.hidden?.id, "!a:s")
        XCTAssertEqual(result.totalUnread, 4)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
