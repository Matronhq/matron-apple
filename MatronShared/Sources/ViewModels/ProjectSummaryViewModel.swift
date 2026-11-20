import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs one project's page on the timeline: the page itself, and its
/// week-by-week history once the reader asks for it, a page at a time.
///
/// A 404 means the journal has no such project (`isMissing`).
///
/// A project merged into another answers with the one it became:
/// `redirectedTo` names it and every later read asks for it.
///
/// A read that was called off sets no `error`: nothing failed.
@MainActor @Observable
public final class ProjectSummaryViewModel {
    /// The last page that loaded: a failed read keeps it on screen.
    public private(set) var page: TimelineProjectPage?
    /// The project's weeks newest first, as far as they have been paged.
    public private(set) var history: [TimelineHistoryWeek] = []
    /// The journal has no such project.
    public private(set) var isMissing = false
    /// The project the one asked for was merged into, once the journal says so.
    public private(set) var redirectedTo: String?
    public var error: String?

    public var hasMoreHistory: Bool { historyNextBefore != nil }

    @ObservationIgnored private let timeline: TimelineProviding
    /// The project every read asks for: the one given, then the one it was merged into.
    @ObservationIgnored private var projectID: String
    @ObservationIgnored private var historyNextBefore: String?
    @ObservationIgnored private var hasAskedForHistory = false
    /// A first page of the history has landed.
    @ObservationIgnored private var hasLoadedHistory = false
    /// Bumped by each page read: only the newest read's answer (or failure) lands.
    @ObservationIgnored private var pageGeneration = 0
    /// Bumped when a reload replaces the history: a page fetched before is dropped.
    @ObservationIgnored private var historyGeneration = 0
    @ObservationIgnored private var isLoadingMoreHistory = false
    /// A first-page reload is in flight: paging off the old cursor would mix
    /// two lists, so paging waits for it.
    @ObservationIgnored private var isReloadingHistory = false

    public init(projectID: String, timeline: TimelineProviding) {
        self.projectID = projectID; self.timeline = timeline
    }

    /// Loads the page.
    public func start() async {
        error = nil
        await loadPage()
    }

    /// Re-reads the page, and the history's first page once it was asked
    /// for: a pull to refresh, or after a change to the project. The
    /// history starts over from its first page.
    public func refresh() async {
        await refreshPage()
        if hasAskedForHistory, !isMissing { await loadHistory() }
    }

    /// Re-reads the page alone, for coming back to it: the history stays
    /// as far as it was paged.
    public func refreshPage() async {
        error = nil
        await loadPage()
    }

    /// Reads the history's first page unless it has loaded (or is being
    /// read): the history section coming on screen, the first time or
    /// again, without losing the pages read since.
    public func loadHistoryIfNeeded() async {
        guard !hasLoadedHistory, !isReloadingHistory else { return }
        await loadHistory()
    }

    /// Reads the history's first page, replacing what was loaded.
    public func loadHistory() async {
        hasAskedForHistory = true
        historyGeneration += 1
        let generation = historyGeneration
        isReloadingHistory = true
        defer { if generation == historyGeneration { isReloadingHistory = false } }
        do {
            let loaded = try await timeline.timelineProjectHistory(projectID, before: nil, limit: nil)
            guard generation == historyGeneration else { return }
            history = loaded.weeks
            hasLoadedHistory = true
            historyNextBefore = loaded.nextBefore
        } catch {
            if generation == historyGeneration, !error.isReadCancellation { self.error = error.localizedDescription }
        }
    }

    public func loadMoreHistory() async {
        guard let before = historyNextBefore, !isLoadingMoreHistory, !isReloadingHistory else { return }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }
        let generation = historyGeneration
        do {
            let loaded = try await timeline.timelineProjectHistory(projectID, before: before, limit: nil)
            guard generation == historyGeneration else { return }
            history += loaded.weeks
            historyNextBefore = loaded.nextBefore
        } catch {
            if generation == historyGeneration, !error.isReadCancellation { self.error = error.localizedDescription }
        }
    }

    // MARK: - Loading

    private func loadPage() async {
        pageGeneration += 1
        let generation = pageGeneration
        do {
            let loaded = try await timeline.timelineProject(projectID)
            guard generation == pageGeneration else { return }
            page = loaded
            isMissing = false
            if loaded.mergedFromID != nil, loaded.project.id != projectID {
                redirectedTo = loaded.project.id
                projectID = loaded.project.id
            }
        } catch JournalAPIError.notFound {
            if generation == pageGeneration { isMissing = true }
        } catch {
            if generation == pageGeneration, !error.isReadCancellation { self.error = error.localizedDescription }
        }
    }
}
