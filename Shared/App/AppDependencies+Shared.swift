import Foundation
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

/// The parts of `AppDependencies` that are the same in the iOS and Mac
/// apps: the per-session `JournalCore` and the service and view-model
/// factories built on it. Each app keeps its own `AppDependencies` class
/// (stored state, `init`, `core(for:)`, sign-out, and everything that
/// differs by platform); this file is compiled into both.
@MainActor
extension AppDependencies {
    /// One journal stack per signed-in session: the API client, the local
    /// SQLite mirror, and the sync engine that's the sole writer of that
    /// mirror. Grouping these means `core(for:)` is a single dictionary
    /// lookup instead of three parallel per-session caches.
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
        /// Keeps the project cache and on-screen conversations' mission
        /// links fresh (spec 2026-09-30 §6). Started with the session,
        /// stopped with the rest of the teardown on sign-out.
        let projects: ProjectsSync
        var projectsStartTask: Task<Void, Never>?
        /// Keeps the cached Coordinator in step with the journal (Coordinator
        /// redesign §3a). Started right after construction, stopped on sign-out.
        let coordinator: CoordinatorSync
        var coordinatorStartTask: Task<Void, Never>?
        /// What may push (journal spec 2026-10-01 notification settings):
        /// the Notifications screen and every conversation's bell-slash read
        /// it. Started right after construction, stopped on sign-out.
        let notify: NotifySettingsStore
        /// The user's default model and effort for new chats (journal
        /// `/defaults`): Settings → New chats. Started right after
        /// construction, stopped on sign-out.
        let defaults: NewChatDefaultsStore
        /// The user's journal settings (`/settings`): the For you notices
        /// switch in Settings. Started right after construction, stopped on
        /// sign-out.
        let userSettings: UserSettingsStore
        /// The Coordinator's latest briefing (journal "Coordinator
        /// briefings"): the card at the top of Projects. Started right after
        /// construction, stopped on sign-out.
        let briefing: LatestBriefingStore
        /// The user's pinned desk chats (journal "Pinned desk chats"): the
        /// entries under the Coordinator and Settings → Pinned chats.
        /// Started right after construction, stopped on sign-out.
        let pins: PinsStore
        /// Background store housekeeping (TTL + retention sweeps and the
        /// matching search removal). Replaces the sweep `JournalStore.init`
        /// used to run on the launch path.
        let maintenance: JournalMaintenance
        /// Watches this session's handshakes and REST answers for the
        /// device's credentials being revoked elsewhere. Disarmed first
        /// thing in sign-out, so the teardown's own calls with the dead
        /// token cannot trigger it again.
        let revocation: CredentialRevocationMonitor
        /// This device's id on the journal, revoked on sign-out.
        var deviceID: Int64?
        /// Handle for the `maintenance.start()` kickoff — awaited before
        /// `stop()` in the sign-out teardown, same rule as `itemsStartTask`.
        var maintenanceStartTask: Task<Void, Never>?
        init(api: JournalAPI, store: JournalStore, engine: JournalSyncEngine, items: ItemsSync, missions: MissionsSync,
             projects: ProjectsSync, coordinator: CoordinatorSync, notify: NotifySettingsStore,
             defaults: NewChatDefaultsStore, userSettings: UserSettingsStore, briefing: LatestBriefingStore, pins: PinsStore,
             maintenance: JournalMaintenance, revocation: CredentialRevocationMonitor) {
            self.api = api
            self.store = store
            self.engine = engine
            self.items = items
            self.missions = missions
            self.projects = projects
            self.coordinator = coordinator
            self.notify = notify
            self.defaults = defaults
            self.userSettings = userSettings
            self.briefing = briefing
            self.pins = pins
            self.maintenance = maintenance
            self.revocation = revocation
        }
    }

    /// The search the UI uses: the journal server first, the local index
    /// (`search`) only when the server can't be reached — and the server
    /// alone when the index could not be opened, so search never depends
    /// on it. See `ServerFirstSearchService`.
    func searchService(for session: UserSession) -> SearchService {
        ServerFirstSearchService(remote: core(for: session).api, local: search)
    }

    /// The session's journal store, for read-only feature queries (media
    /// browser). Same instance the sync engine writes.
    func journalStore(for session: UserSession) -> JournalStore {
        core(for: session).store
    }

    func projectsSync(for session: UserSession) -> ProjectsSync {
        core(for: session).projects
    }

    /// The session's `CoordinatorSync` — every Coordinator pick or clear
    /// goes through it (Coordinator redesign §3a).
    func coordinatorSync(for session: UserSession) -> CoordinatorSync {
        core(for: session).coordinator
    }

    /// The session's notification settings — the Notifications screen, the
    /// per-conversation menus and the bell-slash on rows and headers.
    func notifySettings(for session: UserSession) -> NotifySettingsStore {
        core(for: session).notify
    }

    /// The session's pinned desk chats — the entries under the Coordinator,
    /// the pin actions on conversations and Settings → Pinned chats.
    func pinsStore(for session: UserSession) -> PinsStore {
        core(for: session).pins
    }

    /// The user's default model and effort for new chats — Settings → New
    /// chats.
    func newChatDefaults(for session: UserSession) -> NewChatDefaultsStore {
        core(for: session).defaults
    }

    /// The session's journal settings — the For you notices switch.
    func userSettings(for session: UserSession) -> UserSettingsStore {
        core(for: session).userSettings
    }

    /// The user's own Coordinator pick or clear, from any surface: the
    /// journal first, the cache follows. `nil` on success, otherwise the
    /// message to show.
    @MainActor func setCoordinator(_ convoID: String?, for session: UserSession) async -> String? {
        do {
            try await coordinatorSync(for: session).set(convoID)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Resolves a tapped `[#65](matron://item/65)` link to a
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

    /// A tapped `matron://mission/<n>` / `matron://project/<n>` link,
    /// resolved to its page through `PageLinkResolver` and expressed in the
    /// design system's vocabulary for `pageLinks(_:resolve:open:)` — the
    /// same split as `trackerItemLinkOutcome` above.
    func pageLinkOutcome(_ link: MatronPageLink, session: UserSession) async -> MatronPageLinkOutcome {
        let c = core(for: session)
        let resolver = PageLinkResolver(store: c.store, missions: c.missions, projects: c.projects)
        switch await resolver.resolve(link) {
        case .open(let target):
            return .open(target)
        case let miss:
            return .explain(miss.alertMessage(for: link) ?? "\(link.noun.capitalized) #\(link.num) couldn't be opened.")
        }
    }

    /// "Go to #N": resolves a typed number to the item, mission, milestone
    /// or project it names — the local store first, then the journal's
    /// lookup for this user — through the two link resolvers above, so a
    /// row this device lacks is synced before it opens.
    func goToNumberResolver(for session: UserSession) -> GoToNumberResolver {
        let c = core(for: session)
        let api = c.api
        let user = session.userID
        return GoToNumberResolver(
            store: c.store,
            lookup: { try await api.lookup(user: user, num: $0) },
            items: TrackerItemLinkResolver(store: c.store, sync: c.items),
            pages: PageLinkResolver(store: c.store, missions: c.missions, projects: c.projects))
    }

    /// What the session's tracker links point at, for the chip beside each
    /// one: the journal's `GET /lookup`, kept five minutes per session.
    func trackerLinkTitles(origin: TrackerLinkOrigin, session: UserSession) -> TrackerLinkTitles {
        let api = core(for: session).api
        return TrackerLinkTitles(origin: origin, find: { user, num in
            let hit = try await api.lookup(user: user, num: num)
            return (hit.kind.rawValue, hit.title)
        }, isNotFound: { ($0 as? JournalAPIError) == .notFound })
    }

    /// The one Decisions instance per signed-in session (app shell, spec
    /// §1): no home conversation, starts in `.all`, feeds the Decisions
    /// list and the badge. Created and started by the shell, stopped when
    /// the shell leaves the hierarchy on sign-out.
    @MainActor func makeDecisionsViewModel(for session: UserSession) -> ItemsPanelViewModel {
        makeItemsPanelViewModel(for: session, convoID: nil)
    }

    /// The Memories screen's "On your boxes" section: each box's own Claude
    /// Code memories, read over the agent RPC New Chat uses. Asks nothing
    /// until the screen calls `start()`.
    @MainActor func makeLocalMemoriesViewModel(for session: UserSession) -> LocalMemoriesViewModel {
        LocalMemoriesViewModel(api: agentRPCService(for: session))
    }

    /// The Memories screen's view model (spec 2026-09-27 memories). Loads
    /// nothing until the screen calls `start()`; follows the engine's
    /// `memory` markers while started.
    @MainActor func makeMemoriesViewModel(for session: UserSession) -> MemoriesViewModel {
        let c = core(for: session)
        let engine = c.engine
        return MemoriesViewModel(api: c.api, markers: { engine.memoryMarkers() })
    }

    /// Settings ▸ Coordinator ▸ Routines. Loads nothing until the screen
    /// calls `start()`; follows the engine's `routine` markers while
    /// started.
    @MainActor func makeRoutinesViewModel(for session: UserSession) -> RoutinesViewModel {
        let c = core(for: session)
        let engine = c.engine
        return RoutinesViewModel(api: c.api, markers: { engine.routineMarkers() })
    }

    /// The Projects timeline (behind `TimelineViewModel.flagKey`). Reads
    /// nothing until the host calls `start()`. "Ask the Coordinator" sends
    /// to the Coordinator conversation `coordinatorConvoID` names when
    /// asked, the way the dashboard's Ask does.
    @MainActor func makeTimelineViewModel(for session: UserSession,
                                          coordinatorConvoID: @escaping @MainActor () -> String?) -> TimelineViewModel {
        TimelineViewModel(timeline: core(for: session).api,
                          askCoordinator: coordinatorAsk(for: session, coordinatorConvoID: coordinatorConvoID))
    }

    /// Sends a message to the Coordinator conversation `coordinatorConvoID`
    /// names when asked: the timeline's and a project page's "Ask the
    /// Coordinator". Throws when there is no Coordinator to ask.
    @MainActor func coordinatorAsk(for session: UserSession,
                                   coordinatorConvoID: @escaping @MainActor () -> String?) -> (String) async throws -> Void {
        let engine = core(for: session).engine
        return { body in
            guard let convoID = coordinatorConvoID(), !convoID.isEmpty else { throw BriefingsError.noCoordinator }
            try await engine.sendMessage(convoID: convoID, body: body, localID: UUID().uuidString)
        }
    }

    /// One project's page on the timeline: where it stands, and its history.
    @MainActor func makeProjectSummaryViewModel(for session: UserSession, projectID: String) -> ProjectSummaryViewModel {
        ProjectSummaryViewModel(projectID: projectID, timeline: core(for: session).api)
    }

    /// One project page (spec 2026-09-30 §2).
    @MainActor func makeProjectDetailViewModel(for session: UserSession, projectID: String) -> ProjectDetailViewModel {
        let c = core(for: session)
        return ProjectDetailViewModel(projectID: projectID, store: c.store, projects: c.projects, missions: c.missions)
    }

    /// Live `box_defaults` frames for the Devices screen's New sessions
    /// editor, straight off the session's sync engine (`nonisolated`, so
    /// safe to close over).
    func boxDefaultsUpdates(for session: UserSession) -> @Sendable () -> AsyncStream<BoxDefaultsUpdate> {
        let engine = core(for: session).engine
        return { engine.boxDefaultsUpdates() }
    }

    /// Settings → Security: two-factor sign-in (the `/2fa` routes).
    func twoFactorSettingsService(for session: UserSession) -> any TwoFactorSettingsProviding {
        core(for: session).api
    }

    /// Settings → Security → Change password (`POST /password`).
    func passwordService(for session: UserSession) -> any PasswordChanging {
        core(for: session).api
    }

    /// Settings → Security → Email address (`GET`/`PUT /account/email`).
    func accountEmailService(for session: UserSession) -> any AccountEmailProviding {
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

    /// Answers hand-over cards from the timeline (`POST /grants/:id/answer`).
    func grantAnsweringService(for session: UserSession) -> any GrantAnswering {
        core(for: session).api
    }

    /// The Coordinator's consent-approval switch (Settings → Coordinator).
    func coordinatorConsentService(for session: UserSession) -> any CoordinatorConsentProviding {
        core(for: session).api
    }

    /// Stops a session the Coordinator let start, from its spawn card.
    func sessionStopper(for session: UserSession) -> any SessionStopping {
        core(for: session).engine
    }

    /// Show-QR surface (Settings → Link a Device). Same session-scoped
    /// `JournalAPI` as the devices surface; protocol slice for testability.
    func deviceLinkService(for session: UserSession) -> any DeviceLinking {
        core(for: session).api
    }

    /// Settings ▸ People and the invite-link sheets: contacts, and contacts
    /// on other journals by invite link.
    func contactsService(for session: UserSession) -> any ContactsProviding {
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
    /// The Boxes page's view model. Reads what the journal holds; asks no
    /// box anything until a Wake is tapped.
    @MainActor func makeBoxesViewModel(for session: UserSession) -> BoxesViewModel {
        #if DEBUG
        if BoxesDemoData.isRequested {
            return BoxesViewModel(api: BoxesDemoData(), capacityCache: boxCapacityCache(for: session))
        }
        #endif
        let core = core(for: session)
        return BoxesViewModel(api: JournalAgentRPCService(api: core.api, engine: core.engine),
                              capacityCache: boxCapacityCache(for: session))
    }

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

    /// Test seam: number of entries currently held by the timeline cache.
    var timelineCacheCount: Int { timelineCache.count }

    /// Test seam: whether the timeline cache currently holds an entry for
    /// `(userID, roomID)`.
    func timelineCacheContains(userID: String, roomID: String) -> Bool {
        timelineCache.contains(TimelineCacheKey(userID: userID, roomID: roomID))
    }
}
