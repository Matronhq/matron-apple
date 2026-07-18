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

/// Task 12 (Phase 7): wires the Mac app onto the matron-journal stack
/// instead of the Matrix SDK. Same shape as the iOS `AppDependencies`
/// (Task 11) — one `JournalCore` (API client + local SQLite mirror + sync
/// engine) per signed-in session; every per-session / per-room service
/// factory below is a thin wrapper over the same core so the sync engine,
/// the store, and the API client stay singletons for the session's
/// lifetime — same motivation as the pre-journal
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

    /// The parent conversation id of `convoID`, or `nil` for a top-level
    /// conversation. Lets the detail column decide whether to open a
    /// subagent child in the split pane without parsing the (opaque) child
    /// id. Synchronous store read.
    func parentConvoID(of convoID: String, for session: UserSession) -> String? {
        try? core(for: session).store.parentConvoID(of: convoID)
    }

    /// Whether `convoID` is a subagent child (has a parent).
    func isSubChat(_ convoID: String, for session: UserSession) -> Bool {
        parentConvoID(of: convoID, for: session) != nil
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

    /// Devices/pairing surface (Settings → Devices). The session's one
    /// `JournalAPI` conforms directly; the protocol exists so the view
    /// models test against a fake.
    func devicesService(for session: UserSession) -> any DevicesProviding {
        core(for: session).api
    }

    /// Show-QR surface (Settings → Link a Device). Same session-scoped
    /// `JournalAPI` as the devices surface; protocol slice for testability.
    func deviceLinkService(for session: UserSession) -> any DeviceLinking {
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
    /// Teardown runs as ONE awaitable task — bounded best-effort push
    /// deregistration, then `endSync()` to stop the engine from writing to
    /// the store, and only then `store.wipe()` — so the wipe can never race
    /// a still-running sync write, and a fast re-login can't open a second
    /// writer on the same SQLite file (`awaitPendingTeardown()` gates the
    /// new session). Mirrors iOS `AppDependencies.signOut()`.
    func signOut() {
        let oldCores = Array(cores.values)
        // Chain onto any previous teardown: `sign out A → re-login →
        // sign out B` overwrote `teardownTask` while A's endSync/wipe on
        // A's cores might still be running, and `awaitPendingTeardown()`
        // would then wait only for B — a new sign-in could race A's still-
        // running wipe on the same on-disk SQLite (bugbot "Sign-out drops
        // prior teardown job"). Awaiting `previous` first serialises every
        // teardown. The bumped generation lets `awaitPendingTeardown()`
        // notice a task chained while it was suspended. Mirrors iOS.
        let previous = teardownTask
        teardownGeneration &+= 1
        teardownTask = Task { [search] in
            await previous?.value
            for core in oldCores {
                await Self.withTimeout(seconds: 5) { try? await core.api.unregisterPush() }
                await core.engine.endSync()          // stop the writer first…
                try? core.store.wipe()               // …then clear the mirror
            }
            // Inside the awaited teardown so a new session's indexing can't
            // interleave with the wipe (bugbot "Search wipe races indexing").
            try? await search?.wipe()
        }
        cores.removeAll()
        mediaServices.removeAll()
        timelineCache = LRUCache(limit: AppDependencies.timelineCacheLimit)
        try? auth.clearSession()
    }

    /// In-flight (or most-recent) sign-out teardown, if any. See `signOut()`.
    /// Deliberately held even after completion (never nilled out — see
    /// `awaitPendingTeardown()`); awaiting an already-finished task is
    /// instantly satisfied, so the retained value is not a leak.
    private var teardownTask: Task<Void, Never>?

    /// Monotonically increasing generation stamped each time `signOut()`
    /// stores a `teardownTask`. `awaitPendingTeardown()` reads it before and
    /// after its `await` to tell whether a newer teardown was chained on
    /// while it was suspended — `Task` is a value type, so identity can't be
    /// compared with `===`; a strictly-increasing counter is the identity.
    /// `AppDependencies` is `@MainActor`, so counter reads/writes are
    /// serialised; the only interleaving is across the `await` suspension.
    private var teardownGeneration = 0

    /// Blocks until any pending sign-out teardown finishes. The sign-in
    /// path calls this before publishing the new session, so no new
    /// journal core can race the old one's endSync/wipe.
    ///
    /// Loops so that a `signOut()` chaining a newer teardown *while this is
    /// suspended* is also waited for. The stored task is read-only here —
    /// nulling it after the `await` (as an earlier version did) could drop a
    /// just-chained teardown, letting a later sign-in skip its wipe (bugbot
    /// "Teardown await drops newer job").
    func awaitPendingTeardown() async {
        while true {
            let generation = teardownGeneration
            guard let task = teardownTask else { return }
            await task.value
            // No newer teardown was stored while we awaited → done.
            if teardownGeneration == generation { return }
        }
    }

    /// Removes every on-disk journal mirror plus the shared search index.
    /// Fresh interactive sign-in calls this (after `awaitPendingTeardown()`,
    /// before the first core opens): if the process died between
    /// `signOut()`'s synchronous `clearSession()` and its background wipe,
    /// the previous user's per-user SQLite mirror and the still-populated
    /// shared search index survive on disk — the next fresh sign-in would
    /// reopen them, and (worse) a different user could search the previous
    /// user's messages (bugbot "Sign-out leaves local mirror"). A fresh
    /// login resyncs from a server snapshot, so the clean slate costs
    /// nothing. Session *restore* at launch must NOT call this — a restored
    /// session keeps its mirror. Mirrors iOS.
    ///
    /// File removal runs on the main actor on purpose: the set is tiny (a
    /// few SQLite files) and this runs once, before the UI publishes the
    /// session — matching the class's existing on-main file work.
    func wipeLocalDataForFreshLogin() async {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
        try? await search?.wipe()
    }

    /// Test seam: the on-disk directory holding per-user journal SQLite
    /// mirrors. `wipeLocalDataForFreshLogin()` empties it; the test asserts
    /// a stray file placed here is gone afterwards.
    var journalStoreDirectory: URL { journalDirectory }

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
