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

    /// The confirmation to show before a close, or `nil` when nothing is
    /// open and the close needs no extra ceremony.
    public var closeConfirmation: String? {
        guard !openItems.isEmpty else { return nil }
        return "Close with \(openItems.count) item\(openItems.count == 1 ? "" : "s") still open?"
    }

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

    /// One store read per DISTINCT conversation in the unfiltered list, so
    /// toggling "My inputs only" costs nothing and a 40-milestone mission
    /// posted in three sessions does three reads, not forty.
    private func refreshSessionTags() {
        var tags: [String: SessionTagInputs] = [:]
        for convoID in Set(allMilestones.map(\.convoID)) {
            if let tag = store.sessionTag(convoID: convoID) { tags[convoID] = tag }
        }
        sessionTags = tags
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

    public func refresh() async { await sync.refreshMission(id: missionID) }

    /// The user's close. Always permitted server-side, even over open items
    /// — the journal records the override and the close marker names the
    /// numbers. The host shows `closeConfirmation` first when it is non-nil.
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
