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

    /// Long-lived stream of a parent conversation's subagent children, in
    /// creation order (running + finished). Drives the parent chat's
    /// running-subagent strip and the sub-chat switcher menu. The stream
    /// yields the current children immediately on subscribe, then a fresh
    /// list whenever a child is created, renamed, or transitions
    /// running→done. Nesting recurses: passing a child's id returns *its*
    /// children, so the strip and switcher work at any depth. Cancelling
    /// one consumer doesn't disturb the chat list or other subscribers.
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]>

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

    // MARK: - Phase 5 Task 7 — DEFERRED
    //
    // The plan called for `func sessionMeta(for roomID: String) async
    // throws -> SessionMetaEvent?` reading the
    // `chat.matron.session_meta` state event via `Room.getStateEvent`.
    // **v26 of `matrix-rust-components-swift` does not expose a state-
    // event read API on `Room`** — only `sendStateEventRaw(...)` (the
    // write side) and a handful of typed accessors (`name()`,
    // `topic()`, `encryptionState()`, etc.). Arbitrary state-event
    // reading by `eventType` + `stateKey` is not in the FFI surface.
    // Confirmed by walking the `RoomProtocol` declaration in
    // `Sources/MatrixRustSDK/matrix_sdk_ffi.swift`.
    //
    // Consequences:
    // - Task 7 + Task 10 (`SessionMetaHeader`) are both deferred until
    //   either (a) the SDK adds a state-event reader, or (b) we work
    //   around it via a raw HTTP call to
    //   `GET /_matrix/client/v3/rooms/{roomId}/state/{eventType}` using
    //   the SDK's auth token.
    // - The Task 4 `SessionMetaEvent` parser ships unused on the
    //   client side for now; the bot can still write the event via
    //   `Room.sendStateEventRaw`, the data just doesn't surface in
    //   the UI yet.
    //
    // Adding this method as a TODO instead of leaving it silently
    // unimplemented so a future agent picking up the deferred work
    // has the contract pinned where they expect it.
    //
    // func sessionMeta(for roomID: String) async throws -> SessionMetaEvent?
}

public extension ChatService {
    /// Joined-room IDs for the push bootstrap's per-room `.allMessages`
    /// pass, sourced from `chatSummaries()`. `PushBootstrap.bootstrapHost`'s
    /// `joinedRoomIDs` source on both hosts — lives here (not in MatronPush)
    /// so the push module stays decoupled from the chat layer.
    ///
    /// **Waits for the first NON-EMPTY snapshot**, bounded by `timeout`.
    /// The stream's first yield is `[]` while sliding sync is still warming
    /// (per the `chatSummaries()` doc); the prior one-shot read took that
    /// `[]` and returned, so a cold sign-in set push rules on zero rooms
    /// for the whole session — bootstrap runs once per
    /// `.task(id: session.userID)` and never re-fires (cursor PR #5 finding
    /// "push rules miss late rooms"). The bound is required because a
    /// genuinely room-less account yields `[]` and then nothing, so there's
    /// no non-empty snapshot to wait for; on timeout this returns `[]`.
    ///
    /// The caller runs this OFF the pusher-registration critical path
    /// (after `register(token:)`), so the wait can never delay the
    /// `setPusher` write. The subscription is short-lived — torn down on
    /// return or task cancellation (sign-out) — and never advances the
    /// broadcaster's other consumers (ChatListViewModel, NewChatSheet).
    func firstSnapshotRoomIDs(timeout: Duration = .seconds(30)) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            group.addTask {
                var iterator = chatSummaries().makeAsyncIterator()
                while !Task.isCancelled {
                    // `try?` collapses a thrown stream (SyncReadyError) and a
                    // finished stream alike to "give up" — a room-less or
                    // failed-sync account isn't worth failing push setup over.
                    guard let snapshot = try? await iterator.next() else { return [] }
                    if !snapshot.isEmpty { return snapshot.map(\.id) }
                }
                return []
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }
}
