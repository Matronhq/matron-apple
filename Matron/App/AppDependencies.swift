import Foundation
import SwiftUI
import MatronAuth
import MatronChat
import MatronModels
import MatronStorage
import MatronSync
import MatronVerification

@MainActor
final class AppDependencies {
    let auth: AuthService
    let clientProvider: ClientProvider

    private var syncCache: [String: SyncService] = [:]
    /// Per-session `VerificationServiceLive` cache. The service owns the
    /// FlowStore (in-flight SAS controllers + open `AsyncStream` continuations)
    /// AND the registered `LiveSessionVerificationDelegate`. Returning a fresh
    /// instance every call would (a) hand the SAS UI an empty FlowStore so
    /// `acceptIncoming(requestID:)` would immediately yield
    /// `.cancelled("Unknown request: …")`, and (b) fail to register the
    /// delegate so `incomingRequests()` would never produce. Caching per
    /// `userID` mirrors `syncCache`.
    private var verificationCache: [String: VerificationServiceLive] = [:]
    /// Per-session `MediaService` cache. `MediaServiceLive` owns its own
    /// 64 MB `NSCache` for resolved `mxc://` bytes; returning a fresh
    /// instance every call (the prior behaviour) defeated that cache and
    /// re-fetched the same image bytes on every view re-render. Caching
    /// per `userID` keeps the cache shared across rooms in a session.
    private var mediaCache: [String: MediaService] = [:]
    /// Per-session `ChatService` cache. `ChatServiceLive` owns the
    /// shared `ChatSummaryBroadcaster` and the `BootstrapState` that
    /// holds the single upstream `RoomListSubscription` (Phase 2.5
    /// fan-out design). Without this cache, every consumer
    /// (`ChatListViewModel.start()`, `NewChatSheet.loadBots()`, etc.)
    /// would build its own `ChatServiceLive` → its own broadcaster →
    /// its own `entriesWithDynamicAdapters` listener, which exactly
    /// defeats the singleton design the broadcaster was added to enable.
    private var chatCache: [String: ChatService] = [:]
    /// Per-room timeline cache keyed by `(userID, roomID)`. Re-using the
    /// same `TimelineServiceLive` across navigations to the same room
    /// preserves the SDK timeline handle and the in-memory snapshot the
    /// diff listener has built up — re-creating would cause a UI flicker
    /// on every push/pop.
    ///
    /// Bounded with an LRU cap (`timelineCacheLimit`) so a long session
    /// that visits many rooms doesn't accumulate one SDK timeline handle
    /// (+ in-memory snapshot) per room forever. `mediaCache` and
    /// `syncCache` are bounded by user-count, but the timeline cache
    /// scales with rooms-visited, which is unbounded over a session.
    /// 16 entries comfortably covers the recently-active rooms most users
    /// flip between; older entries fall out and are reconstructed on next
    /// visit (a cheap rebuild from the SDK's persisted store).
    private var timelineCache: LRUCache<TimelineCacheKey, TimelineService> = .init(limit: AppDependencies.timelineCacheLimit)

