import Foundation
import Observation
import MatronModels

/// A shell's Projects timeline, one per window, behind
/// `TimelineViewModel.flagKey`: the view model (built on the first visit
/// to Projects, and only with the flag on) and the place picked in the
/// list or the week menu. With the flag off, or on a journal without the
/// timeline routes, Projects stays the home it is today.
@MainActor @Observable
public final class TimelineHostState {
    public private(set) var viewModel: TimelineViewModel?
    /// The pick, set at once so the page follows the tap in the same
    /// frame; the view model's own `place` (the newest week before any
    /// pick) follows when its read starts.
    public private(set) var selection: TimelinePlace?
    /// The last week picked: the week page under a list (the iPhone's root).
    private var pickedWeek: String?

    public init() {}

    public static func flagOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: TimelineViewModel.flagKey)
    }

    /// The timeline replaces the home only once the journal has answered
    /// the weeks list: until then (nil) there is nothing to show instead.
    public var isShown: Bool { viewModel?.isSupported == true }

    public var place: TimelinePlace? { selection ?? viewModel?.place }

    /// The week on screen, else the last one picked, else the newest.
    public var week: String? {
        if case .week(let key) = place { return key }
        return pickedWeek ?? viewModel?.weeks.first?.week
    }

    /// Projects came on screen: the first time (flag on; nil reads it)
    /// builds and starts the view model, then reads the counts; later
    /// visits re-read what is on screen and the counts, unless the journal
    /// has no timeline (its 404 would only come again). Returns the reads' task.
    @discardableResult
    public func projectsShown(flagOn: Bool? = nil, build: () -> TimelineViewModel) -> Task<Void, Never>? {
        if let viewModel {
            guard viewModel.isSupported != false else { return nil }
            return Task { await refresh() }
        }
        guard flagOn ?? Self.flagOn() else { return nil }
        let viewModel = build()
        self.viewModel = viewModel
        return Task {
            await viewModel.start()
            // A journal without the timeline has no lists to count either.
            guard viewModel.isSupported != false else { return }
            // A place picked before the view model existed (Back onto a
            // timeline place after an account switch) wins over the
            // newest week `start()` opened on.
            if let selection = self.selection, viewModel.place != selection { await viewModel.select(selection) }
            await viewModel.loadCounts()
        }
    }

    /// Re-reads the place on screen and the counts (pull to refresh, a later visit).
    public func refresh() async {
        guard let viewModel, viewModel.isSupported != false else { return }
        await viewModel.refresh()
        await viewModel.loadCounts()
    }

    public func select(_ place: TimelinePlace?) {
        selection = place
        if case .week(let key) = place { pickedWeek = key }
        guard let place, let viewModel, viewModel.place != place else { return }
        Task { await viewModel.select(place) }
    }

    /// A new session: nothing of the old one's timeline carries over.
    public func reset() {
        viewModel = nil
        selection = nil
        pickedWeek = nil
    }
}
