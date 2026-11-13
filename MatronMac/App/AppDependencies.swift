import Foundation
import os
import SwiftUI
import UserNotifications
import MatronAuth
import MatronChat
import MatronDesignSystem
import MatronJournal
import MatronModels
import MatronPush
import MatronSearch
import MatronStorage
import MatronViewModels

/// Wires the Mac app onto the journal stack. Same shape as the iOS
/// `AppDependencies` — one `JournalCore` (API client + local SQLite mirror
/// + sync engine) per signed-in session; every per-session / per-room
/// service factory below is a thin wrapper over the same core so the sync
/// engine, the store, and the API client stay singletons for the session's
/// lifetime.
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

    private var cores: [String: JournalCore] = [:]
    /// Read-state reporter per session (`SeenTracker`), created on first use
    /// and dropped with the cores on sign-out.
    private var seenTrackers: [String: SeenTracker] = [:]

    /// What this session's timelines and item details report as seen.
    func seenTracker(for session: UserSession) -> SeenTracker {
        if let existing = seenTrackers[session.userID] { return existing }
        let engine = core(for: session).engine
        let tracker = SeenTracker(isActive: NSApp.isActive) { op in try await engine.sendOp(op) }
        seenTrackers[session.userID] = tracker
        return tracker
    }
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
    /// Not `private`: the shared factories (`Shared/App`) fill it.
    var timelineCache = LRUCache<TimelineCacheKey, JournalTimelineService>(limit: AppDependencies.timelineCacheLimit)

    init() {
        // Mac uses Application Support — single-process, no App Group.
        // `StoragePaths.appSupport` is non-optional on macOS (vs. the
        // App-Group `URL?` on iOS) and creates the directory on first
        // read, so there's no dev-environment fallback branch to write
        // here the way iOS needs one for its entitlement-less test/preview
        // runs.
        let container = StoragePaths.appSupport
        // Split the container into two sibling directories so a fresh-login
        // wipe of the journal store can never take out a persisted session.
        // - `journal-store` : the per-user SQLite mirror. Wiped on sign-out.
        // - `sessions`       : the session's legacy / fallback file. The
        //                      session itself lives in the Keychain (see
        //                      `SessionStores.live`); a file here is moved
        //                      into it on first read. Never wiped.
        sessionsDirectory = container.appendingPathComponent("sessions")
        journalDirectory = container.appendingPathComponent("journal-store")
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)

        auth = JournalAuthService(sessionStore: SessionStores.live(directory: sessionsDirectory))
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
    /// caller would have to null-check. Not `private`: the shared factories
    /// (`Shared/App`) call it.
    func core(for session: UserSession) -> JournalCore {
        if let existing = cores[session.userID] { return existing }
        // Built first so the API client and the engine report to it from
        // their very first request — a revoke discovered while a restored
        // session is still connecting at launch counts too.
        let revocation = CredentialRevocationMonitor { [weak self] in
            Task { @MainActor in self?.credentialsRevoked(for: session) }
        }
        let api = JournalAPI(serverURL: session.homeserverURL, token: session.accessToken,
                             authResponses: { [revocation] status in revocation.noteResponse(status: status) })
        let dbURL = journalDirectory.appendingPathComponent("\(session.userID).sqlite")
        LaunchTimeline.shared.beginStoreOpen()
        // `store.changeFeed` (on unless switched off in Settings → Storage;
        // `-store.changeFeed NO` on the command line for one run) serves the
        // conversation and item streams from change-fed indexes instead of
        // whole-table re-reads per commit.
        // `store.pool` (off by default; `-store.pool YES`) opens the mirror
        // as a `DatabasePool`, so reads stop waiting behind sync writes.
        let store = try! JournalStore(
            databaseURL: dbURL, ownSender: "user:\(session.userID)",
            usesChangeFeed: JournalStore.changeFeedEnabled(),
            usesPool: UserDefaults.standard.bool(forKey: JournalStore.poolFlagKey))
        LaunchTimeline.shared.endStoreOpen()
        // Un-gated, like MainThreadStallMonitor: a once-a-minute line per
        // store observation and hot write (category `store-observation`).
        StoreMetricsReporter.shared.start()
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
            ownSender: "user:\(session.userID)", search: search,
            credentialSignals: { [revocation] signal in revocation.handle(signal) }
        )
        // Task 9 (items tracker): the marker/reconnect streams come straight
        // off the sync engine (`nonisolated`, so safe to close over here).
        let items = ItemsSync(api: api, store: store, markers: { engine.itemMarkers() }, connectionStates: { engine.stateStream() },
                              sharedMissions: { engine.sharedMissionUpdates() })
        let missions = MissionsSync(api: api, store: store, markers: { engine.missionMarkers() },
                                    connectionStates: { engine.stateStream() })
        let projects = ProjectsSync(api: api, store: store, markers: { engine.missionMarkers() },
                                    connectionStates: { engine.stateStream() })
        let coordinator = CoordinatorSync(api: api, setting: CoordinatorSetting(userID: session.userID),
                                          updates: { engine.coordinatorUpdates() })
        let notify = NotifySettingsStore(api: api, updates: { engine.notifyUpdates() },
                                         connectionStates: { engine.stateStream() })
        let defaults = NewChatDefaultsStore(api: api, updates: { engine.defaultsUpdates() },
                                            connectionStates: { engine.stateStream() })
        let userSettings = UserSettingsStore(api: api, updates: { engine.userSettingsUpdates() },
                                             connectionStates: { engine.stateStream() })
        let briefing = LatestBriefingStore(api: api, updates: { engine.briefingUpdates() },
                                           connectionStates: { engine.stateStream() })
        let pins = PinsStore(api: api, updates: { engine.pinsUpdates() },
                             connectionStates: { engine.stateStream() },
                             boxNames: { store.agentNamesStream() })
        let maintenance = JournalMaintenance(store: store, search: search,
                                             openConversations: { await engine.viewedConversationIDs() })

        let core = JournalCore(api: api, store: store, engine: engine, items: items, missions: missions,
                                projects: projects, coordinator: coordinator, notify: notify,
                                defaults: defaults, userSettings: userSettings, briefing: briefing, pins: pins,
                                maintenance: maintenance, revocation: revocation)
        core.deviceID = Int64(session.deviceID)
        core.itemsStartTask = Task {
            // Spec 2026-09-28 dashboard §3.7: an item change on a mission
            // refetches that mission, so its needs-you count stays current.
            await items.setMissionRefetcher { missionID in await missions.refreshMission(id: missionID) }
            await items.start()
        }
        core.missionsStartTask = Task { await missions.start() }
        core.projectsStartTask = Task { await projects.start() }
        core.coordinatorStartTask = Task { await coordinator.start() }
        notify.start()
        defaults.start()
        userSettings.start()
        briefing.start()
        pins.start()
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

    func syncEngine(for session: UserSession) -> JournalSyncEngine { core(for: session).engine }

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

    func mediaService(for session: UserSession) -> any MediaService {
        if let existing = mediaServices[session.userID] { return existing }
        let service = JournalMediaService(api: core(for: session).api)
        mediaServices[session.userID] = service
        return service
    }

    /// The session's background sweeper — the app-foreground trigger calls
    /// `runIfDue()` on it.
    func journalMaintenance(for session: UserSession) -> JournalMaintenance {
        core(for: session).maintenance
    }

    /// The session's `MissionsSync` actor — marker refetches and the
    /// reconnect list refresh. One per session, same instance the view-model
    /// factories hand out.
    func missionsSync(for session: UserSession) -> MissionsSync {
        core(for: session).missions
    }

    /// The host for shareable links (`https://<journal>/u/<user>/<n>`),
    /// which open in-app: what one of the user's own numbers names comes
    /// from the go-to-number resolver above, and another person's link goes
    /// to `showOthers`. `nil` for a session whose server URL is not a web
    /// origin.
    func trackerNumberLinks(for session: UserSession,
                            showOthers: @escaping @MainActor @Sendable (TrackerLinkPath, URL) -> Void) -> TrackerNumberLinks? {
        guard let origin = TrackerLinkOrigin(serverURL: session.homeserverURL, user: session.userID) else { return nil }
        let resolver = goToNumberResolver(for: session)
        return TrackerNumberLinks(origin: origin, find: { await resolver.linkTarget(num: $0) }, showOthers: showOthers,
                                  titles: trackerLinkTitles(origin: origin, session: session))
    }

    /// Reads another person's shareable link for the read-only sheet.
    func sharedTrackerLinkLoader(for session: UserSession) -> SharedTrackerLinkLoader {
        SharedTrackerLinkLoader(api: core(for: session).api)
    }

    /// The Search page's query over everything (`GET /search/all`).
    func globalSearcher(for session: UserSession) -> any GlobalSearching {
        core(for: session).api
    }

    /// Per-chat / cross-chat items panel (spec: Apps → Panel content).
    /// `convoID: nil` is the app-wide instance — see `makeDecisionsViewModel`.
    @MainActor func makeItemsPanelViewModel(for session: UserSession, convoID: String?) -> ItemsPanelViewModel {
        let c = core(for: session)
        return ItemsPanelViewModel(convoID: convoID, store: c.store, api: c.api, sync: c.items, gate: .shared)
    }

    /// The rooms one conversation takes part in — its chat header's
    /// "Rooms · n". Reads the store's rooms stream; one per mounted chat.
    @MainActor func makeConversationRoomsViewModel(for session: UserSession, convoID: String) -> ConversationRoomsViewModel {
        let store = core(for: session).store
        return ConversationRoomsViewModel(convoID: convoID, rooms: { store.roomsStream() })
    }

    /// The Missions dashboard's view model — one per signed-in session,
    /// created and started by the shell (its badge shows on every entry),
    /// stopped when the shell leaves. The Ask button sends through the
    /// engine's offline outbox, like any composed message.
    ///
    /// `summaries: { chat.chatSummaries() }` opens its own summaries
    /// pipeline, independent of the chat list's — `chatSummaries()` is not
    /// a shared broadcaster and `ChatListViewModel` exposes no stream a
    /// second consumer could share. `MacChatListView` builds this VM once
    /// per session (`.task(id: session?.userID)`), never per appearance,
    /// so that is exactly one extra pipeline for the whole session (as on
    /// iOS).
    @MainActor func makeMissionsDashboardViewModel(for session: UserSession) -> MissionsDashboardViewModel {
        let c = core(for: session)
        let api = c.api, engine = c.engine
        let chat = chatService(for: session)
        return MissionsDashboardViewModel(
            store: c.store, sync: c.missions,
            summaries: { chat.chatSummaries() },
            roster: { try await api.roster() },
            send: { convoID, body in
                // `sendMessage` is synchronous throws on the engine actor
                // (queue-and-flush, not a network round trip) — `await` is
                // for the actor hop, not for asynchronous work.
                try await engine.sendMessage(convoID: convoID, body: body, localID: UUID().uuidString)
            },
            projectsStore: c.store, projects: c.projects, briefing: c.briefing, gate: .shared)
    }

    /// One mission page.
    /// The Mac mission page's Board also reads the mission's closed items
    /// from the local store (its Done column), and opening the page runs
    /// the tracker's list refresh to keep them current.
    @MainActor func makeMissionDetailViewModel(for session: UserSession, missionID: String) -> MissionDetailViewModel {
        let c = core(for: session)
        let items = c.items
        return MissionDetailViewModel(missionID: missionID, store: c.store, sync: c.missions, closedItems: c.store,
                                      // Incremental from the tracker's watermark: brings in
                                      // items re-pointed to this mission with no marker.
                                      refreshItems: { _ = await items.refresh(scope: .all) },
                                      projectsStore: c.store, projects: c.projects)
    }

    /// Item detail sheet/screen.
    @MainActor func makeItemDetailViewModel(for session: UserSession, itemID: String) -> ItemDetailViewModel {
        let c = core(for: session)
        // `events` + `agentSpawn`: the consent card inside
        // item detail reads the origin conversation's card and outcome from
        // the same store the timeline does, and answers on the same API.
        return ItemDetailViewModel(itemID: itemID, store: c.store, api: c.api, sync: c.items, events: c.store, agentSpawn: c.api,
                                   seen: seenTracker(for: session),
                                   // Queued replies: the origin conversation's
                                   // queue cards, answered on the same socket a card tap uses.
                                   queuedCards: c.store, queuedRelease: c.engine,
                                   // The header's mission and owner conversation;
                                   // a mission this device lacks is fetched once so the row can
                                   // name it.
                                   contextStore: c.store,
                                   refreshMission: { [missions = c.missions] id in await missions.refreshMission(id: id) })
    }

    func pushService(for session: UserSession) -> JournalPushService {
        JournalPushService(api: core(for: session).api, environment: pushEnvironment)
    }

    /// Devices/pairing surface (Settings → Devices). The session's one
    /// `JournalAPI` conforms directly; the protocol exists so the view
    /// models test against a fake.
    func devicesService(for session: UserSession) -> any DevicesProviding {
        core(for: session).api
    }

    /// Test seam: how many distinct rooms the timeline cache holds before
    /// LRU eviction begins. See iOS `AppDependencies.timelineCacheLimit`.
    static let timelineCacheLimit = 16

    /// Called on the main actor when the server has revoked the signed-in
    /// device's credentials (signed out from another device). The host runs
    /// its normal sign-out from here and shows the sign-in screen with a
    /// reason. The host sets it in `bootstrap()`; a revoke found before that
    /// (another scene restored the session first) is handled here and handed
    /// over as soon as it is set — see `credentialsRevoked(for:)`.
    var onCredentialsRevoked: ((UserSession) -> Void)? {
        didSet {
            guard let onCredentialsRevoked, let pending = pendingRevokedSession else { return }
            pendingRevokedSession = nil
            onCredentialsRevoked(pending)
        }
    }

    /// A revoke this object already signed out for because no host was
    /// listening yet; delivered to `onCredentialsRevoked` once it is set, so
    /// the sign-in screen still says why.
    private var pendingRevokedSession: UserSession?

    /// Forwards a revoke to `onCredentialsRevoked` — only while the session
    /// it was found for is still live. A late report from a core that has
    /// already been torn down (the user signed out, or signed in again and
    /// got a new core) is dropped, so one revoke can sign out at most once.
    /// With no host listening yet, signs out right here (the wipe must not
    /// wait for a window that may never open) and keeps the session for the
    /// host's notice.
    func credentialsRevoked(for session: UserSession) {
        // `hasFired` tells this session's current core apart from one a
        // sign-out already replaced: a fresh core's monitor has not fired.
        guard let core = cores[session.userID], core.revocation.hasFired else { return }
        if let onCredentialsRevoked {
            onCredentialsRevoked(session)
            return
        }
        signOut()
        pendingRevokedSession = session
    }

    /// Test seam: reports this session's handshake as refused, exactly as
    /// the sync engine does when the server rejects the device's token.
    func simulateConnectionAuthRejected(for session: UserSession) {
        core(for: session).revocation.handle(.rejected)
    }

    /// Test seam: reports a REST answer for this session, exactly as its
    /// API client does after a token-bearing request.
    func simulateRESTResponse(status: Int, for session: UserSession) {
        core(for: session).revocation.noteResponse(status: status)
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
        // Disarm first: the teardown below still talks to the server with
        // the old token (push deregistration), and a revoked token's 401s
        // must not ask for a second sign-out.
        for core in oldCores { core.revocation.cancel() }
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
                // Two separate hazards, both real:
                //  - a not-yet-run start would arm the hourly timer AFTER
                //    teardown, so await the kickoff first;
                //  - a pass already suspended in `search.removeAll(…)` would
                //    resume after the wipe below and re-stamp
                //    `maintenance_last_run` on an empty `meta`, so `stop()`
                //    awaits it (see `JournalMaintenance.stop`).
                await core.maintenanceStartTask?.value
                await core.maintenance.stop()
                // Best-effort, bounded: push deregistration, then this
                // device's own token revoked (see the iOS `signOut`).
                await Self.withTimeout(seconds: 5) { await core.api.signOutThisDevice(deviceID: core.deviceID) }
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
                await core.projectsStartTask?.value
                await core.projects.stop()
                await core.coordinatorStartTask?.value
                await core.coordinator.stop()
                core.notify.stop()
                core.defaults.stop()
                core.userSettings.stop()
                core.briefing.stop()
                core.pins.stop()
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
            // Again, now the server side is done: a notification can land
            // between the sign-out tap and the revocation.
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        cores.removeAll()
        seenTrackers.removeAll()
        mediaServices.removeAll()
        timelineCache = LRUCache(limit: AppDependencies.timelineCacheLimit)
        // The previous account's notifications stay in Notification Center
        // otherwise, previews and all.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        // The timeline's process-wide measurement memo holds rendered copies
        // of the previous account's messages.
        MacTimelineMeasureCache.shared.removeAll()
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
