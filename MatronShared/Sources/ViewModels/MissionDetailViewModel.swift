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

    private let store: any MissionsStoreReading
    private let sync: any MissionsSyncing
    /// Unfiltered, as the store delivered it — `applyFilter` derives
    /// `milestones` from this, so toggling the filter needs no refetch.
    private var allMilestones: [Milestone] = []
    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?

    public init(missionID: String, store: any MissionsStoreReading, sync: any MissionsSyncing) {
        self.missionID = missionID; self.store = store; self.sync = sync
    }

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
        sessionTags = store.sessionTags(convoIDs: Set(allMilestones.map(\.convoID)))
    }

    public func start() {
        stop()
        let id = missionID
        tasks.append(Task { [weak self] in
            guard let s = self?.store.missionStream(id: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.mission = v }
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
            for await v in s { guard let self, !Task.isCancelled else { return }; self.openItems = v }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.missionConversationsStream(missionID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.conversations = v }
        })
        // Conversations and the full milestone list only reach the local
        // cache through a detail fetch — opening the page must trigger one.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        refreshTask?.cancel(); refreshTask = nil
    }

    /// A failed refresh sets `error` — the same alert plumbing `close()`
    /// already feeds — so a cold open with nothing cached (a milestone
    /// card tap, a title tap, a `#N`) while the journal is unreachable
    /// surfaces a retryable message instead of dead-ending on the "not on
    /// this device yet" placeholder forever (MAJOR-4).
    public func refresh() async {
        // As in `MissionsListViewModel.refresh()`: a success clears a stale
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
}
