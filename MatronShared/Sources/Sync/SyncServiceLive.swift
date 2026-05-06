import Foundation
import MatrixRustSDK
import MatronModels

/// Errors thrown by `SyncServiceLive.waitUntilReady()` when sync fails to
/// reach `.running` within a reasonable window.
public enum SyncReadyError: Error, Equatable {
    case timeout
    case terminated
    case errored
}

public actor SyncServiceLive: SyncService {
    /// How long `waitUntilReady()` will wait before throwing `.timeout`. Set
    /// to a generous bound so a slow first sync against a real homeserver
    /// still resolves; long enough that an unreachable server surfaces an
    /// error rather than a perpetual "Connecting…" spinner.
    public static let readyTimeout: TimeInterval = 30

    private let provider: ClientProvider
    private let session: UserSession
    private var sdkSyncService: MatrixRustSDK.SyncService?
    private var stateHandle: TaskHandle?
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var ready: Bool = false
    /// Once we've ever reached `.running`, terminal states like `.error` /
    /// `.terminated` won't fail subsequent waiters — the SDK auto-recovers.
    /// Until then, terminal states are surfaced as thrown errors so the UI
    /// doesn't hang on "Connecting…".
    private var hasEverBeenRunning: Bool = false
    /// Latest user-facing state replayed to every new `stateStream()`
    /// subscriber. Pre-`start()` we report `.connecting` so the banner
    /// shows the right thing on initial app open before sliding sync has
    /// even been kicked off.
    private var currentState: SyncConnectionState = .connecting
    /// Active stream subscribers, keyed by a per-subscription token so
    /// we can drop one cleanly when its consumer's `for await` cancels
    /// (without that, a long-running session accumulates inert finished
    /// continuations every time a chat-list view is recycled). On
    /// `stop()` they're all finished so consumer loops exit. Storing
    /// `Sendable` continuations directly is fine because this actor's
    /// isolation already serialises mutation.
    private var stateContinuations: [UInt64: AsyncStream<SyncConnectionState>.Continuation] = [:]
    private var nextStateToken: UInt64 = 0
    /// Backoff for the auto-restart driven by `.error` / `.terminated`.
    /// matrix-rust-sdk's `SyncService` does NOT auto-recover from those
    /// states — once it hits them sync is dead until `.start()` is called
    /// again. Without this restarter the chat list silently goes stale
    /// after the first DNS blip / wake-from-sleep / network change. We
    /// observed a Mac session run fine for 14 minutes, hit a single DNS
    /// error after the laptop came back from sleep, and then sit
    /// permanently with no sync_once until the user force-quits the app.
    private var restartTask: Task<Void, Never>?
    /// Doubles each consecutive failure so a persistently-broken server
    /// doesn't get hammered. Reset to `restartBaseDelay` on every
    /// `.running`. Caps at `restartMaxDelay`.
    private var restartDelay: TimeInterval = SyncServiceLive.restartBaseDelay
    private static let restartBaseDelay: TimeInterval = 2
    private static let restartMaxDelay: TimeInterval = 60

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func start() async throws {
        guard sdkSyncService == nil else { return }
        let client = try await provider.client(for: session)
        let svc = try await client.syncService().finish()

        // Attach state observer BEFORE start so we don't miss the .running
        // transition. Calling RoomListService methods before .running crashes
        // BaseStateStore::rooms_stream because the state store hasn't been
        // populated yet.
        let observer = StateObserver { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateChange(state) }
        }
        stateHandle = svc.state(listener: observer)
        await svc.start()
        sdkSyncService = svc
    }

    public func stop() async {
        // Cancel a pending auto-restart so a sign-out doesn't get
        // re-armed by the SDK firing one last `.error` on its way down.
        restartTask?.cancel()
        restartTask = nil
        restartDelay = Self.restartBaseDelay
        if let svc = sdkSyncService {
            await svc.stop()
        }
        sdkSyncService = nil
        stateHandle = nil
        ready = false
        // Drop every connection-state subscriber — banner consumers
        // exit their `for await` loops cleanly. `currentState` resets
        // to `.connecting` so a fresh `start()` after sign-in/-out
        // doesn't replay a stale `.running` to a new subscriber.
        let conts = stateContinuations.values
        stateContinuations.removeAll()
        for cont in conts { cont.finish() }
        currentState = .connecting
    }

    public var isRunning: Bool { sdkSyncService != nil }

    public func stateStream() -> AsyncStream<SyncConnectionState> {
        let token = nextStateToken
        nextStateToken &+= 1
        let snapshot = currentState
        return AsyncStream { continuation in
            // Replay current state so the View doesn't render an empty
            // banner on first subscribe — it always knows the truth as
            // of "now". Subsequent transitions fan out via
            // `setState(_:)`'s broadcast (one yield per active token).
            continuation.yield(snapshot)
            stateContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token: token) }
            }
        }
    }

    /// Drops a terminated continuation. Called by `onTermination` when a
    /// consumer cancels their `for await` (chat-list view goes away)
    /// so the dictionary doesn't accumulate inert entries across
    /// long-running sessions.
    private func removeContinuation(token: UInt64) {
        stateContinuations.removeValue(forKey: token)
    }

    /// Updates `currentState` and broadcasts the new value to every
    /// active subscriber. Called from `handleStateChange(_:)` when the
    /// SDK observer fires a transition that maps to a different
    /// user-facing state. Idempotent — repeated yields of the same
    /// state are filtered out so the banner doesn't churn.
    private func setState(_ next: SyncConnectionState) {
        guard next != currentState else { return }
        currentState = next
        for cont in stateContinuations.values { cont.yield(next) }
    }

    public func waitUntilReady() async throws {
        if ready { return }
        // Spawn a watchdog that fails any waiter still in the queue after the
        // timeout window expires. Cancelled if .running fires first.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readyTimeout * 1_000_000_000))
            await self?.failPendingWaiters(with: SyncReadyError.timeout)
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }

    public func sdkService() -> MatrixRustSDK.SyncService? {
        sdkSyncService
    }

    private func handleStateChange(_ state: SyncServiceState) {
        switch state {
        case .running:
            hasEverBeenRunning = true
            setState(.running)
            // Successful run resets the auto-restart backoff so the next
            // blip starts from `restartBaseDelay`, not whatever we'd
            // climbed to during a long outage.
            restartDelay = Self.restartBaseDelay
            guard !ready else { return }
            ready = true
            let waiters = readyContinuations
            readyContinuations.removeAll()
            for cont in waiters { cont.resume() }
        case .error:
            // Pre-`.running`: surface a thrown error to anyone awaiting
            // `waitUntilReady()` so the UI doesn't hang on "Connecting…".
            // Don't auto-restart here — the SDK fires `.error` for
            // permanently-misconfigured connections too, and an infinite
            // restart loop would burn battery and login attempts.
            if !hasEverBeenRunning {
                failPendingWaiters(with: SyncReadyError.errored)
                setState(.offline(reason: "Connection error"))
                return
            }
            // Mid-session: matrix-rust-sdk does NOT auto-recover from
            // `.error`. The SDK's sync_once loop terminates and never
            // resumes until we call `.start()` again. Surface the
            // outage to the banner and queue a backoff'd restart.
            setState(.offline(reason: "Connection error"))
            scheduleAutoRestart()
        case .terminated:
            if !hasEverBeenRunning {
                failPendingWaiters(with: SyncReadyError.terminated)
                setState(.offline(reason: "Sync terminated"))
                return
            }
            // Same shape as `.error` — terminal mid-session, needs an
            // explicit restart. Common trigger: laptop sleep + wake.
            setState(.offline(reason: "Sync terminated"))
            scheduleAutoRestart()
        case .offline:
            // The SDK reports .offline when it can't reach the server.
            // Surface to the banner regardless of `hasEverBeenRunning`
            // — an offline blip mid-session is a real signal the user
            // wants to see ("you're offline; messages won't send"),
            // unlike a transient error that the SDK transparently
            // retries. setState filters out duplicate yields so a
            // flapping connection doesn't spam the banner.
            setState(.offline(reason: "Offline"))
        case .idle:
            // .idle is the SDK's pre-`.running` transient. Banner
            // already says .connecting — leave it there.
            break
        }
    }

    private func failPendingWaiters(with error: Error) {
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume(throwing: error) }
    }

    /// Queue a single-flight restart on the actor. If a restart is
    /// already pending we leave it alone — the SDK can fire several
    /// `.error` transitions in a row (one per sub-channel) and we don't
    /// want each one stacking another sleep+restart.
    private func scheduleAutoRestart() {
        if let task = restartTask, !task.isCancelled { return }
        let delay = restartDelay
        // Climb the backoff for the *next* failure; the current attempt
        // uses `delay` already snapshotted. Reset happens on `.running`.
        restartDelay = min(restartDelay * 2, Self.restartMaxDelay)
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            await self.performAutoRestart()
        }
    }

    private func performAutoRestart() async {
        restartTask = nil
        // If the consumer signed out or already nudged sync back to
        // `.running` while we were sleeping, drop the restart.
        guard let svc = sdkSyncService else { return }
        if currentState == .running { return }
        await svc.start()
    }
}

private final class StateObserver: SyncServiceStateObserver {
    private let onState: @Sendable (SyncServiceState) -> Void
    init(_ onState: @escaping @Sendable (SyncServiceState) -> Void) { self.onState = onState }
    func onUpdate(state: SyncServiceState) { onState(state) }
}
