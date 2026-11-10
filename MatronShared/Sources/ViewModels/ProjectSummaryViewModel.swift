import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs one project's page on the timeline: the page itself, and its
/// week-by-week history once the reader asks for it, a page at a time.
///
/// The journal answers 404 both for a project it doesn't have and when it
/// has no project-page route at all, so a 404 is settled by one read of
/// the all-projects list: that list answering means the project is gone
/// (`isMissing`), a 404 there too means the journal is older than the
/// page (`isUnsupported`) and the host shows the project page it had.
///
/// A project merged into another answers with the one it became:
/// `redirectedTo` names it and every later read asks for it.
@MainActor @Observable
public final class ProjectSummaryViewModel {
    /// The last page that loaded: a failed read keeps it on screen.
    public private(set) var page: TimelineProjectPage?
    /// The project's weeks newest first, as far as they have been paged.
    public private(set) var history: [TimelineHistoryWeek] = []
    /// The journal has no such project.
    public private(set) var isMissing = false
    /// The journal has no project-page route.
    public private(set) var isUnsupported = false
    /// The project the one asked for was merged into, once the journal says so.
    public private(set) var redirectedTo: String?
    public var error: String?

    public var hasMoreHistory: Bool { historyNextBefore != nil }

    @ObservationIgnored private let timeline: TimelineProviding
    /// The project every read asks for: the one given, then the one it was merged into.
    @ObservationIgnored private var projectID: String
    @ObservationIgnored private var historyNextBefore: String?
    @ObservationIgnored private var hasAskedForHistory = false
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

    /// Re-reads the page, and the history's first page once it was asked for.
    public func refresh() async {
        error = nil
        await loadPage()
        if hasAskedForHistory, !isMissing, !isUnsupported { await loadHistory() }
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
            historyNextBefore = loaded.nextBefore
        } catch {
            if generation == historyGeneration { self.error = error.localizedDescription }
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
            if generation == historyGeneration { self.error = error.localizedDescription }
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
            isUnsupported = false
            if loaded.mergedFromID != nil, loaded.project.id != projectID {
                redirectedTo = loaded.project.id
                projectID = loaded.project.id
            }
        } catch JournalAPIError.notFound {
            await settleNotFound(generation)
        } catch {
            if generation == pageGeneration { self.error = error.localizedDescription }
        }
    }

    /// The page answered 404: the all-projects list says whether the
    /// project is gone or the journal has no such route.
    private func settleNotFound(_ generation: Int) async {
        do {
            _ = try await timeline.timelineProjects(before: nil, limit: 1)
            guard generation == pageGeneration else { return }
            isMissing = true
            isUnsupported = false
        } catch JournalAPIError.notFound {
            guard generation == pageGeneration else { return }
            isUnsupported = true
            isMissing = false
        } catch {
            if generation == pageGeneration { self.error = error.localizedDescription }
        }
    }
}
