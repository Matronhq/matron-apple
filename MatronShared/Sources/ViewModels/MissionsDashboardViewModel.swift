import Foundation
import Observation
import MatronChat
import MatronModels
import MatronJournal

/// The store reads the dashboard needs, as a protocol so tests fake the
/// store (`JournalStore` conforms here, as with `MissionsStoreReading`).
public protocol MissionsDashboardStoreReading: Sendable {
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]>
    func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]>
    func latestMilestonesStream() -> AsyncStream<[String: Milestone]>
    func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]>
    func latestSummaryTOCsStream() -> AsyncStream<[String: String]>
    /// `ChatSummary` carries no session state of its own (dropped for
    /// chat-list performance) — this is the live source for a cached
    /// session's dot (`JournalStore.sessionStatesStream()`).
    func sessionStatesStream() -> AsyncStream<[String: String]>
}

extension JournalStore: MissionsDashboardStoreReading {}

/// Backs the Missions dashboard (spec 2026-09-28 §3.7). One per signed-in
/// session, like the list it replaces: `start()`/`stop()` follow the
/// session (the badge and `isSupported` are read while another tab shows),
/// `pageDidAppear()`/`pageDidDisappear()` follow the page and own the
/// chat-summaries subscription, the roster poll and the per-mission detail
/// refresh.
@MainActor @Observable
public final class MissionsDashboardViewModel {
    /// Spec §3.4, verbatim.
    public static let coordinatorRefreshMessage =
        "Refresh the status of every open mission from its latest milestones, sessions and open items."
    public static let maxDetailRefreshesInFlight = 4
    /// Spec: skip the page-appear detail fan-out when one completed within
    /// this long (an explicit `refresh()` always runs regardless).
    public static let detailFanOutThrottle: TimeInterval = 60

    public private(set) var cards: [DashboardMissionCard] = []
    public private(set) var looseSessions: [DashboardSession] = []
    public private(set) var closed: [Mission] = []
    /// The sessions of the mission a mission page shows (uncapped, see
    /// `MissionsDashboardSnapshot.sessionsByMission`) — the Mac page's
    /// Sessions card. Only this slice is observable, and it is assigned only
    /// when it changes: a roster poll or summaries emission that touches
    /// some other mission must not re-render the page.
    public private(set) var pageMissionSessions: [DashboardSession] = []
    /// Every mission's sessions, uncapped. Observable: the project page's
    /// session chips read it (spec 2026-09-30 §2). The mission page slice is
    /// cut from this.
    public private(set) var sessionsByMission: [String: [DashboardSession]] = [:]
    /// The Projects home (spec 2026-09-30 §2, §6).
    public private(set) var home = ProjectsHomeSnapshot()
    /// `false` once `GET /projects` 404s: the host shows today's dashboard.
    public private(set) var projectsSupported: Bool?
    public var canCreateProject: Bool { projects != nil && projectsSupported != false }
    /// The journal's `TITLE_MAX`, in UTF-16 units (preflight R6).
    public static let maxProjectTitleUTF16 = 200
    @ObservationIgnored private let projectsStore: (any ProjectsStoreReading)?
    @ObservationIgnored private let projects: (any ProjectsSyncing)?
    @ObservationIgnored private var projectPageVisible = false
    @ObservationIgnored private var looseSectionVisible = false
    /// The mission the page shows, set by `missionPageDidAppear(missionID:)`.
    @ObservationIgnored private(set) var pageMissionID: String?
    /// Tri-state exactly as the old list VM's `isSupported`: `nil`
    /// until known, and every consumer treats `nil` as supported.
    public private(set) var isSupported: Bool?
    public private(set) var isRefreshing = false
    public var error: String?
    /// When the Ask was sent (this session); cleared once a mission status
    /// newer than it lands.
    public private(set) var askedAt: Date?
    /// Mirrored from the host's cached Coordinator setting.
    public var coordinatorConvoID: String? {
        didSet {
            guard coordinatorConvoID != oldValue else { return }
            inputs.coordinatorConvoID = coordinatorConvoID
            // Synchronous, deliberately not `scheduleRebuild()`: a host
            // setting this reads `looseSessions`/`cards` right back
            // (`testTheCoordinatorIsNeverALooseSession`), unlike a stream
            // emission which a consumer only ever observes asynchronously.
            performRebuild()
        }
    }

