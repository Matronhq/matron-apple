import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronViewModels

extension AppShellNavigation {
    /// Push one of the timeline's lists, or a section of a project's page,
    /// onto the Projects stack; a double tap never stacks two.
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
                          sizes: images.sizes,
                          asked: viewModel.askedProjectIDs, onOpenProject: onOpenProject, onOpenItem: onOpenItem,
                          onAsk: { stalled in Task { await viewModel.ask(about: stalled) } },
                          onLoadMoreFinished: { Task { await viewModel.loadMoreFinished() } },
                          onLoadMoreProjects: { Task { await viewModel.loadMoreProjects() } },
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

/// A project's page while the timeline is shown (`ProjectSummaryView`), or
/// one of the page's three sections, pushed one level down. Where the
/// project stands and its history come from a `ProjectSummaryViewModel`;
/// its missions, its files and the "···" actions from a
/// `ProjectDetailViewModel`. Both live as long as the pushed screen. On a
/// journal without the project-page route it shows the project page that
/// journal has (`ProjectDetailHost`).
struct TimelineStoryHost: View {
    let projectID: String
    /// The section this screen shows; nil is the page itself.
    var section: ProjectSection? = nil
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    let onOpenSection: (ProjectSection) -> Void
    let onOpenMission: (String) -> Void
    let onOpenItem: (String) -> Void
    let onOpenSession: (String) -> Void
    let onOpenMilestone: (String, Int64) -> Void

    @Environment(\.appDependencies) private var deps
    /// The shell's timeline: its lists name the project too, so a "···"
    /// write reads them again.
    @Environment(TimelineHostState.self) private var timeline: TimelineHostState?
    @State private var summary: ProjectSummaryViewModel?
    @State private var detail: ProjectDetailViewModel?
    /// The route id the view models were built for (a merge changes the
    /// page's project, not this), so a reused host never keeps another
    /// project's.
    @State private var loadedProjectID: String?
    /// The first read of the page failed, so there is nothing to show.
    @State private var loadFailed = false
    @State private var images = TimelineImages()
    @State private var confirmMerge: Project?
    @State private var confirmClose = false
    /// Something asked of this page could not be done: "Ask the
    /// Coordinator" not sent, a file that would not open.
    @State private var actionError: String?
    /// "Ask the Coordinator" was sent from this page: its entry says so.
    @State private var asked = false
    /// One `.sheet` for the three (`ProjectsTabRoot.sheet` says why).
    @State private var sheet: Sheet?
    /// Videos being fetched for the player: a second tap starts no second fetch.
    @State private var fetchingBlobIDs: Set<String> = []

    private enum Sheet: Identifiable {
        case rename(id: UUID = UUID())
        case picture(id: UUID = UUID(), ImageGallery)
        case video(id: UUID = UUID(), URL, filename: String)

        var id: UUID {
            switch self {
            case .rename(let id), .picture(let id, _), .video(let id, _, _): return id
            }
        }
    }

    /// What the screen draws.
    enum Content: Equatable {
        case summary
        case section(ProjectSection)
        /// The journal has no project-page route: the project page it had.
        case todaysPage
        case missing, loadFailed, loading
    }

    /// An older journal first (it has nothing to show a section of), then
    /// the page or its section, then why there is none.
    static func content(hasPage: Bool, isMissing: Bool, isUnsupported: Bool, loadFailed: Bool,
                        section: ProjectSection?) -> Content {
        if isUnsupported { return .todaysPage }
        if hasPage { return section.map { .section($0) } ?? .summary }
        if isMissing { return .missing }
        return loadFailed ? .loadFailed : .loading
    }

    /// How a file of the Files section opens: a picture in the image
    /// viewer, a video in the player, anything else where it was posted.
    enum FileOpening: Equatable { case picture, video, source }

    static func fileOpening(_ file: ProjectFile) -> FileOpening {
        if file.isImage { return .picture }
        return file.contentType?.lowercased().hasPrefix("video/") == true ? .video : .source
    }

