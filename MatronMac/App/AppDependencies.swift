import Foundation
import SwiftUI
import MatronAuth
import MatronChat
import MatronModels
import MatronSearch
import MatronStorage
import MatronSync
import MatronVerification

@MainActor
final class AppDependencies {
    let auth: AuthService
    let clientProvider: ClientProvider
    /// Phase 6 (Search): local FTS index. Optional — see iOS `AppDependencies`
    /// for the graceful-degradation rationale.
    let search: SearchService?

    private var syncCache: [String: SyncService] = [:]
    /// Per-session `VerificationServiceLive` cache. Mirrors the iOS
    /// `AppDependencies.verificationCache` — every consumer (sidebar
    /// banner, per-bot MacChatView banner, MacDeviceSettingsView, post-
    /// login gate, Help → Verify This Device…, Help → Show Recovery Key…)
    /// shares the SAME FlowStore + the SAME registered SDK delegate.
    private var verificationCache: [String: VerificationServiceLive] = [:]
    /// Per-session `MediaService` cache. See iOS `AppDependencies` for the
    /// full rationale — `MediaServiceLive` owns a 64 MB `NSCache` for
    /// resolved `mxc://` bytes, and a fresh instance per call defeats it.
    private var mediaCache: [String: MediaService] = [:]
    /// Per-session `ChatService` cache — see iOS `AppDependencies`
    /// for the full Phase 2.5 broadcaster-singleton rationale.
    private var chatCache: [String: ChatService] = [:]
    /// Per-room timeline cache keyed by `(userID, roomID)`. Re-using the
    /// same `TimelineServiceLive` across detail-column transitions
    /// preserves the SDK timeline handle and the in-memory snapshot the
    /// diff listener has built up — re-creating would force the listener
    /// to rebuild from scratch and flicker the UI on every selection
    /// change. Mirrors the iOS `AppDependencies` strategy.
    ///
    /// Bounded with an LRU cap (`timelineCacheLimit`) so a long session
    /// that flips between many sidebar rooms doesn't accumulate one SDK
    /// timeline handle per room forever. See iOS `AppDependencies` for
    /// the full rationale.
    private var timelineCache: LRUCache<TimelineCacheKey, TimelineService> = .init(limit: AppDependencies.timelineCacheLimit)
    /// Per-session `BackfillCoordinator` cache — see iOS `AppDependencies`.
    private var backfillCache: [String: BackfillCoordinator] = [:]

    init() {
        // Mac uses Application Support — single-process, no App Group.
        // StoragePaths.appSupport creates the directory on first read.
        let container = StoragePaths.appSupport

        // Split the container into two sibling directories so a fresh-login
        // wipe of the SDK store can never take out the persisted session JSON.
        // See the iOS AppDependencies for the full rationale.
        let sdkStore = container.appendingPathComponent("sdk-store")
        let sessionsDir = container.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: sdkStore, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Phase 1 uses a file-backed session store on Mac for symmetry with
        // iOS. Phase 3 will switch to Keychain when signing is settled.
        let sessionStore = FileSessionStore(directory: sessionsDir)
        self.auth = AuthServiceLive(sessionStore: sessionStore, basePath: sdkStore)
        self.clientProvider = ClientProvider(basePath: sdkStore)
        // Phase 6 (Search): FTS index in Application Support, alongside the
        // crypto store. `try?` keeps init non-throwing (search disabled on a
        // failed open). On Mac there's no file-protection class — FileVault
        // covers encryption at rest (SearchSchema gates that block to iOS).
        // `searchDBPath` is a non-optional URL on macOS (vs. the App-Group
        // optional on iOS) — it resolves under the same `appSupport` dir as
        // `container`.
        self.search = try? SearchServiceLive(databaseURL: StoragePaths.searchDBPath)
    }

    func syncService(for session: UserSession) -> SyncService {
        if let existing = syncCache[session.userID] { return existing }
        let svc = SyncServiceLive(provider: clientProvider, session: session)
        syncCache[session.userID] = svc
        return svc
    }

