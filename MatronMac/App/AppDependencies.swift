import Foundation
import SwiftUI
import MatronAuth
import MatronChat
import MatronJournal
import MatronModels
import MatronPush
import MatronSearch
import MatronStorage
import MatronSync

/// Task 12 (Phase 7): wires the Mac app onto the matron-journal stack
/// instead of the Matrix SDK. Same shape as the iOS `AppDependencies`
/// (Task 11) — one `JournalCore` (API client + local SQLite mirror + sync
/// engine) per signed-in session; every per-session / per-room service
/// factory below is a thin wrapper over the same core so the sync engine,
/// the store, and the API client stay singletons for the session's
/// lifetime — same motivation as the pre-journal
/// `syncCache`/`mediaCache`/`chatCache` per-session caches this replaces.
///
/// Matrix code still exists in `MatronShared` (Task 14 deletes it); this
/// type simply stops referencing it.
@MainActor
final class AppDependencies {
    let auth: AuthService
    /// Phase 6 (Search): the local FTS index. Optional — `nil` only if the
    /// SQLite store can't be opened (rare); the journal services all treat
    /// search as optional, so the app degrades to "search disabled" rather
    /// than failing to launch.
    let search: SearchService?

    private let sessionsDirectory: URL
    private let journalDirectory: URL

    /// One journal stack per signed-in session: the API client, the local
    /// SQLite mirror, and the sync engine that's the sole writer of that
    /// mirror. Grouping these means `core(for:)` is a single dictionary
    /// lookup instead of three parallel per-session caches. See iOS
    /// `AppDependencies.JournalCore` for the full rationale.
    final class JournalCore {
        let api: JournalAPI
        let store: JournalStore
        let engine: JournalSyncEngine
        init(api: JournalAPI, store: JournalStore, engine: JournalSyncEngine) {
            self.api = api
            self.store = store
            self.engine = engine
        }
    }

    private var cores: [String: JournalCore] = [:]
    /// Per-session `MediaService` cache. Task 11/12's journal swap dropped
    /// the old `mediaCache` when `MediaServiceLive`'s NSCache-backed
    /// instance was replaced by `JournalMediaService` — `mediaService(for:)`
    /// briefly returned a fresh instance (and a fresh empty image cache)
    /// on every call. Mirrors `cores`/`timelineCache`: one instance per
    /// signed-in session, cleared on sign-out.
    private var mediaServices: [String: any MediaService] = [:]
    /// Per-room `TimelineService` cache, bounded LRU so a long session that
    /// visits many rooms doesn't accumulate one journal timeline handle per
    /// room forever. Mirrors the pre-journal `timelineCache` — see
    /// `timelineCacheLimit`.
    private var timelineCache = LRUCache<TimelineCacheKey, JournalTimelineService>(limit: AppDependencies.timelineCacheLimit)

    init() {
        // Mac uses Application Support — single-process, no App Group.
        // `StoragePaths.appSupport` is non-optional on macOS (vs. the
        // App-Group `URL?` on iOS) and creates the directory on first
        // read, so there's no dev-environment fallback branch to write
        // here the way iOS needs one for its entitlement-less test/preview
        // runs.
        let container = StoragePaths.appSupport
        // Split the container into two sibling directories so a fresh-login
        // wipe of the journal store can never take out the persisted
        // session JSON.
        // - `journal-store` : the per-user SQLite mirror. Wiped on sign-out.
        // - `sessions`       : FileSessionStore lives here. Never wiped.
        sessionsDirectory = container.appendingPathComponent("sessions")
        journalDirectory = container.appendingPathComponent("journal-store")
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)