    /// The pictures the viewer steps through, in the grid's order: a
    /// picture attached twice is one picture.
    static func pictureBlobIDs(_ files: [ProjectFile]) -> [String] {
        var seen = Set<String>()
        return files.filter(\.isImage).map(\.blobID).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Group {
            if content == .todaysPage {
                ProjectDetailHost(projectID: projectID, session: session, missionsViewModel: missionsViewModel,
                                  onOpenMission: onOpenMission, onOpenItem: onOpenItem, onOpenSession: onOpenSession,
                                  onOpenMilestone: onOpenMilestone)
            } else {
                page
            }
        }
        // Runs again on every re-appear (Back from a section or a mission):
        // the view models are kept, and the page alone is read again.
        .task(id: projectID) { await load() }
        .onDisappear { detail?.stop() }
    }

    private var content: Content {
        Self.content(hasPage: summary?.page != nil, isMissing: summary?.isMissing == true,
                     isUnsupported: summary?.isUnsupported == true, loadFailed: loadFailed, section: section)
    }

    /// Reads the page: on arrival, on coming back, and for "Try again".
    /// The missions, files and actions wait for the page's first answer:
    /// on a journal without the route they are the other page's to read.
    private func load() async {
        guard let deps else { return }
        if loadedProjectID != projectID {
            detail?.stop()
            detail = nil
            summary = nil
            asked = false
            loadedProjectID = projectID
        }
        detail?.start()
        loadFailed = false
        if let summary {
            // The history stays as far as it was paged: pull to refresh
            // reads it again.
            await summary.refreshPage()
        } else {
            let made = deps.makeProjectSummaryViewModel(for: session, projectID: projectID)
            summary = made
            await made.start()
        }
        guard !Task.isCancelled, let summary else { return }
        loadFailed = summary.page == nil && !summary.isMissing && !summary.isUnsupported
        // The page says it could not load; an alert over it would say so twice.
        if loadFailed { summary.error = nil }
        guard !summary.isUnsupported, detail == nil else { return }
        let made = deps.makeProjectDetailViewModel(for: session, projectID: projectID)
        detail = made
        made.start()
    }

