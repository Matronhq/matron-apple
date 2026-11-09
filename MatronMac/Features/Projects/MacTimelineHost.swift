import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Projects timeline's rules for the shell, pure so tests can pin them.
/// Behind `TimelineViewModel.flagKey`: with it off, or on a journal without
/// the timeline routes, Projects stays the full-width home it is today.
@MainActor enum MacTimelineNav {
    /// What the timeline adds to a Projects place.
    struct PlaceInput: Equatable {
        var place: TimelinePlace?
        var story: String?
    }

    static func flagOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: TimelineViewModel.flagKey)
    }

    /// The timeline replaces the home only once the journal has answered
    /// the weeks list: until then (nil) there is no empty column to flash.
    static func isShown(flagOn: Bool, isSupported: Bool?) -> Bool {
        flagOn && isSupported == true
    }

    /// The Projects place: a mission page, then a project page ("All
    /// details"), then the timeline's place and open story, else the home.
    static func projectsDetail(selectedMissionID: String?, selectedProjectID: String?,
                               timeline: PlaceInput?) -> MacPlace.Detail {
        if selectedMissionID == nil, let selectedProjectID { return .project(id: selectedProjectID) }
        if selectedMissionID == nil, let timeline { return .timeline(place: timeline.place, story: timeline.story) }
        return .mission(id: selectedMissionID)
    }

    /// Whether `next` is the Projects home becoming the timeline: the home
    /// shown before the journal answered, or the timeline before its first
    /// week loaded. That is the same place filling in, not a move, so
    /// Back from the first week goes where the user was before Projects.
    static func fillsInHome(from current: MacPlace?, to next: MacPlace) -> Bool {
        guard case .timeline(_, nil) = next.detail, let current else { return false }
        switch current.detail {
        case .mission(nil), .timeline(nil, nil): return true
        default: return false
        }
    }
}

/// The shell's timeline state, one per window: the view model (built on
/// the first visit to Projects, and only with the flag on), the list
/// column's selection and the project story open over it.
@MainActor @Observable
final class MacTimelineState {
    private(set) var viewModel: TimelineViewModel?
    /// The list column's pick, set at once so the shell's place follows the
    /// click in the same frame; the view model's own `place` (the newest
    /// week before any pick) follows when its read starts.
    private(set) var selection: TimelinePlace?
    /// A project opened from the timeline, shown as its story.
    var storyProjectID: String?

    var isShown: Bool { MacTimelineNav.isShown(flagOn: viewModel != nil, isSupported: viewModel?.isSupported) }

    var place: TimelinePlace? { selection ?? viewModel?.place }

    /// What the shell's place carries, or nil when the timeline is not shown.
    var placeInput: MacTimelineNav.PlaceInput? {
        isShown ? .init(place: place, story: storyProjectID) : nil
    }

    /// Projects came on screen: the first time (flag on; nil reads it)
    /// builds and starts the view model, then reads the sidebar's counts;
    /// later visits re-read what is on screen, unless the journal has no
    /// timeline (its 404 would only come again). Returns the reads' task.
    @discardableResult
    func projectsShown(flagOn: Bool? = nil, build: () -> TimelineViewModel) -> Task<Void, Never>? {
        if let viewModel {
            guard viewModel.isSupported != false else { return nil }
            return Task {
                await viewModel.refresh()
                await viewModel.loadCounts()
            }
        }
        guard flagOn ?? MacTimelineNav.flagOn() else { return nil }
        let viewModel = build()
        self.viewModel = viewModel
        return Task {
            await viewModel.start()
            // A place picked before the view model existed (Back onto a
            // timeline place after an account switch) wins over the
            // newest week `start()` opened on.
            if let selection = self.selection, viewModel.place != selection { await viewModel.select(selection) }
            await viewModel.loadCounts()
        }
    }

    func select(_ place: TimelinePlace?) {
        selection = place
        guard let place, let viewModel, viewModel.place != place else { return }
        Task { await viewModel.select(place) }
    }

    /// A new session: nothing of the old one's timeline carries over.
    func reset() {
        viewModel = nil
        selection = nil
        storyProjectID = nil
    }
}

/// The list column under Projects: the weeks and "Worth a look".
struct MacTimelineColumn: View {
    let state: MacTimelineState
    let onSelect: (TimelinePlace) -> Void

    var body: some View {
        if let viewModel = state.viewModel {
            TimelineSidebarView(weeks: viewModel.weeks, quietCount: viewModel.quiet?.total,
                                longCount: viewModel.long?.total,
                                // The journal sends no finished total; a
                                // count of the rows loaded so far would read as one.
                                finishedCount: nil,
                                selection: Binding(get: { state.place }, set: { if let place = $0 { onSelect(place) } }),
                                onLoadEarlier: viewModel.hasEarlierWeeks
                                    ? { Task { await viewModel.loadEarlierWeeks() } } : nil)
        }
    }
}

