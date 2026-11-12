import Foundation

public protocol ChatService: Sendable {
    /// Long-lived async stream of chat list snapshots (full list, not
    /// deltas), read from the local journal mirror.
    ///
    /// Each call is an independent subscription: the consumer immediately
    /// receives the current list, then a fresh snapshot whenever the
    /// mirror's conversations change. The stream stays open until the
    /// consumer cancels (sheet dismiss, view-model `cancel()`, task
    /// cancellation). Cancelling one consumer doesn't affect any other.
    ///
    /// `AsyncThrowingStream` so a failure can reach the consumer instead of
    /// being swallowed by `continuation.finish()` — `ChatListViewModel`
    /// displays the message in a banner / empty-state overlay.
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error>

    /// Long-lived stream of a parent conversation's subagent children, in
    /// creation order (running + finished). Drives the parent chat's
    /// running-subagent strip and the sub-chat switcher menu. The stream
    /// yields the current children immediately on subscribe, then a fresh
    /// list whenever a child is created, renamed, or transitions
    /// running→done. Nesting recurses: passing a child's id returns *its*
    /// children, so the strip and switcher work at any depth. Cancelling
    /// one consumer doesn't disturb the chat list or other subscribers.
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]>

    /// Asks the sync engine to re-fetch the conversation summaries from the
    /// server, best-effort; every `chatSummaries()` consumer then sees the
    /// result through the mirror. Bound to the iOS pull-to-refresh and Mac
    /// `⌘R` gestures via `ChatListViewModel.refresh()`.
    func forceSnapshot() async throws

    /// The list came on screen. A device that does not mirror every
    /// conversation (the `forYou` sync scope) refreshes its summaries then,
    /// at most once a minute; one that does has them current already.
    func listDidAppear() async

    /// Archives (`archived: true`) or unarchives the conversations. An
    /// archived conversation leaves the chat list for Archived at once;
    /// nothing in it is deleted, and a new message brings it back. Synced
    /// to the user's other devices on a journal that syncs the archive.
    func setArchived(_ roomIDs: [String], archived: Bool) async

    /// Long-lived stream of the archived conversations, in the chat list's
    /// order (most recently active first). Same shape as `chatSummaries()`.
    func archivedChatSummaries() -> AsyncStream<[ChatSummary]>
}

public extension ChatService {
    func listDidAppear() async {}

    /// Default for fakes that do not archive.
    func setArchived(_ roomIDs: [String], archived: Bool) async {}

    /// Default for fakes: never anything archived.
    func archivedChatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }
}
