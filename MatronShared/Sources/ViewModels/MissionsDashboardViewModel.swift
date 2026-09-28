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
            rebuild()
        }
    }

    public var canAskCoordinator: Bool { Self.trimmed(coordinatorConvoID) != nil }
    /// The tab / nav badge.
    public var needsYouTotal: Int { cards.reduce(0) { $0 + $1.needsYouCount } }

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
    @ObservationIgnored private var hasLoadedMissions = false
    @ObservationIgnored private var pageVisible = false
    @ObservationIgnored private var detailFanOutPending = false

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
                    self.rebuild()
                }
            } catch {
                // The chat list surfaces its own stream errors; the
                // dashboard keeps the last list it had.
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let stream = await self.sync.supportedStream()
            for await supported in stream {
                guard !Task.isCancelled else { return }
                self.isSupported = supported
            }
        })
        listRefreshTask = Task { [weak self] in await self?.refreshList() }
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        listRefreshTask?.cancel(); listRefreshTask = nil
        pageDidDisappear()
        hasLoadedMissions = false
    }

    private func observe<Value: Sendable>(
        _ stream: AsyncStream<Value>,
        _ apply: @escaping @MainActor (MissionsDashboardViewModel, Value) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                apply(self, value)
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now())
        if cards != snapshot.cards { cards = snapshot.cards }
        if looseSessions != snapshot.looseSessions { looseSessions = snapshot.looseSessions }
        if closed != snapshot.closed { closed = snapshot.closed }
    }

    // MARK: Page lifetime

    /// Idempotent: a second `onAppear` never starts a second poll loop.
    public func pageDidAppear() {
        pageVisible = true
        guard rosterTask == nil else { return }
        let interval = rosterInterval
        rosterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let vm = self else { return }
                await vm.fetchRoster()
                try? await Task.sleep(for: interval)
            }
        }
        if hasLoadedMissions { startDetailFanOut() } else { detailFanOutPending = true }
    }

    public func pageDidDisappear() {
        pageVisible = false
        detailFanOutPending = false
        rosterTask?.cancel(); rosterTask = nil
        detailTask?.cancel(); detailTask = nil
    }

    private func startDetailFanOut() {
        detailFanOutPending = false
        guard pageVisible else { return }
        detailTask?.cancel()
        detailTask = Task { [weak self] in await self?.refreshOpenMissionDetails() }
    }

    // MARK: Fetches

    /// Pull-to-refresh / the Mac refresh button: list, roster, details.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshList()
        await fetchRoster()
        await refreshOpenMissionDetails()
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
            rebuild()
        } catch {
            // Deliberately silent (spec §3.7).
        }
    }

    private func refreshOpenMissionDetails() async {
        let ids = inputs.missions.filter { $0.state == .open }.map(\.id)
        let sync = self.sync
        await Self.forEach(ids, maxConcurrent: Self.maxDetailRefreshesInFlight) { id in
            _ = await sync.refreshMission(id: id)
        }
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
