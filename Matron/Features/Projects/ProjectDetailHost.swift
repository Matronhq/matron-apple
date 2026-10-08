import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One project page on iOS: owns its `ProjectDetailViewModel` for the life
/// of the pushed screen. Session chips come from the shell's dashboard VM.
struct ProjectDetailHost: View {
    let projectID: String
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    let onOpenMission: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenSession: (String) -> Void
    let onOpenMilestone: (String, Int64) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: ProjectDetailViewModel?
    /// The route id `viewModel` was built for (a merge redirect changes the
    /// page's project, not this), so a reused host never keeps another
    /// project's view model.
    @State private var viewModelProjectID: String?
    @State private var confirmMerge: Project?
    /// Host for `matron://item/<n>` links in the status and description:
    /// the item opens the way this page's item rows open it.
    @State private var itemLinkRelay = TrackerItemLinkRelay()
    /// The roll-up's image thumbnails, by blob id: loaded once each through
    /// the session's authenticated media service, as item attachments are.
    @State private var images: [String: Image] = [:]

    var body: some View {
        content
            .navigationTitle(viewModel?.page?.project.title ?? "Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // Re-runs on every re-appear (a Back from a pushed mission),
            // not only when `projectID` changes — a fresh view model each
            // time flashed a spinner and scrolled to the top (review, fix
            // round 1). The existing one already has its page cached (and,
            // after a merge redirect, is already following the target), so
            // reappearing just restarts its observers/refresh; only a
            // genuinely new pushed screen (`viewModel == nil`) builds one.
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
            .task(id: imageBlobIDs) { await loadImages(imageBlobIDs) }
            .onAppear { missionsViewModel.projectPageDidAppear() }
            .onDisappear {
                viewModel?.stop()
                missionsViewModel.projectPageDidDisappear()
            }
            .confirmationDialog(mergeTitle, isPresented: mergeShown, titleVisibility: .visible) {
                Button("Merge", role: .destructive) { merge() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its missions move there and this project closes.")
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel?.error = nil }
            } message: {
                Text(viewModel?.error ?? "")
            }
            .tabBarFollowsTheSelectedTab(otherwise: .hidden)
            .trackerItemLinks(itemLinkRelay, resolve: { num in
                guard let deps else { return .ignore }
                return await deps.trackerItemLinkOutcome(num: num, session: session)
            }, open: onOpenItem)
    }

    /// Which of the four states `content` draws, in priority order: a
    /// loaded page beats "not found", which beats a failed load, which
    /// beats the spinner. Pure and static so the ordering has a test
    /// independent of SwiftUI.
    enum DisplayState: Equatable {
        case page
        case missing
        case loadFailed
        case loading
    }

    static func displayState(hasPage: Bool, isMissing: Bool, loadFailed: Bool) -> DisplayState {
        if hasPage { return .page }
        if isMissing { return .missing }
        if loadFailed { return .loadFailed }
        return .loading
    }

    @ViewBuilder private var content: some View {
        let page = viewModel.flatMap(pageModel)
        switch Self.displayState(hasPage: page != nil, isMissing: viewModel?.isMissing ?? false,
                                  loadFailed: viewModel?.loadFailed ?? false) {
        case .page:
            if let viewModel, let page {
                // A minute clock, as the Mac page's: the meta line, day groups
                // and file ages move on while the page sits open.
                TimelineView(.periodic(from: .now, by: 60)) { clock in
                    ProjectDetailView(page: page, now: clock.date, loadingMore: viewModel.loadingMore, images: images,
                                      onOpenMission: onOpenMission, onOpenItem: onOpenItem,
                                      onOpenSession: onOpenSession,
                                      onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
                                      onOpenFile: open,
                                      onLoadMore: { kind in Task { await viewModel.loadMore(kind: kind) } },
                                      onMoveMission: { id, target in Task { await viewModel.moveMission(id, to: target) } },
                                      onRefresh: { await viewModel.refresh() })
                }
            }
        case .missing:
            ContentUnavailableView("Project not found", systemImage: ProjectGlyph.symbol,
                                   description: Text("It may have been merged or removed."))
        case .loadFailed:
            if let viewModel {
                ContentUnavailableView {
                    Label("Couldn't load this project", systemImage: ProjectGlyph.symbol)
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try again") { Task { await viewModel.refresh() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The page with its session chips and room counts, which live on the
    /// shell's dashboard VM (it already owns every mission's sessions).
    private func pageModel(_ viewModel: ProjectDetailViewModel) -> ProjectPageModel? {
        guard var page = viewModel.page else { return nil }
        page.sessionsByMission = missionsViewModel.sessionsByMission
        page.roomCountsByMission = missionsViewModel.roomCountsByMission
        return page
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if let page = viewModel?.page {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu("Add a mission") {
                        ForEach(page.unfiledMissions) { mission in
                            Button(mission.label) { Task { await viewModel?.addMission(mission.id) } }
                        }
                    }
                    .disabled(page.unfiledMissions.isEmpty)
                    Menu("Merge into…") {
                        ForEach(page.mergeTargets) { target in Button(target.title) { confirmMerge = target } }
                    }
                    .disabled(page.mergeTargets.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Project actions")
            }
        }
    }

    private var mergeTitle: String {
        guard let target = confirmMerge, let page = viewModel?.page else { return "" }
        return "Merge “\(page.project.title)” into “\(target.title)”?"
    }

    private var mergeShown: Binding<Bool> {
        Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } })
    }

    private func merge() {
        guard let target = confirmMerge else { return }
        confirmMerge = nil
        Task { _ = await viewModel?.merge(into: target.id) }
    }

    /// A chat file opens its conversation at the event; an item file names
    /// its item by number, resolved the way a tapped `matron://item/<n>`
    /// link is (one refresh on a miss), else the page's alert says why.
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

    private func loadImages(_ blobIDs: [String]) async {
        guard let deps else { return }
        let media = deps.mediaService(for: session)
        // Only the page's current images stay decoded: the page is reused
        // across projects, and a full-size bitmap per visited file adds up.
        let wanted = Set(blobIDs)
        images = images.filter { wanted.contains($0.key) }
        for blobID in blobIDs where images[blobID] == nil {
            let url = session.homeserverURL.appendingPathComponent("media").appendingPathComponent(blobID)
            guard let image = await media.swiftUIImage(for: url) else { continue }
            // A switch to another page restarts this task; a load already in
            // flight must not put the old page's bitmap back.
            guard !Task.isCancelled, imageBlobIDs.contains(blobID) else { return }
            images[blobID] = image
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel?.error != nil }, set: { if !$0 { viewModel?.error = nil } })
    }
}