    public var canAskCoordinator: Bool { Self.trimmed(coordinatorConvoID) != nil }
    /// Review minor 1: after an Ask, a repeat is skipped for this long, so
    /// a double click sends the refresh message once.
    public static let askCooldown: TimeInterval = 10
    /// Whether the Ask button is live: a Coordinator is set, no Ask is in
    /// flight, and the last one is out of its cooldown. Hosts disable the
    /// button on `false`.
    public var canSendAsk: Bool { canAskCoordinator && !isAsking && !askCoolingDown }
    private var isAsking = false
    /// Observable twin of the cooldown clock in `askCoordinator()`, cleared
    /// by `askCooldownTask` so the button re-enables on its own.
    private var askCoolingDown = false
    /// The tab / nav badge.
    public var needsYouTotal: Int { cards.reduce(0) { $0 + $1.needsYouCount } }

    /// How many times `MissionsDashboardAssembly.assemble` actually ran —
    /// `internal` so tests (`@testable import`) can confirm a burst of
    /// stream emissions coalesces to one assemble, without any other
    /// consumer depending on it.
    private(set) var rebuildRunCount = 0

    @ObservationIgnored private var inputs = MissionsDashboardInputs()
    @ObservationIgnored private let store: any MissionsDashboardStoreReading
    @ObservationIgnored private let sync: any MissionsSyncing
    @ObservationIgnored private let summariesSource: @Sendable () -> AsyncThrowingStream<[ChatSummary], Error>
    @ObservationIgnored private let rosterSource: @Sendable () async throws -> [String: String]
    @ObservationIgnored private let send: @Sendable (String, String) async throws -> Void
    @ObservationIgnored private let rosterInterval: Duration
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var listRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var rosterTask: Task<Void, Never>?
    /// The chat-summaries subscription — page-scoped, not session-scoped
    /// (review I2): a second summary pipeline all session, one per Mac
    /// window, for a page that may never open, cost more than a refresh
    /// on the next appear. Only loose sessions and session titles read
    /// the summaries; the cards and the needs-you badge come from the
    /// missions and items streams, which stay live all session.
    @ObservationIgnored private var summariesTask: Task<Void, Never>?
    /// Between `start()` and `stop()`: a page appearing before the session
    /// starts opens nothing — `start()` opens it then.
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    /// Fan-outs that were cancelled but may not have finished yet. A
    /// cancelled fan-out only stops handing out new ids — the (up to four)
    /// `MissionsSync.refreshMission` calls it already made run on in an
    /// unstructured `Task` regardless — so every one stays here, awaitable
    /// by the next fan-out (or `refresh()`), until it has finished; then it
    /// is removed. See `retireDetailTask()` / `drainRetiredDetailTasks(_:)`.
    @ObservationIgnored private var drainingDetailTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingRebuildTask: Task<Void, Never>?
    @ObservationIgnored private var lastAskSentAt: Date?
    @ObservationIgnored private var askCooldownTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedMissions = false
    @ObservationIgnored private var pageVisible = false
    /// A mission page (Mac) reads `sessionsByMission`, whose titles and
    /// summaries come from the chat summaries and the roster — so those two
    /// feeds run while either the dashboard or a mission page shows. The
    /// detail fan-out stays the dashboard's alone: a mission page refreshes
    /// its own mission.
    @ObservationIgnored private var missionPageVisible = false
    @ObservationIgnored private var detailFanOutPending = false
    /// When a detail pass that covered every open mission (at least one)
    /// last ran to completion — a full pass, or a catch-up that found every
    /// open mission missing — and not one cancelled partway, run over
    /// nothing, or left over from a previous session: the page-appear
    /// throttle's clock. `internal` read access so tests can wait on the
    /// completion itself rather than sleeping and hoping it landed.
    @ObservationIgnored private(set) var lastDetailFanOutCompletedAt: Date?
    /// Missions whose detail has been fetched this session. The throttle
    /// only ever skips a repeat pass over these; an open mission missing
    /// from it is fetched whenever the page shows (PR 265: GRDB's first
    /// snapshot after sign-in or a wipe is empty, so the first pass covers
    /// nothing and the real missions arrive in a later emission).
    @ObservationIgnored private var detailRefreshedIDs: Set<String> = []
    /// Bumped by `stop()`. Every pass captures it when created; a pass from
    /// an older session may still be finishing requests (production
    /// `refreshMission` ignores cancellation), and its marks and completion
    /// stamp are dropped rather than landing in the new session's state.
    @ObservationIgnored private var detailSession = 0
    /// The catch-up link queued behind the current fan-out, if any — at
    /// most one waits at a time. A token, not a flag, so a retired link
    /// that finishes late clears only its own slot, never a newer link's.
    @ObservationIgnored private var queuedCatchUp: UUID?
    /// Whether a catch-up link is queued — `internal` for tests.
    var hasQueuedCatchUp: Bool { queuedCatchUp != nil }
    /// How many times a detail fan-out (or `refresh()`) has parked waiting
    /// for earlier, retired fan-outs to drain — `internal` so tests can wait for
    /// that parked state deterministically before releasing requests.
    @ObservationIgnored private(set) var detailDrainWaitCount = 0