    /// Per-session `VerificationServiceLive` factory. See iOS
    /// `AppDependencies.verificationService(for:)` for the full caching
    /// rationale (shared FlowStore + shared registered delegate).
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
    /// 64 MB `NSCache` inside `MediaServiceLive` is shared across rooms.
    /// See iOS `AppDependencies` for the full rationale.
    func mediaService(for session: UserSession) -> MediaService {
        if let existing = mediaCache[session.userID] { return existing }
        let svc = MediaServiceLive(provider: clientProvider, session: session)
        mediaCache[session.userID] = svc
        return svc
    }

    /// Per-room `TimelineService` factory. See iOS `AppDependencies` for
    /// the full caching rationale (now bounded by `timelineCacheLimit`).
    func timelineService(for session: UserSession, roomID: String) -> TimelineService {
        let key = TimelineCacheKey(userID: session.userID, roomID: roomID)
        if let existing = timelineCache[key] { return existing }
        let svc = TimelineServiceLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session),
            roomID: roomID,
            search: search
        )
        timelineCache[key] = svc
        return svc
    }

    /// Per-session `BackfillCoordinator`, or `nil` when search is disabled.
    /// See iOS `AppDependencies.backfillCoordinator(for:)`.
    func backfillCoordinator(for session: UserSession) -> BackfillCoordinator? {
        guard let search else { return nil }
        if let existing = backfillCache[session.userID] { return existing }
        let pager = TimelinePagerLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session)
        )
        let runner = BackfillRunner(timeline: pager, search: search)
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let coordinator = BackfillCoordinator(runner: runner, cutoff: cutoff)
        backfillCache[session.userID] = coordinator
        return coordinator
    }

    /// Test seam — see iOS `AppDependencies.timelineCacheLimit` for the
    /// rationale and the eviction invariant.
    static let timelineCacheLimit = 16

    /// Test seam — see iOS `AppDependencies.timelineCacheCount`.
    var timelineCacheCount: Int { timelineCache.count }

    /// Test seam — see iOS `AppDependencies.timelineCacheContains(...)`.
    func timelineCacheContains(userID: String, roomID: String) -> Bool {
        timelineCache.contains(TimelineCacheKey(userID: userID, roomID: roomID))
    }

    /// Sign-out path — see iOS `AppDependencies.signOut()` for the full
    /// rationale. Wipes the persisted session and clears every
    /// per-session cache so a subsequent `restoreSession()` returns
    /// nil and a fresh login lands in a clean state.
    func signOut() {
        try? auth.clearSession()
        syncCache.removeAll()
        verificationCache.removeAll()
        mediaCache.removeAll()
        chatCache.removeAll()
        timelineCache = .init(limit: AppDependencies.timelineCacheLimit)
        backfillCache.removeAll()
        // Phase 6 (Search): wipe the index on sign-out — see iOS AppDependencies
        // for the race rationale. On Mac this clears
        // ~/Library/Application Support/chat.matron.mac/matron-search.sqlite.
        // Stored so the next session's backfill awaits it before sweeping
        // (bugbot "Sign-out wipe races login").
        pendingIndexWipe = Task { [search] in try? await search?.wipe() }
    }

    /// The in-flight `signOut()` index wipe — see iOS `AppDependencies`.
    private var pendingIndexWipe: Task<Void, Never>?

    /// Awaits any in-flight sign-out index wipe so backfill never runs against
    /// a half-wiped DB (bugbot "Sign-out wipe races login").
    func awaitPendingIndexWipe() async {
        await pendingIndexWipe?.value
    }
}

// MARK: - SwiftUI Environment

/// Environment key carrying the app-wide `AppDependencies` (Mac). The Mac
/// `AppDependencies` is a separate type from the iOS one — they share
/// service-layer code via `MatronShared`, but the per-platform glue
/// (storage container, entitlements) differs.
struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

/// Environment key carrying the current authenticated `UserSession`.
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
