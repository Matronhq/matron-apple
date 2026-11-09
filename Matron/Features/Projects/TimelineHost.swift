import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronViewModels

extension AppShellNavigation {
    /// Push a story or one of the timeline's lists onto the Projects
    /// stack; a double tap never stacks two.
    func pushTimelinePage(_ value: String) {
        guard missionsPath.last != value else { return }
        push(value, on: .missions)
    }
}

/// One week, or one of the three lists (`TimelinePlaceView`), with its
/// pictures and pull to refresh: the iPad's Projects detail root, the
/// iPhone's week page (with its "Worth a look" rows as `footer`) and the
/// lists pushed from it. Its alert is the host's (`timelineErrorAlert`):
/// the iPhone's root shares one with the rest of the Projects root.
struct TimelinePlacePage<Footer: View>: View {
    let host: TimelineHostState
    let viewModel: TimelineViewModel
    let place: TimelinePlace?
    let session: UserSession
    let onOpenProject: (String) -> Void
    let onOpenItem: (String) -> Void
    @ViewBuilder let footer: () -> Footer

    @Environment(\.appDependencies) private var deps
    @State private var images = TimelineImages()

    var body: some View {
        TimelinePlaceView(content: viewModel.content(for: place), now: Date(), images: images.images,
                          asked: viewModel.askedProjectIDs, onOpenProject: onOpenProject, onOpenItem: onOpenItem,
                          onAsk: { stalled in Task { await viewModel.ask(about: stalled) } },
                          onLoadMoreFinished: { Task { await viewModel.loadMoreFinished() } },
                          onRetry: { Task { await host.refresh() } }, footer: footer)
            .refreshable { await host.refresh() }
            .task(id: viewModel.imageBlobIDs(for: place)) {
                guard let deps else { return }
                await images.load(viewModel.imageBlobIDs(for: place), media: deps.mediaService(for: session),
                                  base: session.homeserverURL)
            }
    }
}

extension TimelinePlacePage where Footer == EmptyView {
    init(host: TimelineHostState, viewModel: TimelineViewModel, place: TimelinePlace?, session: UserSession,
         onOpenProject: @escaping (String) -> Void, onOpenItem: @escaping (String) -> Void) {
        self.init(host: host, viewModel: viewModel, place: place, session: session, onOpenProject: onOpenProject,
                  onOpenItem: onOpenItem) { EmptyView() }
    }
}

extension View {
    /// The timeline's alert for a page showing `place`: a failed read over
    /// a page on screen, or a failed Ask (`TimelineViewModel.showsError`).
    func timelineErrorAlert(_ viewModel: TimelineViewModel, place: TimelinePlace?) -> some View {
        alert("Projects", isPresented: Binding(get: { viewModel.showsError(on: place) },
                                               set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
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
