import Foundation

public protocol ChatService: Sendable {
    /// Long-lived async stream of room list snapshots (full list, not
    /// deltas). Phase 2.5 wired this through a fan-out broadcaster on top
    /// of `RoomList.entriesWithDynamicAdapters` + per-room
    /// `Room.subscribeToRoomInfoUpdates` — see plan at
    /// `docs/superpowers/plans/2026-05-05-matron-ios-phase-2-5-live-chat-list.md`.
    ///
    /// Each call registers a new continuation with the broadcaster:
    /// the consumer immediately receives the latest snapshot (may be
    /// `[]` if sliding sync is still warming up), then a fresh snapshot
    /// for every diff the live `RoomListSubscription` reports. The stream
    /// stays open until the consumer cancels (sheet dismiss, view-model
    /// `cancel()`, task cancellation). Cancelling one consumer doesn't
    /// affect any other.
    ///
    /// `AsyncThrowingStream` so sliding-sync readiness failures
    /// (`SyncReadyError.timeout`, `.errored`, `.terminated`) bubble to
    /// the consumer instead of being swallowed by `continuation.finish()`
    /// — `ChatListViewModel` displays the message in a banner / empty-state
    /// overlay (QA finding #10).
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error>

    /// Creates a new 1:1 encrypted room with `botID` and returns the new
    /// room ID. The bot is invited via the SDK's `CreateRoomParameters`;
    /// the server (tuwunel) is responsible for marking the room as a DM.
    func createChat(with botID: String) async throws -> String

    /// Blocks on `sync.waitUntilReady()` and returns. Stays around for any
    /// caller that just wants to ensure sliding sync has bootstrapped
    /// before proceeding. View-layer pull-to-refresh / `⌘R` gestures
    /// route through `ChatListViewModel.refresh()` →
    /// `ChatService.forceSnapshot()` instead — see Phase 2.5 plan at
    /// `docs/superpowers/plans/2026-05-05-matron-ios-phase-2-5-live-chat-list.md`.
    func refresh() async throws

    /// Phase 2.5: feeds a fresh one-shot `client.rooms()` snapshot through
    /// the same broadcaster pipe the live `RoomListSubscription` uses, so
    /// every registered `chatSummaries()` consumer sees an extra yield.
    /// Bound to the iOS pull-to-refresh and Mac `⌘R` gestures via
    /// `ChatListViewModel.refresh()`. Does NOT tear down the live listener
    /// — accumulated diff state and per-room subscription handles stay
    /// intact.
    func forceSnapshot() async throws

    /// Mutes notifications for `roomID` by setting the SDK's
    /// `NotificationSettings` room mode to `.mute`. Idempotent — calling
    /// twice for an already-muted room is a no-op on the server.
    func mute(roomID: String) async throws

    /// Leaves and forgets `roomID`. The room disappears from the chat
    /// list once the server confirms the leave; tuwunel may also tombstone
    /// the room for the bot. Phase 4 will add a confirmation alert in the
    /// UI so this isn't a one-tap destructive action.
    func leave(roomID: String) async throws
}

public extension ChatService {
    /// One snapshot off the long-lived `chatSummaries()` stream, mapped
    /// to room IDs. Never consumed past the first yield, so the
    /// broadcaster's other registered consumers (ChatListViewModel,
    /// NewChatSheet) are unaffected. `PushBootstrap.bootstrapHost`'s
    /// `joinedRoomIDs` source on both hosts — lives here (not in
    /// MatronPush) so the push module stays decoupled from the chat
    /// layer.
    func firstSnapshotRoomIDs() async -> [String] {
        var iterator = chatSummaries().makeAsyncIterator()
        if let snapshot = try? await iterator.next() {
            return snapshot.map(\.id)
        }
        return []
    }
}
