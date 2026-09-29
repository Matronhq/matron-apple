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
/// roster poll and the per-mission detail refresh.
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
    /// Tri-state exactly as `MissionsListViewModel.isSupported`: `nil`
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
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRebuildTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedMissions = false
    @ObservationIgnored private var pageVisible = false
    @ObservationIgnored private var detailFanOutPending = false
    /// When a full detail fan-out (over every open mission, at least one)
    /// last ran to completion — not merely started, cancelled partway, or
    /// run over nothing — the page-appear throttle's clock.
    @ObservationIgnored private var lastDetailFanOutCompletedAt: Date?
    /// Missions whose detail has been fetched this session. The throttle
    /// only ever skips a repeat pass over these; an open mission missing
    /// from it is fetched whenever the page shows (PR 265: GRDB's first
    /// snapshot after sign-in or a wipe is empty, so the first pass covers
    /// nothing and the real missions arrive in a later emission).
    @ObservationIgnored private var detailRefreshedIDs: Set<String> = []
    /// A catch-up pass for newly arrived missions is queued behind the
    /// current fan-out — at most one waits at a time.
    @ObservationIgnored private var detailCatchUpQueued = false

    public init(store: any MissionsDashboardStoreReading, sync: any MissionsSyncing,
                summaries: @escaping @Sendable () -> AsyncThrowingStream<[ChatSummary], Error>,
                roster: @escaping @Sendable () async throws -> [String: String],
                send: @escaping @Sendable (_ convoID: String, _ body: String) async throws -> Void,
                rosterInterval: Duration = .seconds(60),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.sync = sync; self.summariesSource = summaries
        self.rosterSource = roster; self.send = send; self.rosterInterval = rosterInterval; self.now = now
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
        let summaries = summariesSource()
        tasks.append(Task { [weak self] in
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
        })
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
        if pageVisible {
            startRosterLoopIfNeeded()
            detailFanOutPending = true
        }
    }

    /// Session-scoped teardown: observers, the roster loop and the detail
    /// fan-out. Deliberately leaves `pageVisible`/`detailFanOutPending`
    /// alone — those are the page's own state, not the session's, and
    /// `start()` reads `pageVisible` right after this runs to decide
    /// whether to restart the roster loop it just cancelled.
    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        listRefreshTask?.cancel(); listRefreshTask = nil
        rosterTask?.cancel(); rosterTask = nil
        detailTask?.cancel(); detailTask = nil
        pendingRebuildTask?.cancel(); pendingRebuildTask = nil
        hasLoadedMissions = false
        lastDetailFanOutCompletedAt = nil
        detailRefreshedIDs = []
        detailCatchUpQueued = false
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
    }

    // MARK: Page lifetime

    /// Idempotent: a second `onAppear` never starts a second poll loop.
    public func pageDidAppear() {
        pageVisible = true
        startRosterLoopIfNeeded()
        if hasLoadedMissions { startDetailFanOut() } else { detailFanOutPending = true }
    }

    public func pageDidDisappear() {
        pageVisible = false
        detailFanOutPending = false
        detailCatchUpQueued = false
        rosterTask?.cancel(); rosterTask = nil
        detailTask?.cancel(); detailTask = nil
    }

    private func startRosterLoopIfNeeded() {
        guard rosterTask == nil else { return }
        let interval = rosterInterval
        rosterTask = Task { [weak self] in
            while !Task.isCancelled {
                // `self?.fetchRoster()` only borrows `self` for the call
                // itself — nothing keeps it alive across the sleep below.
                await self?.fetchRoster()
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
    /// Chained behind whatever fan-out is already running rather than
    /// replacing it outright — `MissionsSync.refreshMission` launches its
    /// network call in an unstructured `Task` that ignores this caller's
    /// cancellation, so a re-appear mid-fan-out that just cancelled and
    /// replaced `detailTask` used to leave the old batch's requests running
    /// ALONGSIDE the new batch's, up to 8 in flight at once. Awaiting the
    /// previous task first (its cancellation only stops it from handing out
    /// ids it hadn't reached yet) means only one batch is ever actively
    /// dispatching new requests.
    private func startDetailFanOut() {
        detailFanOutPending = false
        guard pageVisible else { return }
        let throttled = lastDetailFanOutCompletedAt.map { now().timeIntervalSince($0) < Self.detailFanOutThrottle } ?? false
        if throttled, missingDetailIDs().isEmpty { return }
        let previous = detailTask
        previous?.cancel()
        detailTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.refreshOpenMissionDetails(onlyMissing: throttled)
        }
    }

    /// A missions emission while the page shows: fetch the detail of any
    /// open mission not fetched yet this session, whatever the throttle
    /// says. Queued behind the running fan-out rather than cancelling it
    /// (that one may be a full pass the new mission must not cut short),
    /// so the cap still holds; cancelling this link (disappear, `stop()`,
    /// `refresh()`'s drain, a re-appear) cancels the one it waits on too.
    /// The missing ids are recomputed when it runs, so a burst of
    /// emissions costs one pass.
    private func catchUpMissingDetails() {
        guard pageVisible, !detailCatchUpQueued, !missingDetailIDs().isEmpty else { return }
        detailCatchUpQueued = true
        let previous = detailTask
        detailTask = Task { [weak self] in
            await withTaskCancellationHandler { await previous?.value } onCancel: { previous?.cancel() }
            // Cleared even when cancelled (a re-appear or `refresh()` that
            // replaces this link never clears it), so catch-up never sticks.
            self?.detailCatchUpQueued = false
            guard !Task.isCancelled else { return }
            await self?.refreshOpenMissionDetails(onlyMissing: true)
        }
    }

    private var openMissionIDs: [String] { inputs.missions.filter { $0.state == .open }.map(\.id) }

    private func missingDetailIDs() -> [String] { openMissionIDs.filter { !detailRefreshedIDs.contains($0) } }

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
    /// session (a throttled appear, a newly arrived mission).
    private func refreshOpenMissionDetails(onlyMissing: Bool = false) async {
        let ids = onlyMissing ? missingDetailIDs() : openMissionIDs
        // A pass over nothing (the empty first snapshot after sign-in or a
        // wipe) refreshed nothing and must not start the throttle's clock.
        guard !ids.isEmpty else { return }
        let sync = self.sync
        await Self.forEach(ids, maxConcurrent: Self.maxDetailRefreshesInFlight) { [weak self] id in
            _ = await sync.refreshMission(id: id)
            await self?.markDetailRefreshed(id)
        }
        // Only a genuine, uninterrupted FULL pass starts the throttle's
        // clock — a fan-out cut short by `pageDidDisappear()`/`stop()`
        // (which cancel `detailTask`) did not actually refresh everything,
        // so the next appearance must not skip it; a missing-only pass
        // left the others as old as they were.
        guard !Task.isCancelled, !onlyMissing else { return }
        lastDetailFanOutCompletedAt = now()
    }

    private func markDetailRefreshed(_ id: String) { detailRefreshedIDs.insert(id) }

    /// Cancels any detail fan-out already in flight — the page's own
    /// on-appear refresh, or an earlier `refresh()` — and waits for it to
    /// actually drain before starting a fresh one over every open mission,
    /// then awaits that one too. Never lets two fan-outs both count toward
    /// `Self.maxDetailRefreshesInFlight` at once (a stacked pull-to-refresh
    /// used to run alongside the page's own refresh, up to 8+ in flight).
    ///
    /// The drain is a LOOP, not a single cancel-then-await: while this
    /// method is suspended at `await existing.value`, `pageDidAppear()` (or
    /// the missions handler) can install a brand new fan-out through
    /// `startDetailFanOut()` before this method gets a turn again. A single
    /// cancel-then-await would overwrite that new one without ever
    /// cancelling it — orphaning it, uncounted and unawaited. Nilling
    /// `detailTask` before each await, then re-checking it once the drain
    /// completes, catches however many rounds of that interference land
    /// before installing this method's own fresh fan-out.
    private func runDetailFanOutAwaitingPrevious() async {
        detailFanOutPending = false
        while let existing = detailTask {
            existing.cancel()
            detailTask = nil
            await existing.value
        }
        detailTask = Task { [weak self] in await self?.refreshOpenMissionDetails() }
        await detailTask?.value
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

    public func askCoordinator() async {
        guard let convoID = Self.trimmed(coordinatorConvoID) else { return }
        do {
            try await send(convoID, Self.coordinatorRefreshMessage)
            askedAt = now()
        } catch {
            self.error = error.localizedDescription
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
