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

/// The shell's timeline state, one per window: the shared state (the view
/// model, built on the first visit to Projects and only with the flag on,
/// and the list column's pick) and the project story open over it, which
/// is the Mac's own (iOS pushes it).
@MainActor @Observable
final class MacTimelineState {
    let host = TimelineHostState()
    /// A project opened from the timeline, shown as its story.
    var storyProjectID: String?

    var viewModel: TimelineViewModel? { host.viewModel }
    var isShown: Bool { host.isShown }
    var place: TimelinePlace? { host.place }

    /// What the shell's place carries, or nil when the timeline is not shown.
    var placeInput: MacTimelineNav.PlaceInput? {
        isShown ? .init(place: place, story: storyProjectID) : nil
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
                          asked: viewModel.askedProjectIDs, onOpenProject: onOpenProject, onOpenItem: onOpenItem,
                          onAsk: { stalled in Task { await viewModel.ask(about: stalled) } },
                          onLoadMoreFinished: { Task { await viewModel.loadMoreFinished() } },
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
    @State private var images = TimelineImages()
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