        auth = JournalAuthService(sessionStore: FileSessionStore(directory: sessionsDirectory))
        // Phase 6 (Search): FTS index in Application Support, alongside the
        // journal store. `try?` keeps init non-throwing — a failed open
        // just disables search. `searchDBPath` is a non-optional URL on
        // macOS (vs. the App-Group optional on iOS) — it resolves under
        // the same `appSupport` dir as `container`.
        search = try? SearchServiceLive(databaseURL: StoragePaths.searchDBPath)
    }

    /// Debug builds register sandbox APNs tokens; TestFlight/App Store
    /// builds are prod. See iOS `AppDependencies.pushEnvironment` for why
    /// this is a full statement body rather than an inline `#if`
    /// expression.
    private var pushEnvironment: JournalAPI.PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .prod
        #endif
    }

    /// Builds (or returns the cached) journal stack for `session`. A store
    /// that fails to open is unrecoverable dev-time config; crashing loudly
    /// here is preferable to limping along with a `nil` store that every
    /// caller would have to null-check.
    private func core(for session: UserSession) -> JournalCore {
        if let existing = cores[session.userID] { return existing }
        let api = JournalAPI(serverURL: session.homeserverURL, token: session.accessToken)
        let dbURL = journalDirectory.appendingPathComponent("\(session.userID).sqlite")
        let store = try! JournalStore(databaseURL: dbURL, ownSender: "user:\(session.userID)")
        let engine = JournalSyncEngine(
            api: api, store: store,
            connector: URLSessionWebSocketConnector(),
            token: session.accessToken,
            ownSender: "user:\(session.userID)", search: search
        )
        let core = JournalCore(api: api, store: store, engine: engine)
        cores[session.userID] = core
        return core
    }

    /// `any SyncService` (not `JournalSyncEngine` directly) so existing
    /// view code calling `sync.start()` / `.stateStream()` keeps working
    /// unchanged — `JournalSyncEngine` conforms via the
    /// `JournalSyncConformance.swift` shim. Callers that need engine-only
    /// behaviour (e.g. the foreground reconnect nudge) downcast with
    /// `as? JournalSyncEngine`.
    func syncService(for session: UserSession) -> any SyncService { core(for: session).engine }

    func chatService(for session: UserSession) -> any ChatService {
        let core = core(for: session)
        return JournalChatService(store: core.store, engine: core.engine)
    }

    func mediaService(for session: UserSession) -> any MediaService {
        if let existing = mediaServices[session.userID] { return existing }
        let service = JournalMediaService(api: core(for: session).api)
        mediaServices[session.userID] = service
        return service
    }

    func pushService(for session: UserSession) -> any PushService {
        JournalPushService(api: core(for: session).api, environment: pushEnvironment)
    }

    /// Per-room `TimelineService` factory. Cached by `(userID, roomID)` so
    /// repeat navigations to the same room re-use the same journal timeline
    /// handle instead of rebuilding the overlay state from scratch.
    func timelineService(for session: UserSession, roomID: String) -> any TimelineService {
        let key = TimelineCacheKey(userID: session.userID, roomID: roomID)
        if let cached = timelineCache[key] { return cached }
        let core = core(for: session)
        let service = JournalTimelineService(
            convoID: roomID, store: core.store, engine: core.engine,
            api: core.api, session: session, search: search
        )
        timelineCache[key] = service
        return service
    }

    /// Test seam: how many distinct rooms the timeline cache holds before
    /// LRU eviction begins. See iOS `AppDependencies.timelineCacheLimit`.
    static let timelineCacheLimit = 16

    /// Test seam: number of entries currently held by the timeline cache.
    var timelineCacheCount: Int { timelineCache.count }

    /// Test seam: whether the timeline cache currently holds an entry for
    /// `(userID, roomID)`.
    func timelineCacheContains(userID: String, roomID: String) -> Bool {
        timelineCache.contains(TimelineCacheKey(userID: userID, roomID: roomID))
    }

    /// Sign-out path. Ends every session's sync engine, wipes its local
    /// journal mirror, clears every per-session/per-room cache, wipes the
    /// search index, and drops the persisted auth session so a subsequent
    /// `restoreSession()` returns `nil` and a fresh login lands in a clean
    /// state. Callers (`MatronMacApp`) drop their `session` state regardless
    /// so the UI flips to the sign-in view.
    ///
    /// Each core's teardown runs as one sequenced `Task` — best-effort push
    /// deregistration first (while the API still holds a valid token),
    /// then `endSync()` to stop the engine from writing to the store, and
    /// only then `store.wipe()` — so the wipe can never race a still-running
    /// sync write. The `Task` closes over its own `core` reference, so it's
    /// safe to clear `cores`/`timelineCache` synchronously right after. See
    /// iOS `AppDependencies.signOut()` for the full rationale (that task's
    /// follow-up fix — mirrored here from the start).
    func signOut() {
        for core in cores.values {
            Task {
                // Best-effort server-side push deregistration while the API
                // still holds a valid token.
                try? await core.api.unregisterPush()
                await core.engine.endSync()          // stop the writer first…
                try? core.store.wipe()               // …then clear the mirror
            }
        }
        cores.removeAll()
        mediaServices.removeAll()
        timelineCache = LRUCache(limit: AppDependencies.timelineCacheLimit)
        // Phase 6 (Search): wipe the index so the next user can't search the
        // previous user's messages. `search` is a `let` (the same DB
        // instance persists across sign-out → sign-in); signOut is
        // synchronous so the wipe runs in a detached Task.
        Task { [search] in try? await search?.wipe() }
        try? auth.clearSession()
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
