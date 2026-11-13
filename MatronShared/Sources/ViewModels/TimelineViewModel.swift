import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs the Projects weekly timeline. Weeks load newest first; the quiet and
/// long lists load once per visit-until-refresh, the finished and
/// all-projects lists page.
/// A journal without the timeline routes (404 on the weeks list) leaves
/// `isSupported` false so the host falls back to the plain Projects list.
///
/// A read that was called off sets no `error`: nothing failed.
@MainActor @Observable
public final class TimelineViewModel {
    /// The remote flag that turns the timeline on.
    public static let flagKey = "projects.timeline"

    public private(set) var weeks: [TimelineWeekSummary] = []
    /// nil until the first load, then the newest week.
    public private(set) var place: TimelinePlace?
    /// The last week that loaded: a failed load keeps it on screen.
    public private(set) var week: TimelineWeek?
    public private(set) var quiet: StalledList?
    public private(set) var long: StalledList?
    public private(set) var finished: [FinishedProject] = []
    /// The finished list's first read has landed: until then it has no
    /// page, after it an empty list is one.
    public private(set) var hasLoadedFinished = false
    /// Every project, as far as it has been paged: the pages' rows under
    /// the newest page's count and cursor. nil until the first read.
    public private(set) var allProjects: TimelineProjectList?
    /// nil before the first weeks load; false once the journal answered 404.
    public private(set) var isSupported: Bool?
    /// nil until the all-projects list answers; false once the journal
    /// answered 404 for it (it has the weeks, not that list). The hosts
    /// then offer no "All projects" and nothing asks for it again.
    public private(set) var projectsSupported: Bool?
    /// Projects the Coordinator was asked about in this session: their
    /// rows say so instead of offering the Ask again, across refreshes.
    public private(set) var askedProjectIDs: Set<String> = []
    public var error: String?
    /// The shown week's projects past its stories, as far as they have
    /// been paged, most active first (`weekExtras(for:)`). A re-read of the
    /// week starts them over.
    public private(set) var weekProjects: [TimelineWeekProject] = []
    public private(set) var weekProjectsStatus: TimelineWeekExtras.Status = .done
    /// nil until the week-projects read answers; false once the journal
    /// answered 404 for it (it has the weeks, not that read). Its weeks then
    /// keep their "Also moved" line and nothing asks for it again.
    public private(set) var weekProjectsSupported: Bool?

    /// Projects per week-projects read.
    public static let weekProjectsPageSize = 24

    public var hasEarlierWeeks: Bool { weeksNextBefore != nil }
    public var hasMoreFinished: Bool { finishedNextBefore != nil }
    public var hasMoreProjects: Bool { allProjects?.nextBefore != nil }

    @ObservationIgnored private let timeline: TimelineProviding
    @ObservationIgnored private let askCoordinator: (String) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var weeksNextBefore: String?
    @ObservationIgnored private var finishedNextBefore: String?
    /// Lists loaded since the last refresh; weeks always re-read.
    @ObservationIgnored private var fresh: Set<TimelinePlace> = []
    /// Bumped when a reload replaces a paged list: a page fetched before is dropped.
    @ObservationIgnored private var weeksGeneration = 0
    @ObservationIgnored private var finishedGeneration = 0
    @ObservationIgnored private var projectsGeneration = 0
    /// Bumped by each week read: only the newest read's answer (or
    /// failure) lands, so a slower, older read of the same week never
    /// replaces a newer one or says an error over it.
    @ObservationIgnored private var weekGeneration = 0
    /// Bumped by `refresh()`: a quiet/long result fetched before it is dropped.
    @ObservationIgnored private var refreshEpoch = 0
    /// The week the paged projects belong to, and the next page's offset
    /// (nil when there is none to read).
    @ObservationIgnored private(set) var weekProjectsKey: String?
    @ObservationIgnored private var weekProjectsNextOffset: Int?
    /// Bumped each time a week lands: a page read for the week as it was
    /// before is dropped.
    @ObservationIgnored private var weekProjectsGeneration = 0
    @ObservationIgnored private var isLoadingEarlier = false
    @ObservationIgnored private var isLoadingFinished = false
    @ObservationIgnored private var isLoadingProjects = false
    /// A first-page reload is in flight: paging off the old cursor would mix
    /// two lists, so paging waits for it.
    @ObservationIgnored private var isReloadingWeeks = false
    @ObservationIgnored private var isReloadingFinished = false
    @ObservationIgnored private var isReloadingProjects = false

    public init(timeline: TimelineProviding, askCoordinator: @escaping (String) async throws -> Void,
                now: @escaping () -> Date = Date.init) {
        self.timeline = timeline; self.askCoordinator = askCoordinator; self.now = now
    }

    /// Loads the weeks list and the current place (the newest week on the first call).
    public func start() async {
        error = nil
        guard await loadWeeks() else { return }
        if place == nil, let first = weeks.first { place = .week(first.week) }
        await loadCurrent()
    }

    public func select(_ next: TimelinePlace) async {
        place = next
        error = nil
        await loadCurrent()
    }