/// The Projects detail with the timeline shown: a project (its story, or
/// "All details", today's project page) when one is open, else the week
/// or list the column has selected.
struct MacTimelineDetail: View {
    let state: MacTimelineState
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    @Binding var slot: MacProjectPageSlot<ProjectDetailViewModel>
    /// "All details" is open for this project.
    let selectedProjectID: String?
    let actions: MacProjectPageActions
    let onOpenStory: (String) -> Void
    let onAllDetails: (String) -> Void
    let onRedirect: (String) -> Void
    let onRedirectStory: (String) -> Void

    var body: some View {
        if let projectID = selectedProjectID ?? state.storyProjectID {
            MacTimelineProjectHost(projectID: projectID, showsDetails: selectedProjectID != nil, session: session,
                                   missionsViewModel: missionsViewModel, slot: $slot, actions: actions,
                                   onAllDetails: onAllDetails, onRedirect: onRedirect, onRedirectStory: onRedirectStory)
        } else if let viewModel = state.viewModel {
            MacTimelinePlaceView(viewModel: viewModel, place: state.place, session: session,
                                 onOpenProject: onOpenStory, onOpenItem: actions.onOpenItem)
        }
    }
}

/// One week, or one of the three lists.
struct MacTimelinePlaceView: View {
    let viewModel: TimelineViewModel
    let place: TimelinePlace?
    let session: UserSession
    let onOpenProject: (String) -> Void
    let onOpenItem: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var images = MacTimelineImages()

