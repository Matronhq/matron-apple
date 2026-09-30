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

    /// The project shown. Changes when the project turns out to have been
    /// merged into another (spec §4.2 redirect), or after a merge from here.
    public private(set) var projectID: String
    public private(set) var page: ProjectPageModel?
    /// The journal says there is no such project and nothing is cached.
    public private(set) var isMissing = false
    public private(set) var isBusy = false
    public var error: String?

    @ObservationIgnored private var project: Project?
    @ObservationIgnored private var missions: [Mission] = []
    @ObservationIgnored private var needsYou: [TrackerItem] = []
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
    /// re-read the project on every tick until `stop()`.
    public func start() {
        stop()
        isStarted = true
        sharedTasks.append(observe(store.projectsStream()) { $0.openProjects = $1.filter { $0.state == .open } })
        sharedTasks.append(observe(store.unfiledOpenMissionsStream()) { $0.unfiled = $1 })
        observeProject()
        refreshTask = Task { [weak self] in await self?.refresh() }
        let interval = refreshInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshProject()
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
        project = nil; missions = []; needsYou = []; milestones = []; sessionsByBox = [:]
        page = nil
        isMissing = false
        if isStarted { observeProject() }
    }

    private func rebuild() {
        guard let project else {
            if page != nil { page = nil }
            return
        }
        var byMission: [String: [TrackerItem]] = [:]
        for item in needsYou { if let id = item.missionID { byMission[id, default: []].append(item) } }
        // Preflight R5: the journal refuses a merge from, or filing into, a
        // closed project, so a closed page offers neither.
        let isOpen = project.state == .open
        let next = ProjectPageModel(
            project: project,
            missions: ProjectsHomeAssembly.missionRows(missions, needsYouItems: byMission, now: now()),
            closedMissions: missions.filter { $0.state == .closed },
            needsYou: needsYou, recentMilestones: milestones,
            missionNums: Dictionary(missions.map { ($0.id, $0.num) }, uniquingKeysWith: { first, _ in first }),
            sessionsByBox: sessionsByBox,
            mergeTargets: isOpen ? openProjects.filter { $0.id != project.id } : [],
            unfiledMissions: isOpen ? unfiled : [])
        if page != next { page = next }
    }

    /// Re-reads the project, follows a server redirect, then refreshes the
    /// open missions' details.
    public func refresh() async {
        guard await refreshProject() else { return }
        await refreshOpenMissionDetails()
    }

    /// `GET /projects/:id` for the current id. Returns whether it loaded.
    /// An answer for an id the page has since left (a merge from here, an
    /// earlier redirect) is dropped: it must not drag the page back.
    @discardableResult
    private func refreshProject() async -> Bool {
        let requested = projectID
        let outcome = await projects.refreshProject(id: requested)
        guard requested == projectID else { return false }
        switch outcome {
        case .loaded(let resolved):
            error = nil
            isMissing = false
            if resolved != requested { switchTo(resolved) }
            return true
        case .notFound:
            isMissing = project == nil
            return false
        case .failed(let failure):
            error = failure.message
            return false
        case .stopped:
            return false
        }
    }

    /// The session chips on each mission row come from the missions'
    /// conversations, which only a detail fetch fills.
    private func refreshOpenMissionDetails() async {
        let ids = missions.filter { $0.state == .open }.map(\.id)
        let sync = missionsSync
        await MissionsDashboardViewModel.forEach(ids, maxConcurrent: MissionsDashboardViewModel.maxDetailRefreshesInFlight) { id in
            _ = await sync.refreshMission(id: id)
        }
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

    /// A row's "Move to…". Moving into this project needs it open
    /// (preflight R5); moving out of it, or unfiling, always works.
    public func moveMission(_ missionID: String, to projectID: String?) async {
        if projectID == self.projectID, project?.state != .open { return }
        isBusy = true
        defer { isBusy = false }
        do { _ = try await projects.setMissionProject(missionID: missionID, project: projectID) }
        catch { self.error = error.localizedDescription }
    }
}
