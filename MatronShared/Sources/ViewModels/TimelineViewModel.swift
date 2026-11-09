import Foundation
import Observation
import MatronModels
import MatronJournal

/// Backs the Projects weekly timeline. Weeks load newest first; the quiet and
/// long lists load once per visit-until-refresh, the finished list pages.
/// A journal without the timeline routes (404 on the weeks list) leaves
/// `isSupported` false so the host falls back to the plain Projects list.
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
    /// nil before the first weeks load; false once the journal answered 404.
    public private(set) var isSupported: Bool?
    /// Projects the Coordinator was asked about since the lists last
    /// reloaded: their rows say so instead of offering the Ask again.
    public private(set) var askedProjectIDs: Set<String> = []
    public var error: String?

    public var hasEarlierWeeks: Bool { weeksNextBefore != nil }
    public var hasMoreFinished: Bool { finishedNextBefore != nil }

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
    /// Bumped by `refresh()`: a quiet/long result fetched before it is dropped.
    @ObservationIgnored private var refreshEpoch = 0
    @ObservationIgnored private var isLoadingEarlier = false
    @ObservationIgnored private var isLoadingFinished = false
    /// A first-page reload is in flight: paging off the old cursor would mix
    /// two lists, so paging waits for it.
    @ObservationIgnored private var isReloadingWeeks = false
    @ObservationIgnored private var isReloadingFinished = false

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
        askedProjectIDs.removeAll()
        await start()
    }

    /// Reads the went-quiet and open-a-long-time lists not read since the
    /// last refresh, so the sidebar has their counts before either is
    /// visited; a visit then shows the list without reading it again. A
    /// failure stays quiet: the count is a hint, and the visit retries.
    public func loadCounts() async {
        let epoch = refreshEpoch
        let timeline = self.timeline
        let needsQuiet = !fresh.contains(.quiet), needsLong = !fresh.contains(.long)
        async let quietRead = Self.read(needsQuiet) { try await timeline.wentQuiet() }
        async let longRead = Self.read(needsLong) { try await timeline.openLong() }
        let (quietList, longList) = await (quietRead, longRead)
        guard epoch == refreshEpoch else { return }
        // A visit that read the list meanwhile is as fresh: keep it.
        if let quietList, !fresh.contains(.quiet) { quiet = quietList; fresh.insert(.quiet) }
        if let longList, !fresh.contains(.long) { long = longList; fresh.insert(.long) }
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
            if generation == weeksGeneration { self.error = error.localizedDescription }
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
            if generation == finishedGeneration { self.error = error.localizedDescription }
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
    /// (unsupported journal, or a failed read, which sets `error`).
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
            if generation == weeksGeneration { self.error = error.localizedDescription }
            return false
        }
    }

    private func loadCurrent() async {
        guard let target = place else { return }
        if case .week = target {} else if fresh.contains(target) { return }
        let epoch = refreshEpoch
        do {
            switch target {
            case .week(let key):
                let loaded = try await timeline.timelineWeek(key)
                // A later select moved on while this was in flight.
                if place == target { week = loaded }
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
            }
            if case .week = target {} else { fresh.insert(target) }
        } catch {
            if place == target { self.error = error.localizedDescription }
        }
    }

    /// `read()` when `needed`, nil when not or when it fails.
    private nonisolated static func read(_ needed: Bool,
                                         _ read: @Sendable () async throws -> StalledList) async -> StalledList? {
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
