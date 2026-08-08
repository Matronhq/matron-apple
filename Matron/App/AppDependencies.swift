import Foundation
import os
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
    /// Phase 6 (Search): the local FTS index. Optional — `nil` while the
    /// SQLite store can't be opened; the journal services all treat search as
    /// optional, so the app degrades to "search disabled" rather than failing
    /// to launch.
    ///
    /// Resolved on demand and RE-attempted after a failure, rather than opened
    /// once in `init`. The index file carries `NSFileProtectionComplete`
    /// (see `SearchSchema.makeDatabase`), so opening it throws whenever the
    /// device is locked — and this app gets launched in the background while
    /// locked, by push wake and background refresh. A one-shot `try?` in
    /// `init` therefore left this nil for the entire life of such a process,
    /// which silently removed the chat list's search button (it renders only
    /// when this is non-nil) until the app was force-quit. Retrying means the
    /// first render after unlock picks the index up.
    var search: SearchService? {
        if let openedSearch { return openedSearch }
        do {
            let service = try SearchServiceLive.open(databaseURL: searchDatabaseURL)
            openedSearch = service
            // Anything built while the index was shut has to be told about it
            // now — see `adoptSearch`. Retrying the open is only half a fix if
            // the session that came up locked keeps indexing into nothing.
            adoptSearch(service)
            return service
        } catch {
            // Never swallowed silently again: a missing search button is
            // otherwise indistinguishable from a build without the feature.
            Self.logger.error("search index unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Attaches a just-opened index to every session core that was built
    /// without one.
    ///
    /// `core(for:)` reads `search` once, at construction, and the core it
    /// builds is cached for the process's life. A background launch while the
    /// device is locked therefore produced a session whose sync engine never
    /// indexed anything and whose history backfill never started — and, worse,
    /// the retry above meant the search UI appeared as soon as the user
    /// unlocked, searching an index nothing was writing to. That reads as
    /// "search is broken", not "search is off", which is the harder bug to
    /// report.
    ///
    /// All three halves are repaired here: live indexing from now on via the
    /// engine's `attachSearch`; the backfill sweep that `startBackfill`
    /// declines to start without an index; and the events that landed in
    /// between, which are in the store but not the index —
    /// `resetBookkeepingFirst` is what recovers those (see `startBackfill`).
    private func adoptSearch(_ service: SearchService) {
        for core in cores.values {
            // Only the engine (an actor, hence Sendable) crosses into the
            // task; `core` itself stays on the main actor.
            let engine = core.engine
            Task { await engine.attachSearch(service) }
            if core.backfillTask == nil {
                core.backfillTask = Self.startBackfill(search: service, api: core.api, store: core.store,
                                                       resetBookkeepingFirst: true)
            }
        }
    }

    private static let logger = os.Logger(subsystem: "chat.matron", category: "app-dependencies")
    private var openedSearch: SearchService?
    private let searchDatabaseURL: URL

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
        /// Background search-history backfill sweep for this session (see
        /// `SearchBackfillCoordinator`). Cancelled on sign-out.
        var backfillTask: Task<Void, Never>?
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
        // alongside the journal store, so the NSE/host share it. Only the
        // path is resolved here — the open itself is deferred to `search`,
        // which retries (see there: a locked device can't open the index, and
        // init runs on background launches too).
        // Without the group entitlement (test runner / Previews) the index
        // sits beside the fallback journal container instead of being
        // silently disabled (bugbot "iOS search path mismatch").
        searchDatabaseURL = StoragePaths.searchDBPath ?? StoragePaths.searchDB(in: container)
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
        // One read, used for both: on a locked background launch this is nil
        // and stays nil for this core until `adoptSearch` fills it in.
        let search = self.search
        let engine = JournalSyncEngine(
            api: api, store: store,
            connector: URLSessionWebSocketConnector(),
            token: session.accessToken,
            ownSender: "user:\(session.userID)", search: search
        )
        let core = JournalCore(api: api, store: store, engine: engine)
        core.backfillTask = Self.startBackfill(search: search, api: api, store: store)
        cores[session.userID] = core
        return core
    }

    /// Kicks off the background search-history backfill for a session's
    /// core: a low-priority sweep that walks every conversation's server
    /// history into the FTS index, so search covers messages this device
    /// never saw live (fresh installs and snapshot re-bootstraps start with
    /// an empty message index — the 'dev-z' gap). Retries with backoff while
    /// any conversation fails (offline launch, server error). Stays resident
    /// for the whole session even after a clean sweep: a mid-session
    /// `snapshot_required` bootstrap resets the backfill bookkeeping
    /// (`coldStartIfNeeded`) and only a later pass here re-walks the gap —
    /// exiting after the first clean sweep would leave that hole until the
    /// next launch (bugbot "Backfill never restarts after sweep"). An
    /// all-complete idle pass is pure local reads, so the long cadence
    /// costs no network. Shared with MatronMac via copy — keep in sync.
    ///
    /// `resetBookkeepingFirst` is for the late-attach path (`adoptSearch`):
    /// events applied while the index was shut are in the store but not in
    /// FTS, and they sit at each conversation's HEAD — precisely where the
    /// coordinator does not look, since it returns immediately for a room
    /// already flagged backfill-complete and otherwise resumes walking
    /// *downward* from its recorded oldest point. Clearing the bookkeeping
    /// re-walks every room from its newest page, which is the same remedy
    /// `coldStartIfNeeded` applies for the same reason (head-side holes
    /// hidden by stale complete flags). Indexed messages are untouched and
    /// re-indexing is idempotent, so the cost is re-paging history once.
    static func startBackfill(search: SearchService?, api: JournalAPI, store: JournalStore,
                              resetBookkeepingFirst: Bool = false) -> Task<Void, Never>? {
        guard let search else { return nil }
        let coordinator = SearchBackfillCoordinator(search: search) { convoID, beforeSeq, limit in
            try await api.messages(convoID: convoID, beforeSeq: beforeSeq, limit: limit)
        }
        return Task(priority: .utility) {
            // Inside the task and ahead of the sleep, so it is ordered before
            // the coordinator's first backfillComplete() check. Best-effort:
            // a failed reset leaves coverage where it was, exactly as the
            // cold-start reset does.
            if resetBookkeepingFirst { try? await search.resetBackfill() }
            // Let the initial connect + catch-up replay land before adding
            // background request load.
            try? await Task.sleep(for: .seconds(10))
            var backoff = Duration.seconds(30)
            while !Task.isCancelled {
                // Backgrounded (a BG-refresh wake or the outbox grace
                // window): that runtime belongs to catch-up and send
                // delivery, not to history paging — don't spend its radio
                // time on a sweep the next foreground can run.
                if await MainActor.run(body: { UIApplication.shared.applicationState == .background }) {
                    try? await Task.sleep(for: .seconds(60))
                    continue
                }
                // An empty list means the first snapshot hasn't landed yet —
                // treat it like a failed pass and retry on the backoff curve.
                let ids = (try? store.allConversationIDs()) ?? []
                if !ids.isEmpty, await coordinator.run(convoIDs: ids) {
                    backoff = .seconds(30) // a later failure restarts the curve
                    try? await Task.sleep(for: .seconds(900))
                } else {
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(600))
                }
            }
        }
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
        //
        // Chain onto any previous teardown: `sign out A → re-login →
        // sign out B` overwrote `teardownTask` while A's endSync/wipe on
        // A's cores might still be running, and `awaitPendingTeardown()`
        // would then wait only for B — a new sign-in could race A's still-
        // running wipe on the same on-disk SQLite (bugbot "Sign-out drops
        // prior teardown job"). Awaiting `previous` first serialises every
        // teardown, so a wipe never overlaps an earlier one. The bumped
        // generation lets `awaitPendingTeardown()` notice a task chained
        // while it was suspended.
        let previous = teardownTask
        teardownGeneration &+= 1
        teardownTask = Task { [search] in
            await previous?.value
            for core in oldCores {
                // Stop the backfill sweep before the search wipe below so it
                // can't repopulate the index with the old user's messages.
                // Awaited (not just cancelled): an in-flight page of index
                // writes landing after the wipe would resurrect them.
                core.backfillTask?.cancel()
                await core.backfillTask?.value
                // Best-effort server-side push deregistration while the API
                // still holds a valid token (Finding 3). Bounded so a dead
                // network can't hold re-login hostage to a URLSession
                // timeout — the engine/store teardown below is what
                // correctness needs; this is just hygiene.
                await Self.withTimeout(seconds: 5) { try? await core.api.unregisterPush() }
                await core.engine.endSync()          // stop the writer first…
                try? core.store.wipe()               // …then clear the mirror
                // The mirror wipe deliberately preserves the outbox (a
                // snapshot_required wipe must not eat unsent messages);
                // sign-out is the one place queued sends must NOT survive —
                // the next account on this db file must not inherit or
                // deliver them.
                try? core.store.wipeOutbox()
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
    /// session keeps its mirror.
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

/// Carries the app-wide biometric lock so Settings can offer the
/// enable/timeout controls. `nil` in previews/tests, which simply hides
/// the Privacy section.
struct AppLockControllerKey: EnvironmentKey {
    static let defaultValue: AppLockController? = nil
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
    var appLockController: AppLockController? {
        get { self[AppLockControllerKey.self] }
        set { self[AppLockControllerKey.self] = newValue }
    }
}
