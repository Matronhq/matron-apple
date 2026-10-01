import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs one mission page (spec: Apps → Missions tab → Page). Reads flow
/// from the local store's streams; the single write — the user's close —
/// goes through `MissionsSyncing`.
@MainActor @Observable
public final class MissionDetailViewModel {
    public let missionID: String
    public private(set) var mission: Mission?
    /// Newest first, already filtered by `showOnlyUserInput`.
    public private(set) var milestones: [Milestone] = []
    /// "My inputs only" — the toggle that turns the page into a list of the
    /// user's own redirections.
    public var showOnlyUserInput = false { didSet { if showOnlyUserInput != oldValue { applyFilter() } } }
    /// Open items in this mission, awaiting-you first (the store's order).
    public private(set) var openItems: [TrackerItem] = []
    /// Whether the open-items stream has delivered at least once — until
    /// then `openItems` is "not read yet", not "none" (the needs-you count
    /// falls back to the server's).
    public private(set) var hasLoadedOpenItems = false
    /// The mission's closed items, most recently closed first, at most
    /// `closedItemsLimit`. Empty unless the host passed a
    /// `closedItems` reader (the Mac board does; iOS does not).
    public private(set) var closedItems: [TrackerItem] = []
    /// Every closed item this device has for the mission, whatever the
    /// limit — the Done column's count and "Show more".
    public private(set) var closedItemsTotal = 0
    /// How many closed items `closedItems` is asked for. Grows through
    /// `loadClosedItems(atLeast:)`.
    public private(set) var closedItemsLimit = MissionDetailViewModel.closedItemsPage
    /// The step `closedItemsLimit` grows by.
    public static let closedItemsPage = 50
    public private(set) var conversations: [MissionConversation] = []
    /// The `A:bc` tag halves for every conversation the milestones name,
    /// keyed by conversation id — a mission spans several sessions, so each
    /// row says which one it came from. A conversation this device has not
    /// cached has no entry, and its rows render untagged (never a
    /// placeholder). Rebuilt whenever the milestone list changes.
    public private(set) var sessionTags: [String: SessionTagInputs] = [:]
    public var closeSummaryDraft = ""
    public private(set) var isBusy = false
    public var error: String?
    /// The project this mission is filed in (spec 2026-09-30 §6 "Mission
    /// page" chip and breadcrumb), when it is cached.
    public private(set) var project: Project?
    /// "Move to project…" choices: every open project.
    public private(set) var moveTargets: [Project] = []
    /// On it now / Earlier, sub-chats folded (spec §2), with each
    /// conversation's live session state winning over the detail row's.
    /// The ONE place the page's groups are built: hosts pass it into
    /// `MissionDetailView.Model(conversationGroups:)`.
    public private(set) var conversationGroups = MissionConversationGroups(conversations: [], missionState: .open)
    /// `ProjectsSyncing.supportedStream()`'s latest answer; `nil` until it
    /// first yields. `false` once `GET /projects` has answered 404 — the
    /// same signal `MissionsDashboardViewModel.projectsSupported` follows.
    public private(set) var projectsSupported: Bool?
    /// "Move to project…" is offered only where projects exist: never on a
    /// journal that answered 404 for `/projects` (pr3-review M2). Unknown
    /// (`nil`) keeps it offered.
    public var canMove: Bool { projects != nil && projectsSupported != false }

    private let store: any MissionsStoreReading
    private let sync: any MissionsSyncing
    private let closedItemsReader: (any MissionClosedItemsReading)?
    private let refreshItems: (@Sendable () async -> Void)?
    private let projectsStore: (any ProjectsStoreReading)?
    private let projects: (any ProjectsSyncing)?
    private var allProjects: [Project] = []
    /// The store's live `session_state` per conversation id.
    private var liveStates: [String: String] = [:]
    /// Every room with known participants; `conversationGroups.rooms`
    /// keeps those on this mission.
    private var rooms: [MissionRoom] = []
    private var closedItemsTask: Task<Void, Never>?
    /// Unfiltered, as the store delivered it — `applyFilter` derives
    /// `milestones` from this, so toggling the filter needs no refetch.
    private var allMilestones: [Milestone] = []
    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?

