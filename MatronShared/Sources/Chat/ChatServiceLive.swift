import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync
import os

public final class ChatServiceLive: ChatService, @unchecked Sendable {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "chat-service")

    private let provider: ClientProvider
    private let session: UserSession
    private let sync: MatronSync.SyncService

    /// Single fan-out broadcaster shared by every `chatSummaries()` caller.
    /// Lifetime is tied to the service instance (per-session singleton in
    /// DI), so one broadcaster = one signed-in user.
    private let broadcaster = ChatSummaryBroadcaster()

    /// Owns the lazily-constructed subscription / fallback poll task and
    /// the one-shot bootstrap Task. Actor isolation handles the rare
    /// concurrent-first-caller race without sync/async lock contortions.
    /// The held strong refs keep the SDK listener (or poll task) alive
    /// for the lifetime of the service; consumer cancellation never tears
    /// these down.
    private let state = BootstrapState()

    /// Polling interval for the construction-throw fallback. 30s matches
    /// the plan's narrow-fallback spec — only fires when the live path
    /// fails at construction time, so we err generous to avoid hammering
    /// `client.rooms()` if every poll is going to succeed.
    private static let fallbackPollInterval: TimeInterval = 30

    public init(provider: ClientProvider, session: UserSession, sync: MatronSync.SyncService) {
        self.provider = provider
        self.session = session
        self.sync = sync
    }

    public func createChat(with botID: String) async throws -> String {
        try await sync.waitUntilReady()
        let client = try await provider.client(for: session)
        // SDK v26 (26.04.01) `CreateRoomParameters` shape: `invite` is
        // `[String]?`; positional args after `name`/`topic`/`isEncrypted`/
        // `isDirect`/`visibility`/`preset`/`invite`/`avatar` (powerLevels,
        // joinRule, historyVisibility, canonicalAlias, isSpace) take
        // sensible defaults. See
        // matrix-rust-components-swift/Sources/MatrixRustSDK/matrix_sdk_ffi.swift
        // for the canonical signature.
        let request = CreateRoomParameters(
            name: nil,
            topic: nil,
            isEncrypted: true,
            isDirect: true,
            visibility: .private,
            preset: .privateChat,
            invite: [botID],
            avatar: nil
        )
        return try await client.createRoom(request: request)
    }

    /// Phase 2.5 refresh contract: ensure sliding sync is ready, then
    /// return. The SDK doesn't expose a `forceSyncOnce`-style trigger in
    /// v26, and sliding sync is continuous in the background, so the
    /// meaningful work is making sure the next call to `chatSummaries()`
    /// won't race the initial sync. View-layer pull-to-refresh / `⌘R`
    /// gestures now route through `ChatListViewModel.refresh()` →
    /// `ChatService.forceSnapshot()`; this method stays for any direct
    /// caller that just wants to block on readiness.
    public func refresh() async throws {
        try await sync.waitUntilReady()
    }

    /// Polls `client.rooms()` once and feeds the resulting summaries
    /// through the same broadcaster the live `RoomListSubscription`
    /// publishes to. Every registered `chatSummaries()` consumer sees
    /// one extra yield; the listener and its per-room subscriptions
    /// stay alive. Used by `ChatListViewModel.refresh()` (iOS
    /// pull-to-refresh + Mac `⌘R`).
    public func forceSnapshot() async throws {
        try await sync.waitUntilReady()
        let client = try await provider.client(for: session)
        let summaries = await ChatSummaryMapper.summaries(for: client.rooms(), client: client)
        await broadcaster.broadcast(summaries)
    }

    public func mute(roomID: String) async throws {
        try await sync.waitUntilReady()
        let client = try await provider.client(for: session)
        let settings = await client.getNotificationSettings()
        try await settings.setRoomNotificationMode(roomId: roomID, mode: .mute)
    }

    public func leave(roomID: String) async throws {
        try await sync.waitUntilReady()
        let client = try await provider.client(for: session)
        guard let room = try client.getRoom(roomId: roomID) else {
            throw ChatServiceError.roomNotFound(roomID)
        }
        try await room.leave()
        try await room.forget()
    }

    /// Returns a long-lived stream of chat-list snapshots. Phase 2.5 wired
    /// this to share a single upstream `RoomListSubscription` (Task 2
    /// Step 1) across every consumer via `ChatSummaryBroadcaster` (Task 2
    /// Step 2); see plan at
    /// `docs/superpowers/plans/2026-05-05-matron-ios-phase-2-5-live-chat-list.md`.
    /// The stream stays open for the consumer's lifetime — cancelling
    /// (sheet dismiss, view-model deinit) only removes that one
    /// continuation; the upstream listener keeps running.
    public func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        let broadcaster = self.broadcaster
        let state = self.state
        let provider = self.provider
        let session = self.session
        let sync = self.sync

        // Token slot the registration task will set once `register` returns.
        // Sendable box so the `onTermination` closure can read it without
        // capturing a `var`.
        let tokenBox = TokenBox()

        return AsyncThrowingStream { continuation in
            let registrationTask = Task {
                // Lazily kick off bootstrap on first call; subsequent
                // calls await the already-running bootstrap. Either way
                // the consumer either receives a real first snapshot OR
                // a stored construction-throw failure — never a silent
                // stall.
                await state.ensureBootstrapStarted(
                    sync: sync,
                    provider: provider,
                    session: session,
                    broadcaster: broadcaster,
                    logger: Self.logger,
                    fallbackInterval: Self.fallbackPollInterval
                )
                if Task.isCancelled { return }
                let token = await broadcaster.register(continuation)
                if let token {
                    await tokenBox.set(token)
                    if await tokenBox.cancelledBeforeRegister {
                        // Consumer cancelled between bootstrap and
                        // register; pull the token back out and
                        // unregister immediately.
                        await broadcaster.unregister(token: token)
                    }
                }
            }
            continuation.onTermination = { _ in
                registrationTask.cancel()
                Task {
                    if let token = await tokenBox.takeForUnregister() {
                        await broadcaster.unregister(token: token)
                    }
                }
            }
        }
    }
}