    private var page: some View {
        pageContent
            // The page's own title row carries the name, so the bar shows
            // none; the real title stays set so Back on what this opens
            // names where it leads.
            .navigationTitle(section.map(TimelineFormat.sectionTitle) ?? (title.isEmpty ? "Project" : title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if section == nil {
                    ToolbarItem(placement: .principal) { Text(verbatim: " ").accessibilityHidden(true) }
                }
            }
            // Counted like the project page without the timeline (which
            // counts itself): the dashboard keeps the project list fresh
            // while a project is open.
            .onAppear { missionsViewModel.projectPageDidAppear() }
            .onDisappear { missionsViewModel.projectPageDidDisappear() }
            .task(id: imageBlobIDs) {
                guard let deps else { return }
                await images.load(imageBlobIDs, media: deps.mediaService(for: session), base: session.homeserverURL)
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { clearError() }
            } message: {
                Text(error ?? "")
            }
            .confirmationDialog(mergeTitle, isPresented: mergeShown, titleVisibility: .visible) {
                Button("Merge", role: .destructive) {
                    if let target = confirmMerge { act { _ = await $0.merge(into: target.id) } }
                    confirmMerge = nil
                }
                Button("Cancel", role: .cancel) { confirmMerge = nil }
            } message: {
                Text("Its missions move there and this project closes.")
            }
            .confirmationDialog(ProjectActionsFormat.closeConfirmation(title: title), isPresented: $confirmClose,
                                titleVisibility: .visible) {
                Button("Close project", role: .destructive) { act { _ = await $0.close() } }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $sheet) { shown in
                switch shown {
                case .rename:
                    ProjectRenameSheet(title: title, onSave: { newTitle in
                        sheet = nil
                        act { _ = await $0.rename(to: newTitle) }
                    }, onCancel: { sheet = nil })
                    .presentationDetents([.medium])
                case .picture(_, let gallery):
                    AttachmentFullscreenViewer(gallery: gallery, onDismiss: { sheet = nil })
                case .video(_, let url, let filename):
                    FilePreviewSheet(url: url, filename: filename, onDone: { sheet = nil })
                }
            }
            .tabBarFollowsTheSelectedTab(otherwise: .hidden)
    }

    @ViewBuilder private var pageContent: some View {
        switch content {
        case .summary:
            if let page = summary?.page { summaryView(page) }
        case .section(let section):
            sectionView(section)
        case .missing:
            ContentUnavailableView("Project not found", systemImage: ProjectGlyph.symbol,
                                   description: Text("It may have been merged or removed."))
        case .loadFailed:
            ContentUnavailableView {
                Label("Couldn't load this project", systemImage: ProjectGlyph.symbol)
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading, .todaysPage:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var title: String { summary?.page?.project.title ?? "" }

    // MARK: The page and its sections

    private func summaryView(_ page: TimelineProjectPage) -> some View {
        ProjectSummaryView(page: page, image: page.media.flatMap { images.images[$0.blobID] },
                           pixelSize: page.media.flatMap { images.sizes[$0.blobID] },
                           onOpenItem: onOpenItem, onOpenSection: onOpenSection) {
            ProjectActionsMenu(isOpen: page.isOpen, isLoaded: detail?.page != nil, asked: asked,
                               unfiled: detail?.page?.unfiledMissions ?? [],
                               mergeTargets: detail?.page?.mergeTargets ?? [],
                               onAddMission: { id in act { await $0.addMission(id) } },
                               onAsk: ask,
                               onRename: { sheet = .rename() },
                               onMerge: { id in confirmMerge = detail?.page?.mergeTargets.first { $0.id == id } },
                               onClose: { confirmClose = true })
        }
        .refreshable { await refresh() }
    }

    @ViewBuilder private func sectionView(_ section: ProjectSection) -> some View {
        switch section {
        case .history:
            ProjectHistoryView(weeks: summary?.history ?? [], now: Date(), images: images.images, sizes: images.sizes,
                               hasMore: summary?.hasMoreHistory == true,
                               onOpenMilestone: { onOpenMilestone($0.milestone.convoID, $0.milestone.seq) },
                               onLoadMore: { Task { await summary?.loadMoreHistory() } })
                // Back from a milestone runs this again: nothing is read twice.
                .task { await summary?.loadHistoryIfNeeded() }
                .refreshable { await refresh() }
        case .missions:
            if let page = detail?.page {
                ProjectMissionsListView(open: page.missions, closed: page.closedMissions, now: Date(),
                                        onOpenMission: onOpenMission)
                    .refreshable { await refresh() }
            } else {
                detailPlaceholder
            }
        case .files:
            if let page = detail?.page {
                ProjectFilesGridView(files: page.files.rows, images: images.images, now: Date(),
                                     hasMore: page.files.nextBefore != nil,
                                     onOpenFile: { open($0, among: page.files.rows) },
                                     onLoadMore: { Task { await detail?.loadMore(kind: .files) } })
                    .refreshable { await refresh() }
            } else {
                detailPlaceholder
            }
        }
    }

    /// The missions and files come from the project's own view model:
    /// still loading, or it could not load.
    @ViewBuilder private var detailPlaceholder: some View {
        if detail?.loadFailed == true {
            ContentUnavailableView {
                Label("Couldn't load this project", systemImage: ProjectGlyph.symbol)
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await detail?.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Pull to refresh: both reads again.
    private func refresh() async {
        await summary?.refresh()
        await detail?.refresh()
    }

    // MARK: Pictures and files

    /// The pictures what is on screen draws: the page's own, the history
    /// weeks', or the files'. A video draws its play mark instead.
    private var imageBlobIDs: [String] {
        switch content {
        case .summary: return [summary?.page?.media].compactMap { $0 }.filter { !$0.isVideo }.map(\.blobID)
        case .section(.history): return (summary?.history ?? []).compactMap(\.media).filter { !$0.isVideo }.map(\.blobID)
        case .section(.files): return Self.pictureBlobIDs(detail?.page?.files.rows ?? [])
        default: return []
        }
    }

    private func open(_ file: ProjectFile, among files: [ProjectFile]) {
        switch Self.fileOpening(file) {
        case .picture:
            let blobIDs = Self.pictureBlobIDs(files)
            let names = blobIDs.map { blobID in files.first { $0.blobID == blobID }?.name }
            // The grid's own bitmap opens the viewer at once, when it has loaded.
            let initial = images.images[file.blobID].map { ViewerImage(image: $0, pixelSize: images.sizes[file.blobID]) }
            sheet = .picture(ImageGalleries.urls(blobIDs.map(mediaURL), names: names, tapped: mediaURL(file.blobID),
                                                 initial: initial, deps: deps, session: session))
        case .video:
            play(file)
        case .source:
            openSource(file)
        }
    }

    private func mediaURL(_ blobID: String) -> URL {
        session.homeserverURL.appendingPathComponent("media").appendingPathComponent(blobID)
    }

    /// The video in the player, from a temp file: the copy already there,
    /// or fetched.
    private func play(_ file: ProjectFile) {
        guard let deps else { return }
        let blobID = file.blobID
        let name = file.name.flatMap { $0.isEmpty ? nil : $0 } ?? blobID
        if let cached = AttachmentTempFiles.existingFile(name: name, blobRef: blobID) {
            sheet = .video(cached, filename: name)
            return
        }
        guard !fetchingBlobIDs.contains(blobID) else { return }
        fetchingBlobIDs.insert(blobID)
        let media = deps.mediaService(for: session)
        Task {
            defer { fetchingBlobIDs.remove(blobID) }
            guard let data = await media.fetchBytes(mxcURL: mediaURL(blobID)) else {
                actionError = "Couldn't load that video. Check your connection and try again."
                return
            }
            do {
                sheet = .video(try AttachmentTempFiles.write(data, name: name, blobRef: blobID), filename: name)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// A chat file opens its conversation at the event; an item file names
    /// its item by number, resolved the way a tapped `matron://item/<n>`
    /// link is, else the alert says why.
    private func openSource(_ file: ProjectFile) {
        switch file.source {
        case .chat(let convoID, let seq):
            onOpenMilestone(convoID, seq)
        case .item(let num):
            guard let deps else { return }
            Task {
                switch await deps.trackerItemLinkOutcome(num: num, session: session) {
                case .open(let itemID): onOpenItem(itemID)
                case .explain(let message): actionError = message
                case .ignore: break
                }
            }
        }
    }

    // MARK: Actions

    /// One of the "···" writes, then the page again, and the timeline's
    /// lists: a rename, a close or a mission added shows in what the page
    /// says and in every list that names the project.
    private func act(_ work: @escaping @MainActor (ProjectDetailViewModel) async -> Void) {
        guard let detail else { return }
        Task {
            await work(detail)
            await summary?.refresh()
            await timeline?.projectChanged()
        }
    }

    private func ask() {
        guard let deps, !title.isEmpty, !asked else { return }
        let send = deps.coordinatorAsk(for: session, coordinatorConvoID: { [weak missionsViewModel] in
            missionsViewModel?.coordinatorConvoID
        })
        let message = ProjectActionsFormat.askMessage(title: title)
        Task {
            do {
                try await send(message)
                asked = true
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var error: String? { actionError ?? detail?.error ?? summary?.error }

    private func clearError() {
        actionError = nil
        detail?.error = nil
        summary?.error = nil
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { clearError() } })
    }

    private var mergeTitle: String {
        guard let target = confirmMerge else { return "" }
        return "Merge “\(title)” into “\(target.title)”?"
    }

    private var mergeShown: Binding<Bool> {
        Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } })
    }
}

/// "Rename…": the project's name in a field, as it is now. Save is off
/// while the field is empty.
struct ProjectRenameSheet: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @FocusState private var focused: Bool

    init(title: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: title)
    }

    /// Whether `title` can be saved: something other than space.
    static func canSave(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("projects.rename.field")
            }
            .navigationTitle("Rename project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!Self.canSave(title))
                        .accessibilityIdentifier("projects.rename.save")
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() {
        guard Self.canSave(title) else { return }
        onSave(title)
    }
}