    /// `closedItems` and `refreshItems` go together on the Mac: the board
    /// reads closed items from the local cache, and `refreshItems` (the
    /// tracker's incremental all-states list refresh) brings in items the
    /// server re-pointed to this mission without a marker.
    public init(missionID: String, store: any MissionsStoreReading, sync: any MissionsSyncing,
                closedItems: (any MissionClosedItemsReading)? = nil,
                refreshItems: (@Sendable () async -> Void)? = nil,
                projectsStore: (any ProjectsStoreReading)? = nil, projects: (any ProjectsSyncing)? = nil) {
        self.missionID = missionID; self.store = store; self.sync = sync
        self.closedItemsReader = closedItems; self.refreshItems = refreshItems
        self.projectsStore = projectsStore; self.projects = projects
    }

    /// The newest milestone whatever "My inputs only" says — the Mac
    /// page's "Latest step".
    public var latestMilestone: Milestone? { allMilestones.first }

    public static func filtered(_ milestones: [Milestone], showOnlyUserInput: Bool) -> [Milestone] {
        showOnlyUserInput ? milestones.filter { $0.kind == .userInput } : milestones
    }

    private func applyFilter() { milestones = Self.filtered(allMilestones, showOnlyUserInput: showOnlyUserInput) }

    /// One batch read for every DISTINCT conversation in the unfiltered
    /// list, so toggling "My inputs only" costs nothing, a 40-milestone
    /// mission posted in three sessions does three conversation reads (not
    /// forty), and the box roster is read once rather than once per
    /// conversation on every milestone-stream emission (MINOR-5).
    private func refreshSessionTags() {
        let next = store.sessionTags(convoIDs: Set(allMilestones.map(\.convoID)).union(conversations.map(\.id))
            .union(roomParticipantIDs))
        if next != sessionTags { sessionTags = next }
    }

    /// Recomputes everything that depends on `mission`, `conversations` or
    /// `allProjects` — the three streams a project or a conversation-group
    /// change can arrive on.
    private func refreshDerived() {
        project = mission?.projectID.flatMap { id in allProjects.first { $0.id == id } }
        moveTargets = allProjects.filter { $0.state == .open }
        refreshConversationGroups()
        refreshSessionTags()
    }

    /// The participant conversations of the rooms on this page.
    private var roomParticipantIDs: Set<String> { Set(conversationGroups.rooms.flatMap(\.room.participantConvoIDs)) }

    private func refreshConversationGroups() {
        let next = MissionConversationGroups(conversations: conversations, missionState: mission?.state ?? .open,
                                             liveStates: liveStates, rooms: rooms)
        if next != conversationGroups { conversationGroups = next }
    }

