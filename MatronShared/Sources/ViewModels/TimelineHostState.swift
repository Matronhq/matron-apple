import Foundation
import Observation
import MatronModels

/// A shell's Projects timeline, one per window: the view model (built on
/// the first visit to Projects) and the place picked in the list or the
/// week menu.
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

    /// The timeline is Projects once its view model is built, from the
    /// first visit on; its pages show their own loading state until the
    /// journal answers. Only a journal without the timeline (404 on the
    /// weeks list, one so old it has no `/projects` either) leaves it
    /// hidden, for the missions dashboard such a journal has.
    public var isShown: Bool {
        guard let viewModel else { return false }
        return viewModel.isSupported != false
    }

    public var place: TimelinePlace? { selection ?? viewModel?.place }

    /// The week on screen, else the last one picked, else the newest.
    public var week: String? {
        if case .week(let key) = place { return key }
        return pickedWeek ?? viewModel?.weeks.first?.week
    }

    /// Projects came on screen: the first time builds and starts the view
    /// model, then reads the counts; later visits re-read what is on screen
    /// and the counts, unless the journal has no timeline (its 404 would
    /// only come again). Returns the reads' task.
    @discardableResult
    public func projectsShown(build: () -> TimelineViewModel) -> Task<Void, Never>? {
        if let viewModel {
            guard viewModel.isSupported != false else { return nil }
            return Task { await refresh() }
        }
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

    /// Re-reads the place on screen and the counts (pull to refresh, a
    /// later visit). A refresh that finds the journal has no timeline
    /// asks for no counts: their 404 would only come again.
    public func refresh() async {
        guard let viewModel, viewModel.isSupported != false else { return }
        await viewModel.refresh()
        guard viewModel.isSupported != false else { return }
        await viewModel.loadCounts()
    }

    /// A project was changed from its own page (renamed, closed, merged,
    /// given a mission): every list that names it is read again, the one
    /// under the page now and the others on their next visit, so none
    /// goes on showing it as it was.
    public func projectChanged() async {
        await refresh()
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
