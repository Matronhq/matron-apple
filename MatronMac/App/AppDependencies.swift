import Foundation
import os
import SwiftUI
import MatronAuth
import MatronChat
import MatronDesignSystem
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
    ///
    /// macOS has no file-protection classes, so unlike iOS this open does not
    /// depend on device lock state — but the failure is logged rather than
    /// swallowed for the same reason: search UI is gated on this being
    /// non-nil, and a silently disabled index looks exactly like a build
    /// without the feature.
    let search: SearchService?

    private static let logger = os.Logger(subsystem: "chat.matron.mac", category: "app-dependencies")

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
        /// Task 9 (items tracker): keeps the local tracker cache fresh for
        /// this session. Started right after construction in `core(for:)`;
        /// stopped alongside the rest of the session's teardown on sign-out.
        let items: ItemsSync
        /// Handle for the `items.start()` kickoff `Task` fired at
        /// construction. Awaited (not cancelled — `start()` is a quick,
        /// one-shot subscription setup, not a long-running loop) before
        /// `items.stop()` in the sign-out teardown, so a not-yet-run start
        /// can never install its marker/reconnect subscriptions after the
        /// store wipe.
        var itemsStartTask: Task<Void, Never>?
        /// Keeps the local mission cache fresh for this session (spec
        /// 2026-09-10). Started right after construction, stopped with the
        /// rest of the session's teardown on sign-out.
        let missions: MissionsSync
        var missionsStartTask: Task<Void, Never>?
        /// Background search-history backfill sweep for this session (see
        /// `SearchBackfillCoordinator`). Cancelled on sign-out.
        var backfillTask: Task<Void, Never>?
        /// Background store housekeeping (TTL + retention sweeps and the
        /// matching search removal). Replaces the sweep `JournalStore.init`
        /// used to run on the launch path.
        let maintenance: JournalMaintenance
        /// Handle for the `maintenance.start()` kickoff — awaited before
        /// `stop()` in the sign-out teardown, same rule as `itemsStartTask`.
        var maintenanceStartTask: Task<Void, Never>?
        init(api: JournalAPI, store: JournalStore, engine: JournalSyncEngine, items: ItemsSync, missions: MissionsSync,
             maintenance: JournalMaintenance) {
            self.api = api
            self.store = store
            self.engine = engine
            self.items = items
            self.missions = missions
            self.maintenance = maintenance
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
        do {
            search = try SearchServiceLive.open(databaseURL: StoragePaths.searchDBPath)
        } catch {
            search = nil
            Self.logger.error("search index unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read from the signed provisioning profile (`embedded.provisionprofile`
    /// under `Contents/`), not from the build configuration — see iOS
    /// `AppDependencies.pushEnvironment` and `PushEnvironmentResolver`.
    private var pushEnvironment: JournalAPI.PushEnvironment {
        PushEnvironmentResolver.resolve()
    }

    /// Builds (or returns the cached) journal stack for `session`. A store
    /// that fails to open is unrecoverable dev-time config; crashing loudly
    /// here is preferable to limping along with a `nil` store that every
    /// caller would have to null-check.
    private func core(for session: UserSession) -> JournalCore {
        if let existing = cores[session.userID] { return existing }
        let api = JournalAPI(serverURL: session.homeserverURL, token: session.accessToken)
        let dbURL = journalDirectory.appendingPathComponent("\(session.userID).sqlite")
        LaunchTimeline.shared.beginStoreOpen()
        let store = try! JournalStore(databaseURL: dbURL, ownSender: "user:\(session.userID)")  // unchanged
        LaunchTimeline.shared.endStoreOpen()
        // Nested inside the store-open interval: present on the one launch
        // that ran v11, absent on every later one. That contrast is the
        // headline result of this whole plan, so it has to be visible.
        if let migration = store.lastMigrationDuration {
            LaunchTimeline.shared.recordMigration(migration)
        }
        let engine = JournalSyncEngine(
            api: api, store: store,
            connector: URLSessionWebSocketConnector(),
            token: session.accessToken,
            ownSender: "user:\(session.userID)", search: search
        )
        // Task 9 (items tracker): the marker/reconnect streams come straight
        // off the sync engine (`nonisolated`, so safe to close over here).
        let items = ItemsSync(api: api, store: store, markers: { engine.itemMarkers() }, connectionStates: { engine.stateStream() })
        let missions = MissionsSync(api: api, store: store, markers: { engine.missionMarkers() },
                                    connectionStates: { engine.stateStream() })
        let maintenance = JournalMaintenance(store: store, search: search)
        let core = JournalCore(api: api, store: store, engine: engine, items: items, missions: missions,
                                maintenance: maintenance)
        core.itemsStartTask = Task { await items.start() }
        core.missionsStartTask = Task { await missions.start() }
        core.backfillTask = Self.startBackfill(search: search, api: api, store: store, engine: engine)
        core.maintenanceStartTask = Task {
            await engine.attachMaintenance(maintenance)
            // The engine lives in MatronShared and must not call
            // LaunchTimeline itself (R7); this hook lets the app target
            // record the mark the first time the replay reaches the live
            // cursor. Also lets maintenance past its launch hold early
            // (Bugbot High): catch-up reaching the live cursor is the
            // signal the launch path is over, so a pass may run sooner
            // than `start()`'s `firstRunDelay` if catch-up itself took
            // longer.
            await engine.setCatchUpCompleteHandler {
                LaunchTimeline.shared.mark(.catchUpComplete)
                Task { await maintenance.runAfterCatchUp() }
            }
            await maintenance.start()
        }
        // One-time: box tag letters chosen before they were journal-held
        // move up to the server so they show on every device — and into
        // the local mirror first, so they keep painting while the push is
        // pending (or the journal predates the tag route). A Task keeps
        // itself alive; nil (no legacy overrides) is the steady state.
        _ = BoxLetterMigration.runIfNeeded(api: api, store: store, userID: session.userID)
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
    /// costs no network. Mirror of the iOS implementation — keep in sync.
    ///
    /// `resetBookkeepingFirst` exists for iOS's late-attach path, where the
    /// index can only be opened after the device unlocks and the events
    /// applied in the meantime sit unindexed at each conversation's head.
    /// macOS has no file-protection classes, so its index opens at init and
    /// no caller here passes `true` — the parameter is carried purely to keep
    /// the two copies textually identical.
    static func startBackfill(search: SearchService?, api: JournalAPI, store: JournalStore,
                              engine: JournalSyncEngine, resetBookkeepingFirst: Bool = false) -> Task<Void, Never>? {
        guard let search else { return nil }
        let coordinator = SearchBackfillCoordinator(search: search) { convoID, beforeSeq, limit in
            try await api.messages(convoID: convoID, beforeSeq: beforeSeq, limit: limit)
        }
        return Task(priority: .utility) {
            // Attach before anything else: from the moment a walk can exist,
            // the engine's cold-start bookkeeping reset must route through
            // this coordinator's epoch guard rather than race the walk by
            // hitting the SearchService directly (see
            // SearchBackfillCoordinator.reset).
            await engine.attachBackfillCoordinator(coordinator)
            if resetBookkeepingFirst { await coordinator.reset() }
            // Let the initial connect + catch-up replay land before adding
            // background request load.
            try? await Task.sleep(for: .seconds(10))
            var backoff = Duration.seconds(30)
            while !Task.isCancelled {
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

    /// The session's journal store, for read-only feature queries (media
    /// browser). Same instance the sync engine writes.
    func journalStore(for session: UserSession) -> JournalStore {
        core(for: session).store
    }

    /// The session's background sweeper — the app-foreground trigger calls
    /// `runIfDue()` on it.
    func journalMaintenance(for session: UserSession) -> JournalMaintenance {
        core(for: session).maintenance
    }

    /// Task 9 (items tracker): the session's `ItemsSync` actor — outbox
    /// drain, marker refetches, reconnect refresh. One per session, same
    /// instance the view-model factories below hand out.
    func itemsSync(for session: UserSession) -> ItemsSync {
        core(for: session).items
    }

    /// The session's `MissionsSync` actor — marker refetches and the
    /// reconnect list refresh. One per session, same instance the view-model
    /// factories hand out.
    func missionsSync(for session: UserSession) -> MissionsSync {
        core(for: session).missions
    }

    /// Item #115: resolves a tapped `[#65](matron://item/65)` link to a
    /// local item id, with one `refresh(scope: .all)` retry on a miss. One
    /// per call (a value type over the session's store + sync actor) —
    /// every link-hosting surface asks for its own.
    func itemLinkResolver(for session: UserSession) -> TrackerItemLinkResolver {
        let c = core(for: session)
        return TrackerItemLinkResolver(store: c.store, sync: c.items)
    }

    /// The same resolution, expressed in the design system's vocabulary so a
    /// link-hosting view can hand it straight to `trackerItemLinks`. Lives
    /// here because this is the one layer that sees BOTH
    /// `TrackerItemLinkResolver` (MatronViewModels) and
    /// `TrackerItemLinkOutcome` (MatronDesignSystem); doing the mapping in
    /// each host instead is how the miss path drifted between surfaces
    /// before fix round 2. `alertMessage` is `nil` only for `.open`, which
    /// this switch has already taken.
    func trackerItemLinkOutcome(num: Int, session: UserSession) async -> TrackerItemLinkOutcome {
        switch await itemLinkResolver(for: session).resolve(num: num) {
        case .open(let itemID):
            return .open(itemID: itemID)
        case let miss:
            return .explain(miss.alertMessage(num: num) ?? "Item #\(num) couldn't be opened.")
        }
    }

    /// Read surface for tracker create/comment/close flows that don't need
    /// the full `ItemsPanelViewModel`/`ItemDetailViewModel` (e.g. a
    /// standalone create sheet). Same session-scoped `JournalAPI`.
    func itemsProvider(for session: UserSession) -> any ItemsProviding {
        core(for: session).api
    }

    /// Per-chat / cross-chat items panel (spec: Apps → Panel content).
    /// `convoID: nil` is the app-wide instance — see `makeDecisionsViewModel`.
    @MainActor func makeItemsPanelViewModel(for session: UserSession, convoID: String?) -> ItemsPanelViewModel {
        let c = core(for: session)
        return ItemsPanelViewModel(convoID: convoID, store: c.store, api: c.api, sync: c.items)
    }

    /// The one Decisions instance per signed-in session (app shell, spec
    /// §1): no home conversation, starts in `.all`, feeds the Decisions
    /// list and the badge. Created and started by the shell, stopped when
    /// the shell leaves the hierarchy on sign-out.
    @MainActor func makeDecisionsViewModel(for session: UserSession) -> ItemsPanelViewModel {
        makeItemsPanelViewModel(for: session, convoID: nil)
    }

    /// The Missions tab's list view model — one per signed-in session,
    /// created and started by the shell, stopped when the shell leaves.
    @MainActor func makeMissionsListViewModel(for session: UserSession) -> MissionsListViewModel {
        let c = core(for: session)
        return MissionsListViewModel(store: c.store, sync: c.missions)
    }

    /// One mission page.
    @MainActor func makeMissionDetailViewModel(for session: UserSession, missionID: String) -> MissionDetailViewModel {
        let c = core(for: session)
        return MissionDetailViewModel(missionID: missionID, store: c.store, sync: c.missions)
    }

    /// Item detail sheet/screen.
    @MainActor func makeItemDetailViewModel(for session: UserSession, itemID: String) -> ItemDetailViewModel {
        let c = core(for: session)
        return ItemDetailViewModel(itemID: itemID, store: c.store, api: c.api, sync: c.items)
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

    /// Agent-chat consent surface: answering the cards inline in a chat, and
    /// the Settings screen listing the parked ones.
    /// Same session-scoped `JournalAPI`; protocol slice for testability.
    func agentChatService(for session: UserSession) -> any AgentChatProviding {
        core(for: session).api
    }

    /// Agent-spawn consent surface: answering the cards inline in a chat.
    /// No settings-screen twin — a spawn's resolution is journalled, so
    /// there is no parked-row list to poll.
    func agentSpawnService(for session: UserSession) -> any AgentSpawnAnswering {
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

    /// New Chat surface: last-known per-box capacity, so a box the host has
    /// suspended can still show the quota it had. Namespaced by user id like
    /// the journal store file — agent device ids are only unique within a
    /// journal, so an app-global cache would show one account another's
    /// numbers. `signOut()` removes the account's key alongside the wipes.
    func boxCapacityCache(for session: UserSession) -> any BoxCapacityCaching {
        UserDefaultsBoxCapacityCache(userID: session.userID)
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
        // Keyed by user id, captured before `cores.removeAll()` below.
        let oldUserIDs = Array(cores.keys)
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
                // Stop the backfill sweep before the search wipe below so it
                // can't repopulate the index with the old user's messages.
                // Awaited (not just cancelled): an in-flight page of index
                // writes landing after the wipe would resurrect them.
                core.backfillTask?.cancel()
                await core.backfillTask?.value
                // Two separate hazards, both real:
                //  - a not-yet-run start would arm the hourly timer AFTER
                //    teardown, so await the kickoff first;
                //  - a pass already suspended in `search.removeAll(…)` would
                //    resume after the wipe below and re-stamp
                //    `maintenance_last_run` on an empty `meta`, so `stop()`
                //    awaits it (see `JournalMaintenance.stop`).
                await core.maintenanceStartTask?.value
                await core.maintenance.stop()
                await Self.withTimeout(seconds: 5) { try? await core.api.unregisterPush() }
                // Task 9 (items tracker): await the start kickoff BEFORE
                // stop() — a not-yet-run start could otherwise install its
                // marker/reconnect subscriptions after `stop()` already
                // returned, leaving them live into the wipe below. Then stop
                // the actor's tasks so nothing it triggers can write into
                // the store after it's been cleared.
                await core.itemsStartTask?.value
                await core.items.stop()
                // Same discipline as `items`: await the start kickoff
                // before stop() so a not-yet-run start cannot install its
                // marker/reconnect subscriptions after the store is wiped.
                await core.missionsStartTask?.value
                await core.missions.stop()
                await core.engine.endSync()          // stop the writer first…
                try? core.store.wipe()               // …then clear the mirror
                // The mirror wipe deliberately preserves the outbox (a
                // snapshot_required wipe must not eat unsent messages);
                // sign-out is the one place queued sends must NOT survive —
                // the next account on this db file must not inherit or
                // deliver them.
                try? core.store.wipeOutbox()
                // Belt-and-braces (`wipe()` already clears `item`/
                // `item_comment` and `wipeOutbox()` already clears
                // `item_outbox`): explicit so a future change to either of
                // those doesn't silently leave tracker rows behind.
                try? core.store.wipeItems()
            }
            // Inside the awaited teardown so a new session's indexing can't
            // interleave with the wipe (bugbot "Search wipe races indexing").
            try? await search?.wipe()
            // Same data-separation contract: agent device ids repeat across
            // journals, so the next account on this device must not inherit
            // the last one's box capacities (account email included).
            for userID in oldUserIDs {
                UserDefaultsBoxCapacityCache.removeAll(for: userID)
            }
        }
        cores.removeAll()
        mediaServices.removeAll()
        timelineCache = LRUCache(limit: AppDependencies.timelineCacheLimit)
        try? auth.clearSession()
    }

    /// Test-only: stops every still-live session's background maintenance
    /// sweeper — the `maintenanceStartTask` kickoff, then `stop()` — without
    /// ending sync or wiping the store/search index, unlike `signOut()`.
    /// MatronMacTests construct `AppDependencies()` directly and reach
    /// `core(for:)` (via `mediaService(for:)`, `timelineService(for:)`,
    /// etc.), which starts a real `JournalMaintenance` with its live 10 s
    /// `firstRunDelay` timer; without this, that timer outlives the test
    /// method and can fire against the shared `MATRON_APP_SUPPORT_OVERRIDE`
    /// directory after a later test deletes or recreates the store there
    /// (task-6-review.md Major #1: `SQLite error 10: disk I/O error`).
    /// `internal`, `@testable`-visible only — no production call site.
    internal func stopMaintenanceForTests() async {
        for core in cores.values {
            await core.maintenanceStartTask?.value
            await core.maintenance.stop()
        }
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

    /// Mirror of the iOS accessor. `searchDBPath` is non-optional on macOS.
    var searchStoreURL: URL? { StoragePaths.searchDBPath }

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

/// Carries the app-wide biometric lock so Settings can offer the
/// enable/timeout controls. `nil` in previews/tests hides the section.
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
    var appLockController: AppLockController? {
        get { self[AppLockControllerKey.self] }
        set { self[AppLockControllerKey.self] = newValue }
    }
}
