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
import MatronViewModels

/// Task 11 (Phase 7): wires the iOS app onto the matron-journal stack
/// instead of the Matrix SDK. One `JournalCore` (API client + local SQLite
/// mirror + sync engine) is built per signed-in session; every per-session
/// / per-room service factory below is a thin wrapper over the same core so
/// the sync engine, the store, and the API client stay singletons for the
/// session's lifetime — same motivation as the pre-journal
/// `syncCache`/`mediaCache`/`chatCache` per-session caches this replaces.
///
/// Built entirely on the journal stack; the Matrix SDK is gone from the repo.
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
    /// lookup instead of three parallel per-session caches.
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
    /// Per-session `MediaService` cache. Task 11's journal swap dropped the
    /// old `mediaCache` when `MediaServiceLive`'s NSCache-backed instance
    /// was replaced by `JournalMediaService` — `mediaService(for:)` briefly
    /// returned a fresh instance (and a fresh empty image cache) on every
    /// call. Mirrors `cores`/`timelineCache`: one instance per signed-in
    /// session, cleared on sign-out.
    private var mediaServices: [String: any MediaService] = [:]
    /// Per-room `TimelineService` cache, bounded LRU so a long session that
    /// visits many rooms doesn't accumulate one journal timeline handle per
    /// room forever. Mirrors the pre-journal `timelineCache` — see
    /// `timelineCacheLimit`.
    private var timelineCache = LRUCache<TimelineCacheKey, JournalTimelineService>(limit: AppDependencies.timelineCacheLimit)

    init() {
        // iOS shares its journal store + search DB with the NSE via the App
        // Group container. Falls back to a tmp dir only when running outside
        // an entitlement (test runner / Previews).
        let container = StoragePaths.groupContainer
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("matron-dev")
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
        // Phase 6 (Search): the FTS index lives in the App Group container,
        // alongside the journal store, so the NSE/host share it. `try?`
        // keeps init non-throwing — a failed open just disables search.
        // Without the group entitlement (test runner / Previews) the index
        // sits beside the fallback journal container instead of being
        // silently disabled (bugbot "iOS search path mismatch").
        let searchURL = StoragePaths.searchDBPath ?? StoragePaths.searchDB(in: container)
        search = try? SearchServiceLive(databaseURL: searchURL)
    }

    /// Xcode debug builds register sandbox APNs tokens; TestFlight/App
    /// Store builds are prod. Written as a full statement body (not an
    /// inline `#if` expression) because a computed property's getter can't
    /// use `#if`/`#else` as a value-producing expression directly.
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
    /// behaviour (e.g. the scenePhase reconnect `nudge()`) downcast with
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

    /// Devices/pairing surface (Settings → Manage Devices). The session's
    /// one `JournalAPI` conforms directly; the protocol exists so the view
    /// models test against a fake.
    func devicesService(for session: UserSession) -> any DevicesProviding {
        core(for: session).api
    }

    /// New Chat surface: agent roster + `recent_folders`/`start` RPCs over
    /// the session's sync engine.
    func agentRPCService(for session: UserSession) -> any AgentRPCProviding {
        let core = core(for: session)
        return JournalAgentRPCService(api: core.api, engine: core.engine)
    }

    /// Placeholder conversation row so navigating to a just-started
    /// conversation holds even when the `start` answer beats the convo's
    /// first journal frame (the real convo_meta overwrites it).
    func prepareConversation(for session: UserSession, id: String) async {
        await core(for: session).engine.ensurePlaceholderConversation(id: id, title: "New chat")
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

    /// The parent conversation id of `convoID`, or `nil` for a top-level
    /// conversation. Backs the navigation router's decision to render a
    /// read-only sub-chat viewer vs. the full chat screen without the view
    /// layer having to parse the (opaque) child id. Synchronous store read.
    func parentConvoID(of convoID: String, for session: UserSession) -> String? {
        try? core(for: session).store.parentConvoID(of: convoID)
    }

    /// Whether `convoID` is a subagent child (has a parent). See
    /// `parentConvoID(of:for:)`.
    func isSubChat(_ convoID: String, for session: UserSession) -> Bool {
        parentConvoID(of: convoID, for: session) != nil
    }

    /// Test seam: how many distinct rooms the timeline cache holds before
    /// LRU eviction begins. Visible to `AppDependenciesTests` so the
    /// eviction invariant is asserted against a stable bound.
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
    /// state. Callers (`MatronApp`) drop their `session` state regardless
    /// so the UI flips to the SignInView.
    ///
    /// Each core's teardown runs as one sequenced `Task` — best-effort push
    /// deregistration first (while the API still holds a valid token),
    /// then `endSync()` to stop the engine from writing to the store, and
    /// only then `store.wipe()` — so the wipe can never race a still-running
    /// sync write. The `Task` closes over its own `core` reference, so it's
    /// safe to clear `cores`/`timelineCache` synchronously right after.
    func signOut() {
        let oldCores = Array(cores.values)
        // One awaitable teardown task instead of fire-and-forget per core:
        // a fast re-login used to open a new sync engine against the same
        // per-user SQLite file while the old engine was still writing, and
        // the late wipe could erase freshly-synced data (bugbot "Sign-out
        // races fast re-login"). The sign-in path awaits this via
        // `awaitPendingTeardown()` before the new session's services exist.
        teardownTask = Task { [search] in
            for core in oldCores {
                // Best-effort server-side push deregistration while the API
                // still holds a valid token (Finding 3). Bounded so a dead
                // network can't hold re-login hostage to a URLSession
                // timeout — the engine/store teardown below is what
                // correctness needs; this is just hygiene.
                await Self.withTimeout(seconds: 5) { try? await core.api.unregisterPush() }
                await core.engine.endSync()          // stop the writer first…
                try? core.store.wipe()               // …then clear the mirror
            }
            // Phase 6 (Search): wipe the index so the next user can't search
            // the previous user's messages. Inside the awaited teardown so a
            // new session's indexing can't interleave with the wipe (bugbot
            // "Search wipe races indexing").
            try? await search?.wipe()
        }
        cores.removeAll()
        mediaServices.removeAll()
        timelineCache = LRUCache(limit: AppDependencies.timelineCacheLimit)
        try? auth.clearSession()
    }

    /// In-flight sign-out teardown, if any. See `signOut()`.
    private var teardownTask: Task<Void, Never>?

    /// Blocks until any pending sign-out teardown finishes. The sign-in
    /// path calls this before publishing the new session, so no new
    /// journal core can race the old one's endSync/wipe.
    func awaitPendingTeardown() async {
        await teardownTask?.value
        teardownTask = nil
    }

    /// Runs `operation`, abandoning the wait (not the work) after `seconds`.
    /// Used to bound best-effort network calls inside teardown.
    private static func withTimeout(seconds: Double, _ operation: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
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

/// Carries a binding to the chat `NavigationStack` path so descendants (the
/// running-subagent strip, the sub-chat switcher) can push a child chat or
/// switch siblings without threading a closure through every level. `nil`
/// outside the authenticated stack (previews / sign-in). The strip pushes
/// via a plain `NavigationLink`; the switcher uses this binding to REPLACE
/// the current sub-chat with a sibling (pop-then-push) so switching between
/// subagents doesn't grow the back stack.
struct ChatNavigationPathKey: EnvironmentKey {
    static let defaultValue: Binding<[String]>? = nil
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
    var chatNavigationPath: Binding<[String]>? {
        get { self[ChatNavigationPathKey.self] }
        set { self[ChatNavigationPathKey.self] = newValue }
    }
}