// MARK: - Bootstrap state

/// Holds the lazily-constructed `RoomListSubscription` (or fallback poll
/// `Task`) plus the bootstrap Task itself. Actor isolation makes "ensure
/// bootstrap exists, then await its completion" race-free across
/// concurrent first-callers without resorting to sync-context NSLocks
/// (which Swift 6 forbids in async functions).
private actor BootstrapState {
    private var bootstrap: Task<Void, Never>?
    private var subscription: RoomListSubscription?
    private var fallbackTask: Task<Void, Never>?

    /// Lazily starts the bootstrap and awaits its completion. Subsequent
    /// callers await the same Task — first-call wins, every other caller
    /// returns once bootstrap has resolved (success or stored failure).
    func ensureBootstrapStarted(
        sync: MatronSync.SyncService,
        provider: ClientProvider,
        session: UserSession,
        broadcaster: ChatSummaryBroadcaster,
        logger: Logger,
        fallbackInterval: TimeInterval
    ) async {
        if let bootstrap {
            await bootstrap.value
            return
        }
        // Strong self capture — `BootstrapState` is owned by `ChatServiceLive`
        // for its full lifetime, so the task can't outlive a deallocated
        // actor. Weak capture would silently no-op the bootstrap if the
        // actor were ever released early, leaving every registered consumer
        // stalled indefinitely without diagnostic.
        let task: Task<Void, Never> = Task {
            await self.runBootstrap(
                sync: sync,
                provider: provider,
                session: session,
                broadcaster: broadcaster,
                logger: logger,
                fallbackInterval: fallbackInterval
            )
        }
        bootstrap = task
        await task.value
    }

    private func runBootstrap(
        sync: MatronSync.SyncService,
        provider: ClientProvider,
        session: UserSession,
        broadcaster: ChatSummaryBroadcaster,
        logger: Logger,
        fallbackInterval: TimeInterval
    ) async {
        do {
            try await sync.waitUntilReady()
        } catch {
            await broadcaster.fail(with: error)
            return
        }

        let client: Client
        do {
            client = try await provider.client(for: session)
        } catch {
            await broadcaster.fail(with: error)
            return
        }

        // The protocol surface of `MatronSync.SyncService` doesn't expose
        // the SDK's `RoomListService`; the live impl `SyncServiceLive`
        // does via `sdkService()`. In production this cast always
        // succeeds because `AppDependencies` constructs `SyncServiceLive`.
        // In the rare (test-only) case where a fake `SyncService` is
        // wired, we degrade gracefully to the construction-throw fallback
        // path — same end state as if `allRooms()` had thrown.
        guard let liveSync = sync as? SyncServiceLive,
              let sdkSync = await liveSync.sdkService()
        else {
            logger.error("ChatServiceLive: SyncService doesn't expose sdkService(); falling back to client.rooms() poll")
            fallbackTask = Self.startFallbackPoll(
                client: client,
                broadcaster: broadcaster,
                interval: fallbackInterval
            )
            return
        }

        let roomList: RoomList
        do {
            roomList = try await sdkSync.roomListService().allRooms()
        } catch {
            // Construction-throw: this is the single signature we treat
            // as "live path is dead, fall back to polling". See plan
            // Task 2 Step 4 for the rationale (no 5s race; .reset arrives
            // immediately on subscribe so a race always wins even on a
            // silently-broken listener).
            logger.error("ChatServiceLive: roomListService.allRooms() threw: \(error, privacy: .public). Falling back to 30s client.rooms() poll.")
            fallbackTask = Self.startFallbackPoll(
                client: client,
                broadcaster: broadcaster,
                interval: fallbackInterval
            )
            return
        }

        subscription = RoomListSubscription(
            client: client,
            roomList: roomList,
            logger: logger,
            onSnapshot: { snapshot in
                Task { await broadcaster.broadcast(snapshot) }
            }
        )
    }

    private static func startFallbackPoll(
        client: Client,
        broadcaster: ChatSummaryBroadcaster,
        interval: TimeInterval
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let rooms = client.rooms()
                let summaries = await ChatSummaryMapper.summaries(for: rooms, client: client)
                await broadcaster.broadcast(summaries)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    deinit {
        bootstrap?.cancel()
        fallbackTask?.cancel()
    }
}

public enum ChatServiceError: Error, Equatable, Sendable {
    /// Raised when `mute(roomID:)` or `leave(roomID:)` cannot resolve the
    /// requested room — typically because the SDK hasn't synced it yet, or
    /// the user has already left it.
    case roomNotFound(String)
}

/// Bridges `chatSummaries()`'s registration-task ↔ `onTermination`
/// closure so the consumer can cancel before, during, or after the
/// broadcaster registration completes without leaking a continuation.
///
/// State machine:
/// - Start: `token == nil`, `cancelledBeforeUnregister == false`.
/// - Registration completes first: `set(token)` stores it; later
///   termination calls `takeForUnregister()` and the broadcaster sees
///   the unregister.
/// - Termination first: `takeForUnregister()` returns nil and flips
///   `cancelledBeforeRegister = true`; once registration completes it
///   reads that flag and unregisters itself.
private actor TokenBox {
    private var token: UUID?
    private(set) var cancelledBeforeRegister: Bool = false
    private var taken: Bool = false

    func set(_ value: UUID) {
        token = value
    }

    func takeForUnregister() -> UUID? {
        guard !taken else { return nil }
        taken = true
        if let token { return token }
        cancelledBeforeRegister = true
        return nil
    }
}