    /// Re-reads the weeks and the place on screen; the lists off screen
    /// reload on their next visit.
    public func refresh() async {
        refreshEpoch += 1
        fresh.removeAll()
        await start()
    }

    /// Reads the went-quiet and open-a-long-time lists and the first page
    /// of all projects, those not read since the last refresh, so the
    /// sidebar has their counts before any is visited; a visit then shows
    /// the list without reading it again. A failure stays quiet: the count
    /// is a hint, and the visit retries.
    public func loadCounts() async {
        let epoch = refreshEpoch
        let timeline = self.timeline
        let needsQuiet = !fresh.contains(.quiet), needsLong = !fresh.contains(.long)
        let needsProjects = !fresh.contains(.projects) && projectsSupported != false
        async let quietRead = Self.read(needsQuiet) { try await timeline.wentQuiet() }
        async let longRead = Self.read(needsLong) { try await timeline.openLong() }
        async let projectsRead = Self.attempt(needsProjects) { try await timeline.timelineProjects(before: nil, limit: nil) }
        let (quietList, longList, projectsResult) = await (quietRead, longRead, projectsRead)
        // Whether the journal has the list holds across a refresh.
        noteProjectsSupport(projectsResult)
        let projectList = try? projectsResult?.get()
        guard epoch == refreshEpoch else { return }
        // A visit that read the list meanwhile is as fresh: keep it.
        if let quietList, !fresh.contains(.quiet) { quiet = quietList; fresh.insert(.quiet) }
        if let longList, !fresh.contains(.long) { long = longList; fresh.insert(.long) }
        // A visit reading the first page right now brings its own.
        if let projectList, !fresh.contains(.projects), !isReloadingProjects {
            // A page fetched off the list this replaces is dropped.
            projectsGeneration += 1
            allProjects = projectList
            fresh.insert(.projects)
        }
    }

    public func loadEarlierWeeks() async {
        guard let before = weeksNextBefore, !isLoadingEarlier, !isReloadingWeeks else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        let generation = weeksGeneration
        do {
            let page = try await timeline.timelineWeeks(before: before, limit: nil)
            guard generation == weeksGeneration else { return }
            weeks += page.weeks
            weeksNextBefore = page.nextBefore
        } catch {
            if generation == weeksGeneration, !error.isReadCancellation { self.error = error.localizedDescription }
        }
    }

    public func loadMoreFinished() async {
        guard let before = finishedNextBefore, !isLoadingFinished, !isReloadingFinished else { return }
        isLoadingFinished = true
        defer { isLoadingFinished = false }
        let generation = finishedGeneration
        do {
            let page = try await timeline.finishedProjects(before: before, limit: nil)
            guard generation == finishedGeneration else { return }
            finished += page.rows
            finishedNextBefore = page.nextBefore
        } catch {
            if generation == finishedGeneration, !error.isReadCancellation { self.error = error.localizedDescription }
        }
    }

    public func loadMoreProjects() async {
        guard let shown = allProjects, let before = shown.nextBefore,
              !isLoadingProjects, !isReloadingProjects else { return }
        isLoadingProjects = true
        defer { isLoadingProjects = false }
        let generation = projectsGeneration
        do {
            let page = try await timeline.timelineProjects(before: before, limit: nil)
            guard generation == projectsGeneration else { return }
            allProjects = TimelineProjectList(total: page.total, rows: shown.rows + page.rows, nextBefore: page.nextBefore)
        } catch {
            if generation == projectsGeneration, !error.isReadCancellation { self.error = error.localizedDescription }
        }
    }

    /// Reads the next page of the shown week's projects past its stories:
    /// when the page reaches its end, and for Retry. Asks for nothing while
    /// a page is being read, after the last, or from a journal without the read.
    public func loadMoreWeekProjects() async {
        guard let key = weekProjectsKey, let offset = weekProjectsNextOffset,
              weekProjectsStatus == .more || weekProjectsStatus == .failed else { return }
        let generation = weekProjectsGeneration
        weekProjectsStatus = .loading
        do {
            let page = try await timeline.timelineWeekProjects(key, offset: offset, limit: Self.weekProjectsPageSize)
            guard generation == weekProjectsGeneration else { return }
            weekProjectsSupported = true
            // A project shows once: the week's own cards come first, and a
            // list that shifted between pages repeats none.
            var seen = Set((week?.stories ?? []).map(\.project.id) + weekProjects.map(\.project.id))
            weekProjects += page.projects.filter { seen.insert($0.project.id).inserted }
            // An offset that does not move on would read the same page forever.
            if let next = page.nextOffset, next > offset {
                weekProjectsNextOffset = next
                weekProjectsStatus = .more
            } else {
                weekProjectsNextOffset = nil
                weekProjectsStatus = .done
            }
        } catch JournalAPIError.notFound where offset == 0 {
            guard generation == weekProjectsGeneration else { return }
            weekProjectsSupported = false
            weekProjectsNextOffset = nil
            weekProjectsStatus = .unsupported
        } catch {
            guard generation == weekProjectsGeneration else { return }
            // Called off too: the row offers Retry rather than asking again
            // at once, which a transport that keeps calling reads off would
            // turn into a loop.
            weekProjectsStatus = .failed
        }
    }

