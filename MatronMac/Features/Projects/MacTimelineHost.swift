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
        /// The section of the open project's page; nil is the page itself.
        var section: ProjectSection? = nil
    }

    /// The Projects place: a mission page first. While the timeline is
    /// shown, the timeline's place with the project open over it, which is
    /// the one the shell selected (a chip, a link, search) or else the one
    /// opened from the timeline, so today's project page is never a place.
    /// With the timeline hidden, today's project page or the home.
    static func projectsDetail(selectedMissionID: String?, selectedProjectID: String?,
                               timeline: PlaceInput?) -> MacPlace.Detail {
        if let selectedMissionID { return .mission(id: selectedMissionID) }
        if let timeline {
            let story = selectedProjectID ?? timeline.story
            return .timeline(place: timeline.place, story: story, section: story == nil ? nil : timeline.section)
        }
        if let selectedProjectID { return .project(id: selectedProjectID) }
        return .mission(id: nil)
    }

    /// Whether ⌘R and coming back to the app re-read the timeline: only
    /// while Projects shows it (not a mission page over it, not the home).
    static func refreshesTimeline(nav: MacNav, timelineShown: Bool, selectedMissionID: String?) -> Bool {
        nav == .missions && timelineShown && selectedMissionID == nil
    }

    /// Whether `next` is the place `current` already was, filling in: the
    /// home shown before the journal answered, or the timeline before its
    /// first week loaded, becoming the timeline; and likewise today's
    /// project page becoming the project's page over the timeline. That is
    /// not a move, so Back goes where the user was before, and never onto
    /// a place that turns straight back into this one.
    static func fillsIn(from current: MacPlace?, to next: MacPlace) -> Bool {
        guard case .timeline(let place, let story, let section) = next.detail, let current else { return false }
        switch current.detail {
        case .mission(nil): return story == nil
        case .project(let id): return story == id && section == nil
        case .timeline(nil, let was, let wasSection): return place != nil && was == story && wasSection == section
        default: return false
        }
    }

    /// Whether `next` is the page of the project whose section `current`
    /// shows: the section's own back row. The shell records that as a step
    /// back when the page is where the reader came from.
    static func closesSection(from current: MacPlace, to next: MacPlace) -> Bool {
        guard case .timeline(let place, let story?, _?) = current.detail else { return false }
        return next.detail == .timeline(place: place, story: story, section: nil)
    }

    /// What the Projects detail shows for an open project.
    enum ProjectContent: Equatable {
        case summary
        case section(ProjectSection)
        /// The journal has no project-page route: the project page it had.
        case todaysPage
        case missing, loadFailed, loading
    }

    /// An older journal first (it has nothing to show a section of), then
    /// the page or its section, then why there is none.
    static func projectContent(hasPage: Bool, isMissing: Bool, isUnsupported: Bool, loadFailed: Bool,
                               section: ProjectSection?) -> ProjectContent {
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
}

/// The shell's timeline state, one per window: the shared state (the view
/// model, built on the first visit to Projects and only with the flag on,
/// and the list column's pick) and the project open over it with the
/// section of its page, which are the Mac's own (iOS pushes them).
@MainActor @Observable
final class MacTimelineState {
    let host = TimelineHostState()
    /// A project opened from the timeline, shown as its page.
    private(set) var storyProjectID: String?
    /// The section of the open project's page; nil is the page itself.
    var storySection: ProjectSection?

    var viewModel: TimelineViewModel? { host.viewModel }
    var isShown: Bool { host.isShown }
    var place: TimelinePlace? { host.place }

    /// What the shell's place carries, or nil when the timeline is not shown.
    var placeInput: MacTimelineNav.PlaceInput? {
        isShown ? .init(place: place, story: storyProjectID, section: storySection) : nil
    }

    /// Opens `projectID` over the timeline (nil: none) on its page, or on
    /// `section` of it. The section never carries over from another project.
    func openStory(_ projectID: String?, section: ProjectSection? = nil) {
        storyProjectID = projectID
        storySection = section
    }

    /// Projects came on screen (`TimelineHostState.projectsShown`).
    @discardableResult
    func projectsShown(flagOn: Bool? = nil, build: () -> TimelineViewModel) -> Task<Void, Never>? {
        host.projectsShown(flagOn: flagOn, build: build)
    }

    func select(_ place: TimelinePlace?) { host.select(place) }

    /// A new session: nothing of the old one's timeline carries over.
    func reset() {
        host.reset()
        openStory(nil)
    }
}

/// The list column under Projects: the weeks and "Worth a look".
struct MacTimelineColumn: View {
    let state: MacTimelineState
    let onSelect: (TimelinePlace) -> Void

