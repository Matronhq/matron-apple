import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs one project page (spec 2026-09-30 §2 "Project page"). Everything
/// it shows comes from the store; `refresh()` fills the store from
/// `GET /projects/:id` and then refreshes the open missions' details so
/// their session chips have conversations to draw.
///
/// A project that was merged away redirects to its target two ways (spec
/// §4.2): the cached row is closed with `merged_into` (works offline, and
/// the instant a list refresh lands), or `GET /projects/:id` answers with
/// the target's detail — `ProjectsSync.refreshProject` reports the id the
/// journal answered with, so a different id is the redirect.
@MainActor @Observable
public final class ProjectDetailViewModel {
    public static let recentMilestoneCount = 5
    /// A re-appear this soon after the page's last completed detail pass
    /// re-reads only the project (pr3-review M6) — the dashboard's
    /// `detailFanOutThrottle`, for the same reason: Back from each mission
    /// page would otherwise re-fetch every open mission's detail.
    public static let detailRefreshThrottle = MissionsDashboardViewModel.detailFanOutThrottle

    /// The project shown. Changes when the project turns out to have been
    /// merged into another (spec §4.2 redirect), or after a merge from here.
    public private(set) var projectID: String
    public private(set) var page: ProjectPageModel?
    /// The journal says there is no such project and nothing is cached.
    public private(set) var isMissing = false
    /// The last `GET /projects/:id` failed and there is nothing cached to
    /// show (pr4-review I1, Bugbot 281-2). Hosts draw "Couldn't load this
    /// project" with a Try again that calls `refresh()`, instead of a
    /// spinner that only the next tick could end. Cleared when a load
    /// succeeds, when the store delivers the project, and while `refresh()`
    /// retries (the host shows its spinner meanwhile).
    public private(set) var loadFailed = false
    public private(set) var isBusy = false
    /// A failed user action (merge, move, add). Background refreshes never
    /// set it: a failed refresh keeps the page on screen silently, or sets
    /// `loadFailed` when there is none.
    public var error: String?

    @ObservationIgnored private var project: Project?
    @ObservationIgnored private var missions: [Mission] = []
    @ObservationIgnored private var needsYou: [TrackerItem] = []
    @ObservationIgnored private var openItems: [TrackerItem] = []
    @ObservationIgnored private var milestones: [Milestone] = []
    @ObservationIgnored private var sessionsByBox: [String: Int] = [:]
    @ObservationIgnored private var openProjects: [Project] = []
    @ObservationIgnored private var unfiled: [Mission] = []
    @ObservationIgnored private var projectTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var sharedTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Between `start()` and `stop()`: the page is on screen.
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private let store: any ProjectsStoreReading
    @ObservationIgnored private let projects: any ProjectsSyncing
    @ObservationIgnored private let missionsSync: any MissionsSyncing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let refreshInterval: Duration
    /// The project whose open missions' details were last fetched in full,
    /// and when that pass completed: the throttle's clock (same pattern as
    /// `MissionsDashboardViewModel.lastDetailFanOutCompletedAt`). A pass a
    /// `stop()` cancelled never sets it.
    @ObservationIgnored private var lastDetailPass: (projectID: String, completedAt: Date)?

    /// Test seam: whether the missions stream has delivered anything.
    var hasMissions: Bool { !missions.isEmpty }

    /// `refreshInterval` is preflight R4's tick: while the page is visible
    /// the project is re-read at the dashboard's roster cadence, because
    /// project PATCH, status, close and merge emit no marker.
    public init(projectID: String, store: any ProjectsStoreReading, projects: any ProjectsSyncing,
                missions: any MissionsSyncing, now: @escaping @Sendable () -> Date = { Date() },
                refreshInterval: Duration = .seconds(60)) {
        self.projectID = projectID; self.store = store; self.projects = projects
        self.missionsSync = missions; self.now = now; self.refreshInterval = refreshInterval
    }

