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
}
