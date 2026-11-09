import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The shell's Projects timeline state, behind `TimelineViewModel.flagKey`:
/// the view model (built on the first visit to Projects, and only with the
/// flag on) and the place picked in the iPad's sidebar or the iPhone's
/// week menu. With the flag off, or on a journal without the timeline
/// routes, Projects stays the home it is today.
@MainActor @Observable
final class TimelineShellState {
    private(set) var viewModel: TimelineViewModel?
    /// The pick, set at once so the page follows the tap in the same
    /// frame; the view model's own `place` (the newest week before any
    /// pick) follows when its read starts.
    private(set) var selection: TimelinePlace?
    /// The last week picked: the iPhone's week page, under a pushed list.
    private var pickedWeek: String?

    static func flagOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: TimelineViewModel.flagKey)
    }

    /// The timeline replaces the home only once the journal has answered
    /// the weeks list: until then (nil) the home stays.
    var isShown: Bool { viewModel?.isSupported == true }

    var place: TimelinePlace? { selection ?? viewModel?.place }

    /// The week the iPhone's root shows: the one on screen, else the last
    /// one picked, else the newest.
    var week: String? {
        if case .week(let key) = place { return key }
        return pickedWeek ?? viewModel?.weeks.first?.week
    }

    /// Projects came on screen: the first time (flag on; nil reads it)
    /// builds and starts the view model, then reads the counts; later
    /// visits re-read what is on screen, unless the journal has no
    /// timeline (its 404 would only come again). Returns the reads' task.
    @discardableResult
    func projectsShown(flagOn: Bool? = nil, build: () -> TimelineViewModel) -> Task<Void, Never>? {
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
            if let selection = self.selection, viewModel.place != selection { await viewModel.select(selection) }
            await viewModel.loadCounts()
        }
    }

    /// Re-reads the place on screen and the counts (pull to refresh).
    func refresh() async {
        guard let viewModel, viewModel.isSupported != false else { return }
        await viewModel.refresh()
        await viewModel.loadCounts()
    }

    func select(_ place: TimelinePlace) {
        selection = place
        if case .week(let key) = place { pickedWeek = key }
        guard let viewModel, viewModel.place != place else { return }
        Task { await viewModel.select(place) }
    }
}

extension AppShellNavigation {
    /// Push a story or one of the timeline's lists onto the Projects
    /// stack; a double tap never stacks two.
    func pushTimelinePage(_ value: String) {
        guard missionsPath.last != value else { return }
        push(value, on: .missions)
    }
}

/// One week, or one of the three lists: the iPad's Projects detail root,
/// the iPhone's week page (with its "Worth a look" rows as `footer`) and
/// the lists pushed from it.
struct TimelinePlacePage<Footer: View>: View {
    let viewModel: TimelineViewModel
    let place: TimelinePlace?
    let session: UserSession
    let onOpenProject: (String) -> Void
    let onOpenItem: (String) -> Void
    let onRefresh: () async -> Void
    @ViewBuilder let footer: () -> Footer

    @Environment(\.appDependencies) private var deps
    @State private var images = TimelineImages()

    var body: some View {
        content
            .refreshable { await onRefresh() }
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
                                 onOpenProject: onOpenProject, onOpenItem: onOpenItem, footer: footer)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ContentUnavailableView("Nothing has moved yet", systemImage: ProjectGlyph.symbol)
                        footer()
                    }
                    .padding()
                }
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
                Button("Try again") { Task { await onRefresh() } }
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

    /// The loaded week when it is the one chosen: a pick of another week
    /// shows progress (or the retry) until that week arrives, never the
    /// last week's cards under the new title.
    static func shownWeek(_ week: TimelineWeek?, for place: TimelinePlace?) -> TimelineWeek? {
        guard case .week(let key) = place, let week, week.week == key else { return nil }
        return week
    }

    private func ask(_ stalled: StalledProject) {
        Task { await viewModel.ask(about: stalled) }
    }

    /// The week's pictures (videos draw their own panel).
    private var imageBlobIDs: [String] {
        Self.shownWeek(viewModel.week, for: place)?.stories.compactMap { $0.media }.filter { !$0.isVideo }.map(\.blobID) ?? []
    }

    /// A failed read over a page already on screen, or a failed Ask. Only
    /// the page the view model is reading says so: on the iPhone the week
    /// page stays mounted under a pushed list.
    private var errorShown: Binding<Bool> {
        Binding(get: { hasContent && viewModel.place == place && viewModel.error != nil },
                set: { if !$0 { viewModel.error = nil } })
    }
}