    init() {
        // iOS shares its crypto store + search DB with the NSE via the App
        // Group container. Falls back to a tmp dir only when running outside
        // an entitlement (test runner / Previews).
        let container: URL
        #if os(iOS)
        container = (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: StoragePaths.appGroupIdentifier))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
        #else
        container = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
        #endif
        // Split the container into two sibling directories so a fresh-login
        // wipe of the SDK store can never take out the persisted session JSON.
        // - `sdkStore`  : SDK's SQLite + crypto store. Wiped before each login.
        // - `sessions`  : FileSessionStore lives here. Never wiped during login.
        let sdkStore = container.appendingPathComponent("sdk-store")
        let sessionsDir = container.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sdkStore, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Phase 1 uses a file-backed session store rather than Keychain. The
        // iOS Simulator rejects keychain-access-groups entitlements without a
        // signing team, and ad-hoc signing strips them. Phase 3 (verification
        // / recovery key) will add a SessionStore that picks Keychain when
        // entitlements resolve and falls back to file storage otherwise.
        let sessionStore = FileSessionStore(directory: sessionsDir)
        self.auth = AuthServiceLive(sessionStore: sessionStore, basePath: sdkStore)
        self.clientProvider = ClientProvider(basePath: sdkStore)
    }

    func syncService(for session: UserSession) -> SyncService {
        if let existing = syncCache[session.userID] { return existing }
        let svc = SyncServiceLive(provider: clientProvider, session: session)
        syncCache[session.userID] = svc
        return svc
    }

    /// Per-session `VerificationServiceLive` factory. Cached by `session.userID`
    /// so every consumer (chat-list banner, per-bot ChatView banner, Settings
    /// → Device, post-login gate, Mac Help menu) shares the SAME FlowStore
    /// + the SAME registered SDK delegate. Without this cache, each
    /// inline `VerificationServiceLive(...)` construction would have its
    /// own empty FlowStore (so any `acceptIncoming(requestID:)` would yield
    /// `.cancelled("Unknown request: …")`) AND its own un-registered
    /// delegate (so `incomingRequests()` would never produce). Mirrors the
    /// `syncCache` per-session strategy.
    ///
    /// `start()` must still be called on the returned service to fetch the
    /// SDK's session-verification controller and register the delegate; the
    /// cache only guarantees identity, not lifecycle. `MatronApp` drives
    /// `start()` from a `.task` block alongside `syncService.start()`.
    func verificationService(for session: UserSession) -> VerificationServiceLive {
        if let existing = verificationCache[session.userID] { return existing }
        let svc = VerificationServiceLive(provider: clientProvider, session: session)
        verificationCache[session.userID] = svc
        return svc
    }

    func chatService(for session: UserSession) -> ChatService {
        if let existing = chatCache[session.userID] { return existing }
        let svc = ChatServiceLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session)
        )
        chatCache[session.userID] = svc
        return svc
    }

    /// SDK-backed `MediaService` that resolves `mxc://` URLs into bytes via
    /// `Client.getMediaContent`. Cached per `session.userID` so the
    /// 64 MB `NSCache` inside `MediaServiceLive` is shared across rooms
    /// for the lifetime of the session — mirrors the `syncCache` strategy.
    func mediaService(for session: UserSession) -> MediaService {
        if let existing = mediaCache[session.userID] { return existing }
        let svc = MediaServiceLive(provider: clientProvider, session: session)
        mediaCache[session.userID] = svc
        return svc
    }

    /// Per-room `TimelineService` factory. Cached by `(userID, roomID)` so
    /// repeat navigations to the same room re-use the same SDK timeline
    /// handle — that handle owns the in-memory snapshot, so re-creating
    /// it would force the row diff listener to rebuild from scratch and
    /// flicker the UI on every push/pop. Mirrors the `syncCache`
    /// per-session strategy, but bounded by `timelineCacheLimit` LRU
    /// entries so the cache doesn't grow unbounded with rooms-visited.
    func timelineService(for session: UserSession, roomID: String) -> TimelineService {
        let key = TimelineCacheKey(userID: session.userID, roomID: roomID)
        if let existing = timelineCache[key] { return existing }
        let svc = TimelineServiceLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session),
            roomID: roomID
        )
        timelineCache[key] = svc
        return svc
    }

    /// Test seam: how many distinct rooms the timeline cache holds before
    /// LRU eviction begins. Visible to `AppDependenciesTests` so the
    /// eviction invariant is asserted against a stable bound.
    static let timelineCacheLimit = 16

    /// Test seam: number of entries currently held by the timeline cache.
    /// Used by `AppDependenciesTests` to verify the LRU bound holds after
    /// a barrage of distinct rooms.
    var timelineCacheCount: Int { timelineCache.count }

    /// Test seam: whether the timeline cache currently holds an entry for
    /// `(userID, roomID)`. The cached value type is a protocol so we
    /// can't expose it directly without leaking concrete `TimelineService`
    /// identity — this boolean is enough to assert eviction.
    func timelineCacheContains(userID: String, roomID: String) -> Bool {
        timelineCache.contains(TimelineCacheKey(userID: userID, roomID: roomID))
    }

    /// Sign-out path. Wipes the persisted session on disk and clears every
    /// per-session cache so a subsequent `restoreSession()` returns nil
    /// and a fresh login lands in a clean state.
    ///
    /// Errors thrown by `auth.clearSession()` are ignored — typical
    /// failure mode is "no session file to delete," which is exactly
    /// what we want post sign-out. Callers (`MatronApp`) drop their
    /// `session` state regardless so the UI flips to the SignInView.
    /// Per-session caches (`syncCache`, `mediaCache`, `timelineCache`)
    /// are cleared so the next login doesn't reuse stale handles bound
    /// to the previous user's SDK state.
    func signOut() {
        try? auth.clearSession()
        syncCache.removeAll()
        verificationCache.removeAll()
        mediaCache.removeAll()
        chatCache.removeAll()
        timelineCache = .init(limit: AppDependencies.timelineCacheLimit)
    }
}

// MARK: - SwiftUI Environment

/// Environment key carrying the app-wide `AppDependencies`. Defaulting to
/// `nil` keeps preview/test sites compile-clean without a fake stack;
/// production usage in `MatronApp` always injects a real instance.
struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

/// Environment key carrying the current authenticated `UserSession`. Set
/// by `MatronApp` after sign-in succeeds; read by views that construct
/// per-session services (timeline, media, chat-actions).
struct CurrentSessionKey: EnvironmentKey {
    static let defaultValue: UserSession? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
    var currentSession: UserSession? {
        get { self[CurrentSessionKey.self] }
        set { self[CurrentSessionKey.self] = newValue }
    }
}