    public init(store: any MissionsDashboardStoreReading, sync: any MissionsSyncing,
                summaries: @escaping @Sendable () -> AsyncThrowingStream<[ChatSummary], Error>,
                roster: @escaping @Sendable () async throws -> [String: String],
                send: @escaping @Sendable (_ convoID: String, _ body: String) async throws -> Void,
                rosterInterval: Duration = .seconds(60),
                now: @escaping @Sendable () -> Date = { Date() },
                projectsStore: (any ProjectsStoreReading)? = nil, projects: (any ProjectsSyncing)? = nil) {
        self.store = store; self.sync = sync; self.summariesSource = summaries
        self.rosterSource = roster; self.send = send; self.rosterInterval = rosterInterval; self.now = now
        self.projectsStore = projectsStore; self.projects = projects
    }

    // MARK: Session lifetime

    public func start() {
        stop()
        tasks.append(observe(store.missionsStream(state: nil)) { vm, missions in
            vm.inputs.missions = missions
            vm.clearAskedIfAnswered(missions)
            if !vm.hasLoadedMissions {
                vm.hasLoadedMissions = true
                if vm.detailFanOutPending { vm.startDetailFanOut() }
            } else {
                vm.catchUpMissingDetails()
            }
        })
        tasks.append(observe(store.allMissionConversationsStream()) { $0.inputs.conversationsByMission = $1 })
        tasks.append(observe(store.latestMilestonesStream()) { $0.inputs.latestMilestones = $1 })
        tasks.append(observe(store.needsYouItemsByMissionStream()) { $0.inputs.needsYouItems = $1 })
        tasks.append(observe(store.latestSummaryTOCsStream()) { $0.inputs.tocs = $1 })
        tasks.append(observe(store.sessionStatesStream()) { $0.inputs.sessionStates = $1 })
        if let projectsStore {
            tasks.append(observe(projectsStore.projectsStream()) { $0.inputs.projects = $1 })
        }
        if let projects {
            tasks.append(Task { [weak self] in
                let stream = await projects.supportedStream()
                for await supported in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.projectsSupported = supported
                }
            })
        }
        isStarted = true
        tasks.append(Task { [weak self] in
            // Weakly re-checked every iteration (never a strong `self`
            // held across the wait for the next value) — the stream can
            // outlive a session that never yields again.
            guard let stream = await self?.sync.supportedStream() else { return }
            for await supported in stream {
                guard let self, !Task.isCancelled else { return }
                self.isSupported = supported
            }
        })
        listRefreshTask = Task { [weak self] in await self?.refreshList() }
        // The shell's `.task { vm.start() }` runs on a later main-actor
        // turn than a child page's `onAppear`, so the dashboard can already
        // be on screen (`pageVisible == true`) the moment a fresh session
        // starts. `stop()` just above tore down the previous roster loop
        // and detail fan-out without touching `pageVisible` — restart both
        // here so appear-then-start still polls and refreshes, exactly as
        // start-then-appear does.
        if pageVisible || missionPageVisible || projectPageVisible || looseSectionVisible { startSummariesIfNeeded() }
        if pageVisible || missionPageVisible || projectPageVisible { startRosterLoopIfNeeded() }
        if pageVisible { detailFanOutPending = true }
    }

    /// Session-scoped teardown: observers, the summaries, the roster loop and the detail
    /// fan-out. Deliberately leaves `pageVisible`/`detailFanOutPending`
    /// alone — those are the page's own state, not the session's, and
    /// `start()` reads `pageVisible` right after this runs to decide
    /// whether to restart the page work it just cancelled.
    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        listRefreshTask?.cancel(); listRefreshTask = nil
        isStarted = false
        summariesTask?.cancel(); summariesTask = nil
        rosterTask?.cancel(); rosterTask = nil
        retireDetailTask()
        pendingRebuildTask?.cancel(); pendingRebuildTask = nil
        hasLoadedMissions = false
        detailSession += 1
        lastDetailFanOutCompletedAt = nil
        detailRefreshedIDs = []
        queuedCatchUp = nil
    }

    private func observe<Value: Sendable>(
        _ stream: AsyncStream<Value>,
        _ apply: @escaping @MainActor (MissionsDashboardViewModel, Value) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                apply(self, value)
                self.scheduleRebuild()
            }
        }
    }

    /// Coalesces a burst of stream emissions landing in the same main-actor
    /// turn (a cold-launch snapshot fans out across five separate streams)
    /// into a single `assemble` — marks dirty and schedules one rebuild;
    /// later calls before it runs are no-ops. Checks cancellation FIRST: a
    /// cancelled task (only `stop()` cancels one, and it nils the reference
    /// in that same synchronous call) must never touch `pendingRebuildTask`
    /// — otherwise a task cancelled here but scheduled again before this
    /// closure gets to run would clear the *newer* one's reference out from
    /// under it, letting a follow-up `scheduleRebuild()` schedule a THIRD
    /// task and double the assemble the coalescing exists to prevent. Once
    /// past the cancellation check, this closure IS still the current
    /// `pendingRebuildTask` (nothing else can have replaced it — the guard
    /// above only lets a new one in while this one reads nil), so clearing
    /// it here is always correct.
    private func scheduleRebuild() {
        guard pendingRebuildTask == nil else { return }
        pendingRebuildTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.pendingRebuildTask = nil
            self.performRebuild()
        }
    }

    private func performRebuild() {
        rebuildRunCount += 1
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now())
        if cards != snapshot.cards { cards = snapshot.cards }
        if looseSessions != snapshot.looseSessions { looseSessions = snapshot.looseSessions }
        if closed != snapshot.closed { closed = snapshot.closed }
        if sessionsByMission != snapshot.sessionsByMission { sessionsByMission = snapshot.sessionsByMission }
        let nextHome = ProjectsHomeAssembly.assemble(projects: inputs.projects, missions: inputs.missions,
                                                     needsYouItems: inputs.needsYouItems, now: now())
        if home != nextHome { home = nextHome }
        updatePageMissionSessions()
    }

    // MARK: Page lifetime

    /// Idempotent: a second `onAppear` never starts a second poll loop.
    public func pageDidAppear() {
        pageVisible = true
        if isStarted { startSummariesIfNeeded() }
        startRosterLoopIfNeeded()
        refreshProjectsInBackground()
        if hasLoadedMissions { startDetailFanOut() } else { detailFanOutPending = true }
    }

    public func pageDidDisappear() {
        pageVisible = false
        detailFanOutPending = false
        queuedCatchUp = nil
        stopLiveFeedsIfUnwatched()
        retireDetailTask()
    }

    /// A mission page appeared: the session rows' titles and summaries stay
    /// current (chat summaries + roster poll). Idempotent, and independent
    /// of `pageDidAppear()` — SwiftUI can run the page's `onAppear` before
    /// the dashboard's `onDisappear` when one replaces the other, so each
    /// side only stops the feeds once neither shows.
    public func missionPageDidAppear(missionID: String) {
        pageMissionID = missionID
        updatePageMissionSessions()
        missionPageVisible = true
        if isStarted { startSummariesIfNeeded() }
        startRosterLoopIfNeeded()
    }

    public func missionPageDidDisappear() {
        missionPageVisible = false
        stopLiveFeedsIfUnwatched()
    }

    /// The project page shows session chips per mission: summaries + roster.
    public func projectPageDidAppear() {
        projectPageVisible = true
        if isStarted { startSummariesIfNeeded() }
        startRosterLoopIfNeeded()
        refreshProjectsInBackground()
    }

    public func projectPageDidDisappear() {
        projectPageVisible = false
        stopLiveFeedsIfUnwatched()
    }

    /// The Chats tab's "Not on a mission" section (spec §6): summaries only —
    /// its rows fall back to TOC / snippet text, so no roster poll runs while
    /// the chat list is simply on screen.
    public func looseSectionDidAppear() {
        looseSectionVisible = true
        if isStarted { startSummariesIfNeeded() }
    }

    public func looseSectionDidDisappear() {
        looseSectionVisible = false
        stopLiveFeedsIfUnwatched()
    }

    /// Preflight R4: project create, PATCH, status and close emit no
    /// marker, so a Projects surface appearing re-reads `GET /projects`.
    private func refreshProjectsInBackground() {
        guard let projects else { return }
        Task { _ = await projects.refresh() }
    }

    private func updatePageMissionSessions() {
        let slice = pageMissionID.flatMap { sessionsByMission[$0] } ?? []
        if slice != pageMissionSessions { pageMissionSessions = slice }
    }

    private func stopLiveFeedsIfUnwatched() {
        if !pageVisible, !missionPageVisible, !projectPageVisible {
            rosterTask?.cancel(); rosterTask = nil
        }
        guard !pageVisible, !missionPageVisible, !projectPageVisible, !looseSectionVisible else { return }
        summariesTask?.cancel(); summariesTask = nil
    }

    /// Whether the summaries subscription / roster poll are running —
    /// `internal` for tests.
    var isSummariesFeedLive: Bool { summariesTask != nil }
    var isRosterLoopLive: Bool { rosterTask != nil }

    /// Keeps the last list on close, so the page reads as it did until the
    /// next appear's subscription delivers a fresh one.
    private func startSummariesIfNeeded() {
        guard summariesTask == nil else { return }
        let summaries = summariesSource()
        summariesTask = Task { [weak self] in
            do {
                for try await list in summaries {
                    guard let self, !Task.isCancelled else { return }
                    self.inputs.summaries = list
                    self.scheduleRebuild()
                }
            } catch {
                // The chat list surfaces its own stream errors; the
                // dashboard keeps the last list it had.
            }
        }
    }

    private func startRosterLoopIfNeeded() {
        guard rosterTask == nil else { return }
        let interval = rosterInterval
        rosterTask = Task { [weak self] in
            while !Task.isCancelled {
                // `self?.fetchRoster()` only borrows `self` for the call
                // itself — nothing keeps it alive across the sleep below.
                await self?.fetchRoster()
                // Preflight R4: the same 60 s tick re-reads projects while
                // a Projects surface stays visible.
                await self?.refreshProjectsIfVisible()
                guard self != nil else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Throttled to once per `detailFanOutThrottle` (spec §3.7): a page
    /// appearing again moments after its own detail fan-out just completed
    /// (a tab switch, a quick backgrounding) has nothing fresher to ask for
    /// — except for open missions not yet fetched this session, which a
    /// throttled appear still fans out over (and only over those).
    /// Retires whatever fan-out is current; the new pass waits for every
    /// retired one to drain before dispatching (`installDetailPass`).
    private func startDetailFanOut() {
        detailFanOutPending = false
        guard pageVisible else { return }
        let throttled = lastDetailFanOutCompletedAt.map { now().timeIntervalSince($0) < Self.detailFanOutThrottle } ?? false
        if throttled, missingDetailIDs().isEmpty { return }
        retireDetailTask()
        installDetailPass(onlyMissing: throttled)
    }

    /// A missions emission while the page shows: fetch the detail of any
    /// open mission not fetched yet this session, whatever the throttle
    /// says. Queued behind the running fan-out rather than retiring it
    /// (that one may be a full pass the new mission must not cut short).
    /// The missing ids are recomputed when it runs, so a burst of emissions
    /// costs one pass.
    private func catchUpMissingDetails() {
        guard pageVisible, queuedCatchUp == nil, !missingDetailIDs().isEmpty else { return }
        let token = UUID()
        queuedCatchUp = token
        installDetailPass(onlyMissing: true, after: detailTask, catchUpToken: token)
    }

    /// The one place a detail pass is created and made current. It waits,
    /// in order, for `previous` (a catch-up queues behind the running pass;
    /// cancelling this one cancels that too, and since it keeps awaiting
    /// it, retiring this one retires both), then for every retired pass
    /// still draining — `MissionsSync.refreshMission` runs its network call
    /// in an unstructured `Task` that ignores cancellation, so dispatching
    /// alongside a cancelled batch's requests would stack up to 8 in flight.
    ///
    /// The predecessors and the session are captured HERE, synchronously:
    /// the new task can itself be retired into `drainingDetailTasks` while
    /// it waits, and awaiting its own `.value` would deadlock it; and a pass
    /// created before a `stop()` must never write into the next session.
    @discardableResult
    private func installDetailPass(onlyMissing: Bool, after previous: Task<Void, Never>? = nil,
                                   catchUpToken: UUID? = nil) -> Task<Void, Never> {
        let predecessors = drainingDetailTasks
        let session = detailSession
        let task = Task { [weak self] in
            if let previous {
                await withTaskCancellationHandler { await previous.value } onCancel: { previous.cancel() }
            }
            await self?.drainRetiredDetailTasks(predecessors)
            // Cleared even when cancelled (a re-appear or `refresh()` that
            // replaces this link never clears it), so catch-up never sticks
            // — but only this link's own slot.
            if let catchUpToken, self?.queuedCatchUp == catchUpToken { self?.queuedCatchUp = nil }
            guard !Task.isCancelled else { return }
            await self?.refreshOpenMissionDetails(onlyMissing: onlyMissing, session: session)
        }
        detailTask = task
        return task
    }

    private var openMissionIDs: [String] { inputs.missions.filter { $0.state == .open }.map(\.id) }

    private func missingDetailIDs() -> [String] { openMissionIDs.filter { !detailRefreshedIDs.contains($0) } }

    /// Cancels the current fan-out and parks it in `drainingDetailTasks`
    /// until it has finished — never drops it, since its requests can still
    /// be in flight. It removes itself once done, so a retired fan-out that
    /// no later one ever waits on (the page never reappears) doesn't linger.
    private func retireDetailTask() {
        guard let task = detailTask else { return }
        task.cancel()
        detailTask = nil
        drainingDetailTasks.append(task)
        Task { [weak self] in
            await task.value
            self?.drainingDetailTasks.removeAll { $0 == task }
        }
    }

    /// Awaits each of `tasks` (a snapshot of `drainingDetailTasks`), removing
    /// each from the list once it has finished. Safe for several callers to
    /// drain overlapping snapshots: awaiting a finished task is instant, and
    /// removing an already-removed one is a no-op.
    private func drainRetiredDetailTasks(_ tasks: [Task<Void, Never>]) async {
        guard !tasks.isEmpty else { return }
        detailDrainWaitCount += 1
        for task in tasks {
            await task.value
            drainingDetailTasks.removeAll { $0 == task }
        }
    }

    // MARK: Fetches

    /// Pull-to-refresh / the Mac refresh button: list, roster, details. A
    /// second call while one is still running is a no-op (multiple taps).
    /// Skips the detail step entirely before the first missions snapshot
    /// has landed — there is nothing to fan out over yet, and running it
    /// anyway would clear `detailFanOutPending`, silently dropping the
    /// page's own deferred fan-out for whenever missions do land.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshList()
        await fetchRoster()
        guard hasLoadedMissions else { return }
        await runDetailFanOutAwaitingPrevious()
    }

    private func refreshList() async {
        switch await sync.refresh() {
        case .succeeded: error = nil
        case .failed(let failure): error = failure.message
        case .unsupported, .stopped: break
        }
        if let projects, case .failed(let failure) = await projects.refresh(), error == nil {
            error = failure.message
        }
    }

    private func refreshProjectsIfVisible() async {
        guard pageVisible || projectPageVisible, let projects, !Task.isCancelled else { return }
        _ = await projects.refresh()
    }

    /// Spec §3.7: a failed fetch keeps the last good map and is not shown.
    private func fetchRoster() async {
        do {
            let map = try await rosterSource()
            guard !Task.isCancelled else { return }
            inputs.roster = map
            scheduleRebuild()
        } catch {
            // Deliberately silent (spec §3.7).
        }
    }

    /// `onlyMissing` limits the pass to open missions not fetched yet this
    /// session (a throttled appear, a newly arrived mission). `session` is
    /// the `detailSession` the pass was created in.
    private func refreshOpenMissionDetails(onlyMissing: Bool, session: Int) async {
        guard session == detailSession else { return }
        let open = openMissionIDs
        let ids = onlyMissing ? missingDetailIDs() : open
        // A pass over nothing (the empty first snapshot after sign-in or a
        // wipe) refreshed nothing and must not start the throttle's clock.
        guard !ids.isEmpty else { return }
        // Only a pass over every open mission known when it starts can
        // start the clock — full, or a catch-up that found all of them
        // missing (the sign-in path: empty snapshot, then the real one). A
        // catch-up over only the new ones left the others as old as they
        // were.
        let coversEveryOpenMission = ids.count == open.count
        let sync = self.sync
        await Self.forEach(ids, maxConcurrent: Self.maxDetailRefreshesInFlight) { [weak self] id in
            _ = await sync.refreshMission(id: id)
            await self?.markDetailRefreshed(id, session: session)
        }
        // A pass cut short by `pageDidDisappear()`/`stop()` (which cancel
        // `detailTask`) did not refresh everything, so the next appearance
        // must not skip it.
        guard !Task.isCancelled, coversEveryOpenMission, session == detailSession else { return }
        lastDetailFanOutCompletedAt = now()
    }

    /// Drops a mark from a pass of an earlier session (see `detailSession`).
    private func markDetailRefreshed(_ id: String, session: Int) {
        guard session == detailSession else { return }
        detailRefreshedIDs.insert(id)
    }

    /// Retires any detail fan-out already in flight — the page's own
    /// on-appear refresh, or an earlier `refresh()` — and waits for it and
    /// every earlier retired one to actually drain before starting a fresh
    /// one over every open mission, then awaits that one too. Never lets two
    /// fan-outs both count toward `Self.maxDetailRefreshesInFlight` at once.
    ///
    /// The drain is a LOOP: while this method is suspended, `pageDidAppear()`
    /// (or the missions handler) can install a brand new fan-out through
    /// `startDetailFanOut()`. Each round retires whatever is current and
    /// drains everything retired so far, until nothing is left — so none is
    /// ever orphaned, and none still has requests in flight when this
    /// method's own fan-out starts dispatching.
    private func runDetailFanOutAwaitingPrevious() async {
        detailFanOutPending = false
        retireDetailTask()
        while !drainingDetailTasks.isEmpty {
            await drainRetiredDetailTasks(drainingDetailTasks)
            retireDetailTask()
        }
        await installDetailPass(onlyMissing: false).value
    }

    /// Runs `body` for every id with at most `maxConcurrent` in flight;
    /// stops handing out ids once cancelled.
    nonisolated static func forEach(_ ids: [String], maxConcurrent: Int,
                                    _ body: @escaping @Sendable (String) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = ids.makeIterator()
            for _ in 0..<maxConcurrent {
                guard let id = pending.next() else { break }
                group.addTask { await body(id) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let id = pending.next() { group.addTask { await body(id) } }
            }
        }
    }

    // MARK: Ask the Coordinator (spec §3.4)

    /// Skipped while an Ask is in flight or within `askCooldown` of the
    /// last one sent (a double click); a failed Ask can be retried at once.
    public func askCoordinator() async {
        guard let convoID = Self.trimmed(coordinatorConvoID), !isAsking else { return }
        if let lastAskSentAt, now().timeIntervalSince(lastAskSentAt) < Self.askCooldown { return }
        isAsking = true
        defer { isAsking = false }
        do {
            try await send(convoID, Self.coordinatorRefreshMessage)
            let sentAt = now()
            askedAt = sentAt
            lastAskSentAt = sentAt
            startAskCooldown()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Projects (spec 2026-09-30 §6 "Filing")

    /// "New project". Returns the project so the host can open it.
    public func createProject(title: String, body: String?) async -> Project? {
        guard let projects else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Give the project a title."
            return nil
        }
        guard trimmed.utf16.count <= Self.maxProjectTitleUTF16 else {
            error = "Keep the title under 200 characters."
            return nil
        }
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await projects.createProject(title: trimmed, body: trimmedBody?.isEmpty == true ? nil : trimmedBody)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// "Move to project…" on a row. `nil` takes it out of its project.
    public func moveMission(_ missionID: String, to projectID: String?) async {
        guard let projects else { return }
        do { _ = try await projects.setMissionProject(missionID: missionID, project: projectID) }
        catch { self.error = error.localizedDescription }
    }

    private func startAskCooldown() {
        askCoolingDown = true
        askCooldownTask?.cancel()
        askCooldownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.askCooldown))
            guard !Task.isCancelled else { return }
            self?.askCoolingDown = false
        }
    }

    private func clearAskedIfAnswered(_ missions: [Mission]) {
        guard let askedAt else { return }
        let answered = missions.contains { $0.state == .open && ($0.statusUpdatedAt.map { $0 >= askedAt } ?? false) }
        if answered { self.askedAt = nil }
    }

    private static func trimmed(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return id
    }
}