extension TimelinePlacePage where Footer == EmptyView {
    init(viewModel: TimelineViewModel, place: TimelinePlace?, session: UserSession,
         onOpenProject: @escaping (String) -> Void, onOpenItem: @escaping (String) -> Void,
         onRefresh: @escaping () async -> Void) {
        self.init(viewModel: viewModel, place: place, session: session, onOpenProject: onOpenProject,
                  onOpenItem: onOpenItem, onRefresh: onRefresh) { EmptyView() }
    }
}

/// A project opened from the timeline, told as its story. Owns its
/// `ProjectDetailViewModel` for the life of the pushed screen, as
/// `ProjectDetailHost` does; "All details" pushes that page on top.
struct TimelineStoryHost: View {
    let projectID: String
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    let onAllDetails: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenMilestone: (String, Int64) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: ProjectDetailViewModel?
    /// The route id `viewModel` was built for, so a reused host never
    /// keeps another project's view model.
    @State private var viewModelProjectID: String?
    @State private var images = TimelineImages()

    var body: some View {
        content
            // The story's own title row carries the name; the real title
            // stays set so Back on "All details" names the project.
            .navigationTitle(viewModel?.page?.project.title ?? "Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { Text(verbatim: " ").accessibilityHidden(true) } }
            .task(id: projectID) {
                if let viewModel, viewModelProjectID == projectID {
                    viewModel.start()
                    return
                }
                guard let deps else { return }
                viewModel?.stop()
                let vm = deps.makeProjectDetailViewModel(for: session, projectID: projectID)
                viewModel = vm
                viewModelProjectID = projectID
                vm.start()
            }
            .task(id: imageBlobIDs) {
                guard let deps else { return }
                await images.load(imageBlobIDs, media: deps.mediaService(for: session), base: session.homeserverURL)
            }
            // Counted like a project page: the dashboard keeps the project
            // list fresh while one is open.
            .onAppear { missionsViewModel.projectPageDidAppear() }
            .onDisappear {
                viewModel?.stop()
                missionsViewModel.projectPageDidDisappear()
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel?.error = nil }
            } message: {
                Text(viewModel?.error ?? "")
            }
            .tabBarFollowsTheSelectedTab(otherwise: .hidden)
    }

    @ViewBuilder private var content: some View {
        let vm = viewModel
        switch ProjectDetailHost.displayState(hasPage: vm?.page != nil, isMissing: vm?.isMissing ?? false,
                                              loadFailed: vm?.loadFailed ?? false) {
        case .page:
            if let page = vm?.page {
                // A merge moves the page to its target: "All details" opens that.
                ProjectStoryView(page: page, now: Date(), images: images.images, onOpenItem: onOpenItem,
                                 onOpenFile: open, onAllDetails: { onAllDetails(page.project.id) })
                    .id(page.project.id)
            }
        case .missing:
            ContentUnavailableView("Project not found", systemImage: ProjectGlyph.symbol,
                                   description: Text("It may have been merged or removed."))
        case .loadFailed:
            ContentUnavailableView {
                Label("Couldn't load this project", systemImage: ProjectGlyph.symbol)
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await vm?.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A chat file opens its conversation at the event; an item file names
    /// its item by number, resolved the way a tapped `matron://item/<n>`
    /// link is, else the alert says why.
    private func open(_ file: ProjectFile) {
        switch file.source {
        case .chat(let convoID, let seq):
            onOpenMilestone(convoID, seq)
        case .item(let num):
            guard let deps else { return }
            Task {
                switch await deps.trackerItemLinkOutcome(num: num, session: session) {
                case .open(let itemID): onOpenItem(itemID)
                case .explain(let message): viewModel?.error = message
                case .ignore: break
                }
            }
        }
    }

    private var imageBlobIDs: [String] {
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
final class TimelineImages {
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
