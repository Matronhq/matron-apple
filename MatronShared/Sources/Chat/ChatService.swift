import Foundation

public protocol ChatService: Sendable {
    /// Async stream of room list snapshots (full list, not deltas).
    ///
    /// **Phase 1 contract:** the live impl yields exactly one snapshot once
    /// sliding sync reaches `.running`, then completes the stream. Callers
    /// that need to refresh must call this method again.
    ///
    /// **Phase 2 contract:** the live impl will keep the stream open and
    /// yield a new snapshot any time the underlying room list changes
    /// (added/updated/removed rooms, latest-event timestamp updates,
    /// unread-count changes). Test fakes already emit multiple snapshots,
    /// so consumer ViewModels (`ChatListViewModel`) are diff-tolerant today.
    func chatSummaries() -> AsyncStream<[ChatSummary]>

    /// Creates a new 1:1 encrypted room with `botID` and returns the new
    /// room ID. The bot is invited via the SDK's `CreateRoomParameters`;
    /// the server (tuwunel) is responsible for marking the room as a DM.
    func createChat(with botID: String) async throws -> String

    /// Forces the chat list to re-poll its underlying source so consumers
    /// observing `chatSummaries()` receive a fresh snapshot. Wired to the
    /// iOS pull-to-refresh gesture and the Mac `⌘R` menu shortcut. The
    /// Phase 1 contract that `chatSummaries()` is single-shot per call
    /// stays intact — `refresh()` is a write-side ping that the Phase 2
    /// live impl uses to wait for sync readiness; the consumer is
    /// responsible for kicking off a new subscription.
    func refresh() async throws

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