    var body: some View {
        if let viewModel = state.viewModel {
            TimelineSidebarView(weeks: viewModel.weeks, showsProjects: viewModel.showsAllProjects,
                                projectsCount: viewModel.allProjects?.total,
                                quietCount: viewModel.quiet?.total,
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

/// The Projects detail with the timeline shown: a project's page when one
/// is open, else the week or list the column has selected.
struct MacTimelineDetail: View {
    let state: MacTimelineState
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    @Binding var slot: MacProjectPageSlot<ProjectDetailViewModel>
    /// A project the shell selected itself (before the timeline answered,
    /// or by Back onto such a place): shown like one opened from the timeline.
    let selectedProjectID: String?
    let actions: MacProjectPageActions
    let onOpenStory: (String) -> Void
    /// A section of the open project's page, or nil for the page itself.
    let onOpenSection: (ProjectSection?) -> Void
    let onRedirectStory: (String) -> Void

    var body: some View {
        if let projectID = selectedProjectID ?? state.storyProjectID {
            MacTimelineProjectHost(projectID: projectID, section: state.storySection, session: session,
                                   missionsViewModel: missionsViewModel, slot: $slot, actions: actions,
                                   onOpenSection: onOpenSection, onRedirectStory: onRedirectStory,
                                   onChanged: { await state.host.projectChanged() })
                // Another project is another page: its reads, its pictures
                // and anything it was asking start over.
                .id(projectID)
        } else if let viewModel = state.viewModel {
            MacTimelinePlaceView(viewModel: viewModel, place: state.place, session: session,
                                 onRefresh: { await state.host.refresh() },
                                 onOpenProject: onOpenStory, onOpenItem: actions.onOpenItem)
        }
    }
}

/// One week, or one of the three lists (`TimelinePlaceView`), with its
/// pictures and its alert.
struct MacTimelinePlaceView: View {
    let viewModel: TimelineViewModel
    let place: TimelinePlace?
    let session: UserSession
    /// "Try again": the place and the counts again.
    let onRefresh: () async -> Void
    let onOpenProject: (String) -> Void
    let onOpenItem: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var images = TimelineImages()

    var body: some View {
        TimelinePlaceView(content: viewModel.content(for: place), now: Date(), images: images.images,
                          sizes: images.sizes,
                          asked: viewModel.askedProjectIDs, onOpenProject: onOpenProject, onOpenItem: onOpenItem,
                          onAsk: { stalled in Task { await viewModel.ask(about: stalled) } },
                          onLoadMoreFinished: { Task { await viewModel.loadMoreFinished() } },
                          onLoadMoreProjects: { Task { await viewModel.loadMoreProjects() } },
                          onRetry: { Task { await onRefresh() } })
            .task(id: viewModel.imageBlobIDs(for: place)) {
                guard let deps else { return }
                await images.load(viewModel.imageBlobIDs(for: place), media: deps.mediaService(for: session),
                                  base: session.homeserverURL)
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.showsError(on: place) }, set: { if !$0 { viewModel.error = nil } })
    }
}

/// A project open over the timeline: its page (`ProjectSummaryView`), or
/// one of the page's three sections under a row back to the page. Where
/// the project stands and its history come from a `ProjectSummaryViewModel`;
/// its missions, its files and the "···" actions from the shell's
/// `ProjectDetailViewModel`. On a journal without the project-page route
/// it shows the project page that journal has.
struct MacTimelineProjectHost: View {
    let projectID: String
    let section: ProjectSection?
    let session: UserSession
    let missionsViewModel: MissionsDashboardViewModel
    @Binding var slot: MacProjectPageSlot<ProjectDetailViewModel>
    let actions: MacProjectPageActions
    let onOpenSection: (ProjectSection?) -> Void
    let onRedirectStory: (String) -> Void
    /// A "···" write landed: the timeline's lists name the project too.
    let onChanged: () async -> Void

    @Environment(\.appDependencies) private var deps
    @State private var summary: ProjectSummaryViewModel?
    /// The first read of the page failed, so there is nothing to show.
    @State private var loadFailed = false
    @State private var images = TimelineImages()
    /// This host's claim on `slot`: only the page that last showed the view
    /// model stops it on leaving.
    @State private var pageToken = UUID()
    @State private var confirmMerge: Project?
    @State private var confirmClose = false
    @State private var renameShown = false
    /// "Ask the Coordinator" could not be sent.
    @State private var askError: String?
    @State private var imagePreview: GalleryPreview?
    @State private var mediaPreview: MediaPlayerPreview?

    /// What `.sheet(item:)` keys on for the image viewer.
    private struct GalleryPreview: Identifiable {
        let id = UUID()
        let gallery: ImageGallery
    }

    var body: some View {
        Group {
            if content == .todaysPage {
                MacProjectPage(projectID: projectID, session: session, missionsViewModel: missionsViewModel,
                               slot: $slot, actions: actions, onRedirect: onRedirectStory, ownsSlot: false)
            } else {
                page
            }
        }
        .task(id: projectID) {
            guard let deps else { return }
            slot.show(projectID: projectID, owner: owner, page: pageToken) {
                deps.makeProjectDetailViewModel(for: session, projectID: projectID)
            }
            await load()
        }
        .onDisappear { slot.pageDidDisappear(owner: owner, page: pageToken) }
    }

    private var owner: ObjectIdentifier { ObjectIdentifier(missionsViewModel) }

    private var detail: ProjectDetailViewModel? { slot.current(projectID: projectID, owner: owner) }

    private var content: MacTimelineNav.ProjectContent {
        MacTimelineNav.projectContent(hasPage: summary?.page != nil, isMissing: summary?.isMissing == true,
                                      isUnsupported: summary?.isUnsupported == true, loadFailed: loadFailed,
                                      section: section)
    }

    /// Reads the page: the first time, and again for "Try again".
    private func load() async {
        guard let deps else { return }
        let summary = self.summary ?? deps.makeProjectSummaryViewModel(for: session, projectID: projectID)
        self.summary = summary
        loadFailed = false
        await summary.start()
        guard !Task.isCancelled else { return }
        loadFailed = summary.page == nil && !summary.isMissing && !summary.isUnsupported
        // The page says it could not load; an alert over it would say so twice.
        if loadFailed { summary.error = nil }
    }

    @ViewBuilder private var page: some View {
        Group {
            switch content {
            case .summary:
                if let page = summary?.page { summaryView(page) }
            case .section(let section):
                if let page = summary?.page {
                    VStack(spacing: 0) {
                        sectionBackRow(page.project.title)
                        Divider()
                        sectionView(section)
                    }
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
                    Button("Try again") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading, .todaysPage:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Counted like today's project page (which counts itself): the
        // dashboard keeps the project list fresh while a project is open.
        .onAppear { missionsViewModel.projectPageDidAppear() }
        .onDisappear { missionsViewModel.projectPageDidDisappear() }
        // A merge moved the project: the page follows it, whichever of its
        // two reads says so first.
        .onChange(of: slot.model?.projectID) { _, id in
            if let target = slot.redirect(to: id, pageProjectID: projectID) { onRedirectStory(target) }
        }
        .onChange(of: summary?.redirectedTo) { _, target in
            if let target, target != projectID { onRedirectStory(target) }
        }
        .task(id: imageBlobIDs) {
            guard let deps else { return }
            await images.load(imageBlobIDs, media: deps.mediaService(for: session), base: session.homeserverURL)
        }
        .alert("Projects", isPresented: errorShown) {
            Button("OK") { clearError() }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog(mergeTitle, isPresented: mergeShown) {
            Button("Merge", role: .destructive) {
                if let target = confirmMerge { act { _ = await $0.merge(into: target.id) } }
                confirmMerge = nil
            }
            Button("Cancel", role: .cancel) { confirmMerge = nil }
        } message: {
            Text("Its missions move there and this project closes.")
        }
        .confirmationDialog(ProjectActionsFormat.closeConfirmation(title: title), isPresented: $confirmClose) {
            Button("Close project", role: .destructive) { act { _ = await $0.close() } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $renameShown) {
            MacProjectRenameSheet(title: title) { newTitle in act { _ = await $0.rename(to: newTitle) } }
        }
        .sheet(item: $imagePreview) { preview in
            AttachmentFullscreenViewer(gallery: preview.gallery, onDismiss: { imagePreview = nil })
        }
        .mediaPlayerSheet(item: $mediaPreview)
    }

    private var title: String { summary?.page?.project.title ?? "" }

    // MARK: The page and its sections

    private func summaryView(_ page: TimelineProjectPage) -> some View {
        ProjectSummaryView(page: page, image: page.media.flatMap { images.images[$0.blobID] },
                           pixelSize: page.media.flatMap { images.sizes[$0.blobID] },
                           onOpenItem: actions.onOpenItem, onOpenSection: { onOpenSection($0) }) {
            ProjectActionsMenu(isOpen: page.isOpen, isLoaded: detail?.page != nil,
                               unfiled: detail?.page?.unfiledMissions ?? [],
                               mergeTargets: detail?.page?.mergeTargets ?? [],
                               onAddMission: { id in act { await $0.addMission(id) } },
                               onAsk: ask,
                               onRename: { renameShown = true },
                               onMerge: { id in confirmMerge = detail?.page?.mergeTargets.first { $0.id == id } },
                               onClose: { confirmClose = true })
        }
    }

    /// "‹ <project name>": back to the project's page.
    private func sectionBackRow(_ title: String) -> some View {
        HStack {
            Button { onOpenSection(nil) } label: { Label(title, systemImage: "chevron.backward").lineLimit(1) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("projects.section.back")
            Spacer()
        }
        .font(.system(size: 14))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private func sectionView(_ section: ProjectSection) -> some View {
        switch section {
        case .history:
            ProjectHistoryView(weeks: summary?.history ?? [], now: Date(), images: images.images, sizes: images.sizes,
                               hasMore: summary?.hasMoreHistory == true,
                               onOpenMilestone: { actions.onOpenMilestone($0.milestone) },
                               onLoadMore: { Task { await summary?.loadMoreHistory() } })
                .task { await summary?.loadHistory() }
        case .missions:
            if let page = detail?.page {
                ProjectMissionsListView(open: page.missions, closed: page.closedMissions, now: Date(),
                                        onOpenMission: actions.onOpenMission)
            } else {
                detailPlaceholder
            }
        case .files:
            if let page = detail?.page {
                ProjectFilesGridView(files: page.files.rows, images: images.images, now: Date(),
                                     hasMore: page.files.nextBefore != nil,
                                     onOpenFile: { open($0, among: page.files.rows) },
                                     onLoadMore: { Task { await detail?.loadMore(kind: .files) } })
            } else {
                detailPlaceholder
            }
        }
    }

    /// The missions and files come from the shell's project view model:
    /// still loading, or it could not load.
    @ViewBuilder private var detailPlaceholder: some View {
        if detail?.loadFailed == true {
            ContentUnavailableView {
                Label("Couldn't load this project", systemImage: ProjectGlyph.symbol)
            } description: {
                Text("The journal didn't answer. Check the connection and try again.")
            } actions: {
                Button("Try again") { Task { await detail?.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Pictures and files

    /// The pictures what is on screen draws: the page's own, the history
    /// weeks', or the files'. A video draws its play mark instead.
    private var imageBlobIDs: [String] {
        switch content {
        case .summary: return [summary?.page?.media].compactMap { $0 }.filter { !$0.isVideo }.map(\.blobID)
        case .section(.history): return (summary?.history ?? []).compactMap(\.media).filter { !$0.isVideo }.map(\.blobID)
        case .section(.files): return MacTimelineNav.pictureBlobIDs(detail?.page?.files.rows ?? [])
        default: return []
        }
    }

    private func open(_ file: ProjectFile, among files: [ProjectFile]) {
        switch MacTimelineNav.fileOpening(file) {
        case .picture:
            let urls = MacTimelineNav.pictureBlobIDs(files).map(mediaURL)
            let names = MacTimelineNav.pictureBlobIDs(files).map { blobID in files.first { $0.blobID == blobID }?.name }
            imagePreview = GalleryPreview(gallery: ImageGalleries.urls(urls, names: names, tapped: mediaURL(file.blobID),
                                                                       deps: deps, session: session))
        case .video:
            let name = file.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? MacAttachmentOpener.fallbackFilename(mime: file.contentType ?? "")
            MacAttachmentOpener.open(filename: name, mime: file.contentType,
                                     load: { await localFile(file, name: name) }, preview: { mediaPreview = $0 })
        case .source:
            MacProjectPage.openFile(file, deps: deps, session: session, actions: actions, vm: detail)
        }
    }

    private func mediaURL(_ blobID: String) -> URL {
        session.homeserverURL.appendingPathComponent("media").appendingPathComponent(blobID)
    }

    /// The video as a temp file for the player: the copy already there, or fetched.
    private func localFile(_ file: ProjectFile, name: String) async -> URL? {
        if let existing = AttachmentTempFiles.existingFile(name: name, blobRef: file.blobID) { return existing }
        guard let deps, let data = await deps.mediaService(for: session).fetchBytes(mxcURL: mediaURL(file.blobID))
        else { return nil }
        return try? AttachmentTempFiles.write(data, name: name, blobRef: file.blobID)
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
            await onChanged()
        }
    }

    private func ask() {
        guard let deps, !title.isEmpty else { return }
        let send = deps.coordinatorAsk(for: session, coordinatorConvoID: { [weak missionsViewModel] in
            missionsViewModel?.coordinatorConvoID
        })
        let message = ProjectActionsFormat.askMessage(title: title)
        Task {
            do { try await send(message) } catch { askError = error.localizedDescription }
        }
    }

    private var error: String? { askError ?? detail?.error ?? summary?.error }

    private func clearError() {
        askError = nil
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
struct MacProjectRenameSheet: View {
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(title: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _title = State(initialValue: title)
    }

    /// Whether `title` can be saved: something other than space.
    static func canSave(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename project").font(.headline)
            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .accessibilityIdentifier("projects.rename.field")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canSave(title))
                    .accessibilityIdentifier("projects.rename.save")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        guard Self.canSave(title) else { return }
        onSave(title)
        dismiss()
    }
}