    /// A week landed: its projects past the stories start over, with
    /// nothing to read when no other project moved or the journal has no
    /// such read.
    private func resetWeekProjects(for week: TimelineWeek) {
        weekProjectsGeneration += 1
        weekProjectsKey = week.week
        weekProjects = []
        if weekProjectsSupported == false {
            weekProjectsNextOffset = nil
            weekProjectsStatus = .unsupported
        } else if week.also.isEmpty {
            weekProjectsNextOffset = nil
            weekProjectsStatus = .done
        } else {
            weekProjectsNextOffset = 0
            weekProjectsStatus = .more
        }
    }

    /// Hands a stalled project to the Coordinator as a question.
    public func ask(about stalled: StalledProject) async {
        let title = stalled.project.title
        let moved = stalled.lastMovedAt.map { "It last moved \(Self.relative($0, to: now()))." } ?? "It hasn't moved yet."
        do {
            try await askCoordinator("What should we do with the project “\(title)”? \(moved)")
            askedProjectIDs.insert(stalled.project.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Loading

    /// Reads the first page of weeks. False when there is nothing to build on
    /// (unsupported journal, a read called off, or a failed read, which
    /// sets `error`).
    private func loadWeeks() async -> Bool {
        weeksGeneration += 1
        let generation = weeksGeneration
        isReloadingWeeks = true
        defer { if generation == weeksGeneration { isReloadingWeeks = false } }
        do {
            let page = try await timeline.timelineWeeks(before: nil, limit: nil)
            guard generation == weeksGeneration else { return false }
            weeks = page.weeks
            weeksNextBefore = page.nextBefore
            isSupported = true
            return true
        } catch JournalAPIError.notFound {
            if generation == weeksGeneration { isSupported = false }
            return false
        } catch {
            if generation == weeksGeneration, !error.isReadCancellation { self.error = error.localizedDescription }
            return false
        }
    }

    private func loadCurrent() async {
        guard let target = place else { return }
        if case .week = target {} else if fresh.contains(target) { return }
        let epoch = refreshEpoch
        if case .week = target { weekGeneration += 1 }
        let generation = weekGeneration
        do {
            switch target {
            case .week(let key):
                let loaded = try await timeline.timelineWeek(key)
                // A later select moved on, or a newer read started, while this was in flight.
                if place == target, generation == weekGeneration {
                    week = loaded
                    resetWeekProjects(for: loaded)
                }
            case .quiet:
                let loaded = try await timeline.wentQuiet()
                guard epoch == refreshEpoch else { return }
                quiet = loaded
            case .long:
                let loaded = try await timeline.openLong()
                guard epoch == refreshEpoch else { return }
                long = loaded
            case .finished:
                finishedGeneration += 1
                let generation = finishedGeneration
                isReloadingFinished = true
                defer { if generation == finishedGeneration { isReloadingFinished = false } }
                let page = try await timeline.finishedProjects(before: nil, limit: nil)
                guard generation == finishedGeneration else { return }
                finished = page.rows
                finishedNextBefore = page.nextBefore
                hasLoadedFinished = true
            case .projects:
                projectsGeneration += 1
                let generation = projectsGeneration
                isReloadingProjects = true
                defer { if generation == projectsGeneration { isReloadingProjects = false } }
                let result = await Self.attempt(true) { [timeline] in try await timeline.timelineProjects(before: nil, limit: nil) }
                noteProjectsSupport(result)
                guard let page = try result?.get(), generation == projectsGeneration else { return }
                allProjects = page
            }
            if case .week = target {} else { fresh.insert(target) }
        } catch {
            if case .week = target, generation != weekGeneration { return }
            // A read that was called off is not a failure.
            if place == target, !error.isReadCancellation { self.error = error.localizedDescription }
        }
    }

    /// What an all-projects first-page read says of the route: an answer
    /// means the journal has it, a 404 that it does not.
    private func noteProjectsSupport(_ result: Result<TimelineProjectList, Error>?) {
        switch result {
        case .success: projectsSupported = true
        case .failure(JournalAPIError.notFound): projectsSupported = false
        case .failure, nil: break
        }
    }

    /// `read()`'s answer or failure when `needed`, nil when not.
    private nonisolated static func attempt<List: Sendable>(_ needed: Bool,
                                                            _ read: @Sendable () async throws -> List) async -> Result<List, Error>? {
        guard needed else { return nil }
        do { return .success(try await read()) } catch { return .failure(error) }
    }

    /// `read()` when `needed`, nil when not or when it fails.
    private nonisolated static func read<List: Sendable>(_ needed: Bool,
                                                         _ read: @Sendable () async throws -> List) async -> List? {
        guard needed else { return nil }
        return try? await read()
    }

    private static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_GB")
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