    /// The page appeared: subscribe, refresh once (R4 "on appear"), then
    /// re-read the project on every tick until `stop()`. The appear's
    /// mission-detail pass is throttled (`detailRefreshThrottle`).
    public func start() {
        stop()
        isStarted = true
        sharedTasks.append(observe(store.projectsStream()) { $0.openProjects = $1.filter { $0.state == .open } })
        sharedTasks.append(observe(store.unfiledOpenMissionsStream()) { $0.unfiled = $1 })
        observeProject()
        refreshTask = Task { [weak self] in await self?.refreshOnAppear() }
        let interval = refreshInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refreshProject()
            }
        }
    }

    public func stop() {
        isStarted = false
        for t in projectTasks + sharedTasks { t.cancel() }
        projectTasks = []; sharedTasks = []
        refreshTask?.cancel(); refreshTask = nil
        tickTask?.cancel(); tickTask = nil
    }

    private func observeProject() {
        for t in projectTasks { t.cancel() }
        let id = projectID
        projectTasks = [
            observe(store.projectStream(id: id)) { vm, project in
                if let project, project.state == .closed, let target = project.mergedInto, target != id {
                    vm.redirect(to: target)
                } else {
                    vm.project = project
                }
            },
            observe(store.missionsStream(projectID: id)) { $0.missions = $1 },
            observe(store.needsYouItemsStream(projectID: id)) { $0.needsYou = $1 },
            observe(store.openItemsStream(projectID: id)) { $0.openItems = $1 },
            observe(store.recentMilestonesStream(projectID: id, limit: Self.recentMilestoneCount)) { $0.milestones = $1 },
            observe(store.projectSessionsByBoxStream(id: id)) { $0.sessionsByBox = $1 },
        ]
    }

    private func observe<Value: Sendable>(_ stream: AsyncStream<Value>,
                                          _ apply: @escaping @MainActor (ProjectDetailViewModel, Value) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            for await value in stream {
                guard let self, !Task.isCancelled else { return }
                apply(self, value)
                self.rebuild()
            }
        }
    }

    /// The cached row says this project was merged away: follow it, and
    /// fetch the target so its page fills even if nothing of it is cached.
    private func redirect(to target: String) {
        switchTo(target)
        guard isStarted else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    private func switchTo(_ id: String) {
        guard id != projectID else { return }
        projectID = id
        project = nil; missions = []; needsYou = []; openItems = []; milestones = []; sessionsByBox = [:]
        page = nil
        isMissing = false
        loadFailed = false
        if isStarted { observeProject() }
    }

    private func rebuild() {
        guard let project else {
            if page != nil { page = nil }
            return
        }
        if loadFailed { loadFailed = false }
        var byMission: [String: [TrackerItem]] = [:]
        for item in needsYou { if let id = item.missionID { byMission[id, default: []].append(item) } }
        // Preflight R5: the journal refuses a merge from, or filing into, a
        // closed project, so a closed page offers neither. Moving a mission
        // out into an open project is still allowed (only a closed target
        // is refused), so `moveTargets` is not gated.
        let isOpen = project.state == .open
        let next = ProjectPageModel(
            project: project,
            missions: ProjectsHomeAssembly.missionRows(missions, needsYouItems: byMission, now: now()),
            closedMissions: missions.filter { $0.state == .closed },
            needsYou: needsYou, openItems: openItems, recentMilestones: milestones,
            missionNums: Dictionary(missions.map { ($0.id, $0.num) }, uniquingKeysWith: { first, _ in first }),
            sessionsByBox: sessionsByBox,
            mergeTargets: isOpen ? openProjects.filter { $0.id != project.id } : [],
            moveTargets: openProjects,
            unfiledMissions: isOpen ? unfiled : [])
        if page != next { page = next }
    }

    /// Re-reads the project, follows a server redirect, then refreshes the
    /// open missions' details. Never throttled.
    public func refresh() async {
        if loadFailed { loadFailed = false }
        guard await refreshProject() else { return }
        await refreshOpenMissionDetails()
    }

    /// `refresh()`, except that within `detailRefreshThrottle` of this
    /// project's last completed detail pass only the project is re-read.
    /// A server redirect still gets its detail pass: the target's missions
    /// are a different page's, and the throttle is per project.
    private func refreshOnAppear() async {
        let id = projectID
        let throttled = lastDetailPass.map {
            $0.projectID == id && now().timeIntervalSince($0.completedAt) < Self.detailRefreshThrottle
        } ?? false
        guard throttled else { return await refresh() }
        guard await refreshProject(), projectID != id else { return }
        await refreshOpenMissionDetails()
    }

    /// `GET /projects/:id` for the current id. Returns whether it loaded.
    /// An answer for an id the page has since left (a merge from here, an
    /// earlier redirect) is dropped: it must not drag the page back.
    ///
    /// A failure never raises `error`: this runs on appear and on every
    /// tick, so an offline page would get an alert a minute (pr4-review
    /// I1). With the project cached the page stays as it was, like the
    /// dashboard's roster; with nothing cached it reports `loadFailed`.
    @discardableResult
    private func refreshProject() async -> Bool {
        let requested = projectID
        let outcome = await projects.refreshProject(id: requested)
        guard requested == projectID else { return false }
        switch outcome {
        case .loaded(let resolved):
            isMissing = false
            loadFailed = false
            if resolved != requested { switchTo(resolved) }
            return true
        case .notFound:
            isMissing = project == nil
            loadFailed = false
            return false
        case .failed:
            loadFailed = project == nil
            return false
        case .stopped:
            return false
        }
    }

    /// The session chips on each mission row come from the missions'
    /// conversations, which only a detail fetch fills.
    ///
    /// The ids come from the store, read after `refreshProject()` has
    /// written the project's missions — not from `missions`, which a
    /// redirect's `switchTo` has just emptied and whose stream may not have
    /// delivered the target's rows yet (PR2-M1), and which on a first open
    /// with nothing cached is still empty when the fetch returns.
    private func refreshOpenMissionDetails() async {
        let id = projectID
        var ids: [String] = []
        for await current in store.missionsStream(projectID: id) {
            ids = current.filter { $0.state == .open }.map(\.id)
            break
        }
        guard !Task.isCancelled else { return }
        let sync = missionsSync
        await MissionsDashboardViewModel.forEach(ids, maxConcurrent: MissionsDashboardViewModel.maxDetailRefreshesInFlight) { id in
            _ = await sync.refreshMission(id: id)
        }
        guard !Task.isCancelled else { return }
        lastDetailPass = (projectID: id, completedAt: now())
    }

    /// "Merge into…" (spec §4.2): its missions move to `target` and this
    /// project closes. The page follows its missions. Only an open project
    /// merges (preflight R5), and never into itself.
    public func merge(into target: String) async -> Bool {
        guard project?.state == .open else { return false }
        let source = projectID
        guard target != source else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await projects.mergeProject(id: source, into: target)
            switchTo(target)
            // `mergeProject` has re-read the target, so the store holds its
            // missions — the ones moved in included. Their session chips
            // need a detail pass, whatever the throttle says.
            if isStarted {
                refreshTask?.cancel()
                refreshTask = Task { [weak self] in await self?.refreshOpenMissionDetails() }
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// "Add a mission": files it into this project, which must be open
    /// (preflight R5).
    public func addMission(_ missionID: String) async {
        guard project?.state == .open else { return }
        await moveMission(missionID, to: projectID)
    }

    /// A row's "Move to…". The target must be open (preflight R5): this
    /// project when it is open, or another project the store knows is open.
    /// A closed or unknown target (a stale menu entry) is refused here
    /// rather than surfacing the journal's 409. Unfiling always works.
    public func moveMission(_ missionID: String, to projectID: String?) async {
        if let projectID {
            let targetIsOpen = projectID == self.projectID
                ? project?.state == .open
                : openProjects.contains { $0.id == projectID }
            guard targetIsOpen else { return }
        }
        isBusy = true
        defer { isBusy = false }
        do { _ = try await projects.setMissionProject(missionID: missionID, project: projectID) }
        catch { self.error = error.localizedDescription }
    }
}