    var body: some View {
        content
            .task(id: imageBlobIDs) {
                guard let deps else { return }
                await images.load(imageBlobIDs, media: deps.mediaService(for: session), base: session.homeserverURL)
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        let now = Date()
        switch place {
        case .week:
            if let week = Self.shownWeek(viewModel.week, for: place) {
                TimelineWeekView(week: week, sentence: viewModel.weeks.first { $0.week == week.week }?.sentence,
                                 now: now, images: images.images,
                                 onOpenProject: onOpenProject, onOpenItem: onOpenItem)
            } else {
                unloaded
            }
        case .quiet:
            if let list = viewModel.quiet {
                StalledListView(title: TimelineFormat.wentQuiet, lede: TimelineFormat.quietLede, list: list, now: now,
                                onOpenProject: onOpenProject, onAsk: ask, asked: viewModel.askedProjectIDs)
            } else {
                unloaded
            }
        case .long:
            if let list = viewModel.long {
                StalledListView(title: TimelineFormat.openLong, lede: TimelineFormat.longLede, list: list, now: now,
                                onOpenProject: onOpenProject, onAsk: ask, asked: viewModel.askedProjectIDs)
            } else {
                unloaded
            }
        case .finished:
            if viewModel.finished.isEmpty, viewModel.error != nil {
                unloaded
            } else {
                FinishedListView(rows: viewModel.finished, now: now, onOpenProject: onOpenProject,
                                 onLoadMore: viewModel.hasMoreFinished ? { Task { await viewModel.loadMoreFinished() } } : nil)
            }
        case nil:
            if viewModel.weeks.isEmpty, viewModel.error == nil {
                ContentUnavailableView("Nothing has moved yet", systemImage: ProjectGlyph.symbol)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unloaded
            }
        }
    }

    /// The place's read is in flight, or failed with nothing to show.
    @ViewBuilder private var unloaded: some View {
        if viewModel.error != nil {
            ContentUnavailableView {
                Label("Couldn't load this", systemImage: ProjectGlyph.symbol)
            } description: {
                Text("The journal didn't answer. Check the connection and try again.")
            } actions: {
                Button("Try again") { Task { await viewModel.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hasContent: Bool {
        switch place {
        case .week: return Self.shownWeek(viewModel.week, for: place) != nil
        case .quiet: return viewModel.quiet != nil
        case .long: return viewModel.long != nil
        case .finished: return !viewModel.finished.isEmpty
        case nil: return false
        }
    }

    /// The loaded week when it is the one selected: a click on another
    /// week shows progress (or the retry) until that week arrives, never
    /// the last week's cards under the new highlight.
    static func shownWeek(_ week: TimelineWeek?, for place: TimelinePlace?) -> TimelineWeek? {
        guard case .week(let key) = place, let week, week.week == key else { return nil }
        return week
    }

    private func ask(_ stalled: StalledProject) {
        Task { await viewModel.ask(about: stalled) }
    }

    /// The week's pictures (videos draw their own panel).
    private var imageBlobIDs: [String] {
        return Self.shownWeek(viewModel.week, for: place)?.stories.compactMap { $0.media }.filter { !$0.isVideo }.map(\.blobID) ?? []
    }

    /// A failed read over a page already on screen, or a failed Ask.
    private var errorShown: Binding<Bool> {
        Binding(get: { hasContent && viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })
    }
}

/// A project opened from the timeline: its story, or "All details" (today's
/// project page). One host for both, so the shell's project view model is
/// started once and kept across the switch between them.
struct MacTimelineProjectHost: View {
    let projectID: String
    let showsDetails: Bool
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    @Binding var slot: MacProjectPageSlot<ProjectDetailViewModel>
    let actions: MacProjectPageActions
    let onAllDetails: (String) -> Void
    let onRedirect: (String) -> Void
    let onRedirectStory: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var images = MacTimelineImages()
    /// This host's claim on `slot`: only the page that last showed the view
    /// model stops it on leaving.
    @State private var pageToken = UUID()

    var body: some View {
        Group {
            if showsDetails {
                MacProjectPage(projectID: projectID, session: session, missionsViewModel: missionsViewModel,
                               slot: $slot, actions: actions, onRedirect: onRedirect, ownsSlot: false)
            } else {
                story
            }
        }
        .task(id: projectID) {
            guard let deps else { return }
            slot.show(projectID: projectID, owner: owner, page: pageToken) {
                deps.makeProjectDetailViewModel(for: session, projectID: projectID)
            }
        }
        .onDisappear { slot.pageDidDisappear(owner: owner, page: pageToken) }
    }

    private var owner: ObjectIdentifier { ObjectIdentifier(missionsViewModel) }

    private var viewModel: ProjectDetailViewModel? { slot.current(projectID: projectID, owner: owner) }

    @ViewBuilder private var story: some View {
        let vm = viewModel
        Group {
            switch MacProjectPage.contentState(hasPage: vm?.page != nil, isMissing: vm?.isMissing == true,
                                               loadFailed: vm?.loadFailed == true) {
            case .page:
                if let page = vm?.page {
                    ProjectStoryView(page: page, now: Date(), images: images.images, onOpenItem: actions.onOpenItem,
                                     onOpenFile: { [deps, session, actions] file in
                                         MacProjectPage.openFile(file, deps: deps, session: session, actions: actions, vm: vm)
                                     },
                                     onAllDetails: { onAllDetails(projectID) }) { EmptyView() }
                        .id(page.project.id)
                }
            case .missing:
                ContentUnavailableView("Project not found", systemImage: ProjectGlyph.symbol,
                                       description: Text("It may have been merged or removed."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loadFailed:
                ContentUnavailableView {
                    Label("Couldn't load this project", systemImage: ProjectGlyph.symbol)
                } description: {
                    Text("The journal didn't answer. Check the connection and try again.")
                } actions: {
                    Button("Try again") { Task { await vm?.refresh() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Counted like "All details" (which counts itself): the dashboard
        // keeps the project list fresh while a project page is open.
        .onAppear { missionsViewModel.projectPageDidAppear() }
        .onDisappear { missionsViewModel.projectPageDidDisappear() }
        // A merge moved the project: the story follows it, as the page does.
        .onChange(of: slot.model?.projectID) { _, id in
            if let target = slot.redirect(to: id, pageProjectID: projectID) { onRedirectStory(target) }
        }
        .task(id: storyImageBlobIDs) {
            guard let deps else { return }
            await images.load(storyImageBlobIDs, media: deps.mediaService(for: session), base: session.homeserverURL)
        }
        .alert("Projects", isPresented: errorShown) {
            Button("OK") { viewModel?.error = nil }
        } message: {
            Text(viewModel?.error ?? "")
        }
    }

    private var storyImageBlobIDs: [String] {
        viewModel?.page?.files.rows.filter(\.isImage).map(\.blobID) ?? []
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel?.error != nil }, set: { if !$0 { viewModel?.error = nil } })
    }
}

/// Pictures by blob id, loaded once each through the session's
/// authenticated media service, as the project page loads its own. Only
/// the current page's stay decoded.
@MainActor @Observable
final class MacTimelineImages {
    private(set) var images: [String: Image] = [:]

    func load(_ blobIDs: [String], media: any MediaService, base: URL) async {
        let wanted = Set(blobIDs)
        images = images.filter { wanted.contains($0.key) }
        for blobID in blobIDs where images[blobID] == nil {
            let url = base.appendingPathComponent("media").appendingPathComponent(blobID)
            guard let image = await media.swiftUIImage(for: url) else { continue }
            // A newer page restarted the load: keep the old page's bitmap out.
            guard !Task.isCancelled else { return }
            images[blobID] = image
        }
    }
}
