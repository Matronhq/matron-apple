import Foundation

/// Fan-out actor sitting between the single owning `RoomListSubscription`
/// and the (potentially multiple) `ChatService.chatSummaries()` consumers.
///
/// **Why an actor and not a `Sendable` struct with a lock:** consumer
/// cancellation (sheet dismiss, view-model deinit) calls `unregister`
/// from arbitrary threads while `broadcast` is fanning out from the
/// listener task. Actor isolation serialises both without us hand-rolling
/// a recursive lock, and keeps `latest`/`failure` updates atomic with
/// the registration list mutation.
///
/// **Lifecycle:**
/// - `register` adds a continuation, immediately yields the latest
///   snapshot if one exists, OR immediately finishes with the stored
///   `failure` if `fail(with:)` has already been called.
/// - `broadcast` updates `latest` and yields to every registered
///   continuation. Cancelled continuations are dropped silently — the
///   `onTermination` hook in `ChatServiceLive.chatSummaries()` calls
///   `unregister` to clean up the map.
/// - `fail(with:)` terminates every registered continuation with the
///   error and records it so future registrations terminate immediately.
///   This pairs with `ChatServiceLive`'s upstream-error path: a thrown
///   `roomListService.allRooms()` (the documented construction-throw
///   risk) flows out to consumers as a stream failure.
///
/// Two known consumers today: `ChatListViewModel.start()` and
/// `NewChatSheet.loadBots()`. Both share the upstream listener; cancelling
/// one removes only that continuation.
actor ChatSummaryBroadcaster {

    /// Last broadcast snapshot. New consumers see this immediately on
    /// register so the chat list paints with cached data without waiting
    /// for a fresh listener fire. `nil` until the first broadcast.
    private(set) var latest: [ChatSummary]?

    /// Set after `fail(with:)`. Subsequent `register` calls terminate
    /// immediately with this error. `broadcast` is a no-op once failed —
    /// stream lifecycle is one-way.
    private var failure: Error?

    private var continuations: [UUID: AsyncThrowingStream<[ChatSummary], Error>.Continuation] = [:]

    /// Registers a continuation. If a snapshot has already been broadcast,
    /// the continuation receives it immediately; if `fail(with:)` has
    /// already fired, the continuation finishes with the stored error
    /// and `nil` is returned (no token to unregister later).
    ///
    /// - Returns: token used by the consumer-side `onTermination` to
    ///   `unregister` on cancel. `nil` when the broadcaster is already
    ///   failed.
    @discardableResult
    func register(_ continuation: AsyncThrowingStream<[ChatSummary], Error>.Continuation) -> UUID? {
        if let failure {
            continuation.finish(throwing: failure)
            return nil
        }
        let token = UUID()
        continuations[token] = continuation
        if let latest {
            continuation.yield(latest)
        }
        return token
    }

    /// Removes a registered continuation and finishes its stream cleanly.
    /// Idempotent — calling twice with the same token is a no-op (the
    /// `onTermination` hook can fire after a manual `unregister`).
    func unregister(token: UUID) {
        if let continuation = continuations.removeValue(forKey: token) {
            continuation.finish()
        }
    }

    /// Broadcasts a snapshot to every registered consumer and stores it
    /// as `latest` for future registrations. No-op once `fail(with:)` has
    /// been called.
    func broadcast(_ snapshot: [ChatSummary]) {
        guard failure == nil else { return }
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    /// Terminates every registered consumer with `error`. Records the
    /// error so future `register` calls terminate immediately rather than
    /// silently waiting on a dead listener.
    func fail(with error: Error) {
        guard failure == nil else { return }
        failure = error
        let snapshot = continuations
        continuations.removeAll()
        for continuation in snapshot.values {
            continuation.finish(throwing: error)
        }
    }
}