    public func start() {
        stop()
        let id = missionID
        tasks.append(Task { [weak self] in
            guard let s = self?.store.missionStream(id: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.mission = v
                self.refreshDerived()
            }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.milestonesStream(missionID: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.allMilestones = v
                self.applyFilter()
                self.refreshSessionTags()
            }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemsStream(missionID: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.openItems = v
                self.hasLoadedOpenItems = true
            }
        })
        if let reader = closedItemsReader {
            let count = reader.closedItemsCountStream(missionID: id)
            tasks.append(Task { [weak self] in
                for await v in count { guard let self, !Task.isCancelled else { return }; self.closedItemsTotal = v }
            })
            observeClosedItems()
        }
        tasks.append(Task { [weak self] in
            guard let s = self?.store.missionConversationsStream(missionID: id) else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.conversations = v
                self.refreshDerived()
            }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.sessionStatesStream() else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                self.liveStates = v
                self.refreshConversationGroups()
            }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.roomsStream() else { return }
            for await v in s {
                guard let self, !Task.isCancelled else { return }
                // The rooms stream re-emits on every message in ANY room
                // (their activity is a column it reads): re-read tags only
                // when this page's room participants actually changed.
                let before = self.roomParticipantIDs
                self.rooms = v
                self.refreshConversationGroups()
                if self.roomParticipantIDs != before { self.refreshSessionTags() }
            }
        })
        if let projectsStore {
            tasks.append(Task { [weak self] in
                let s = projectsStore.projectsStream()
                for await v in s {
                    guard let self, !Task.isCancelled else { return }
                    self.allProjects = v
                    self.refreshDerived()
                }
            })
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
        // Conversations and the full milestone list only reach the local
        // cache through a detail fetch — opening the page must trigger one.
        refreshTask?.cancel()
        let refreshItems = self.refreshItems
        refreshTask = Task { [weak self] in
            await self?.refresh()
            // After the detail fetch (which upserts the open items): the
            // list refresh picks up closed items re-pointed to this mission
            // with no marker. Incremental from the tracker's watermark.
            await refreshItems?()
        }
    }

    /// Asks for at least `count` closed items ("Show more" past what is
    /// loaded), growing the limit by whole pages. No-op without a reader or
    /// when enough are already asked for.
    public func loadClosedItems(atLeast count: Int) {
        guard closedItemsReader != nil, count > closedItemsLimit else { return }
        let page = Self.closedItemsPage
        closedItemsLimit = ((count + page - 1) / page) * page
        if closedItemsTask != nil { observeClosedItems() }
    }

    private func observeClosedItems() {
        guard let reader = closedItemsReader else { return }
        closedItemsTask?.cancel()
        let stream = reader.closedItemsStream(missionID: missionID, limit: closedItemsLimit)
        closedItemsTask = Task { [weak self] in
            for await v in stream { guard let self, !Task.isCancelled else { return }; self.closedItems = v }
        }
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        closedItemsTask?.cancel(); closedItemsTask = nil
        refreshTask?.cancel(); refreshTask = nil
    }

    /// A failed refresh sets `error` — the same alert plumbing `close()`
    /// already feeds — so a cold open with nothing cached (a milestone
    /// card tap, a title tap, a `#N`) while the journal is unreachable
    /// surfaces a retryable message instead of dead-ending on the "not on
    /// this device yet" placeholder forever (MAJOR-4).
    public func refresh() async {
        // As in `MissionsDashboardViewModel.refresh()`: a success clears a stale
        // banner from an earlier failed refresh (MAJOR-4's retry path has
        // the same shape).
        switch await sync.refreshMission(id: missionID) {
        case .succeeded: error = nil
        case .failed(let failure): error = failure.message
        case .unsupported, .stopped: break
        }
    }

    /// The user's close. Always permitted server-side, even over open items
    /// — the journal records the override and the close marker names the
    /// numbers. The host shows a confirmation first
    /// (`MissionDetailView.confirmationTitle(openItems:)`) naming how many
    /// items stay open, when any do.
    public func close() async {
        let summary = closeSummaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            error = "Write a short summary before closing the mission."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await sync.closeMission(id: missionID, summary: summary)
            closeSummaryDraft = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Move to project…" (spec §6 "Filing"). `nil` takes it out. Targets
    /// are pre-filtered to open projects only (R5): a closed project 409s
    /// on both a merge and a file-into, which would otherwise surface as a
    /// bare "conflict". The same rule is enforced here too, not just in
    /// `moveTargets` — a stale menu, or a caller that bypasses it, must not
    /// be able to file into a closed or unknown project (matches T12's
    /// `ProjectDetailViewModel.moveMission` guard).
    public func moveToProject(_ projectID: String?) async {
        guard let projects else { return }
        if let projectID, allProjects.first(where: { $0.id == projectID })?.state != .open { return }
        isBusy = true
        defer { isBusy = false }
        do { _ = try await projects.setMissionProject(missionID: missionID, project: projectID) }
        catch { self.error = error.localizedDescription }
    }
}
