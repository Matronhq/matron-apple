import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Projects tab's root (spec 2026-09-30 §6). The view model is the
/// shell's session-long `MissionsDashboardViewModel` (its badge shows while
/// another tab does). A journal without `/projects` keeps today's missions
/// dashboard here (spec §7). With the timeline shown (`timeline`, behind
/// its flag) the root is the week page instead of the home.
struct ProjectsTabRoot: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (ProjectsHomeAction) -> Void
    let onLegacyAction: (MissionsDashboardAction) -> Void
    var onOpenMemories: (() -> Void)? = nil
    var timeline: TimelineHostState? = nil
    var timelineActions: TimelineActions? = nil
    @Environment(\.currentSession) private var session
    /// One `.sheet` for both: a second `.sheet` modifier on this root left
    /// a push on the Projects stack mid-transition for good (the Memories
    /// pages' pop in AppShellViewTests).
    @State private var sheet: ProjectsSheet?

    private enum ProjectsSheet: String, Identifiable {
        case newProject, briefing
        var id: String { rawValue }
    }

    /// What a timeline page opens, on the Projects stack.
    struct TimelineActions {
        let onOpenStory: (String) -> Void
        let onOpenList: (TimelinePlace) -> Void
        let onOpenItem: (String) -> Void
    }

    /// Which page the root draws.
    enum Content: Equatable {
        /// Today's missions dashboard, on a journal without `/projects`.
        case legacy
        /// Today's Projects home.
        case home
        /// The timeline's week page.
        case timeline
    }

    static func content(projectsSupported: Bool?, timelineShown: Bool) -> Content {
        if projectsSupported == false { return .legacy }
        return timelineShown ? .timeline : .home
    }

    var body: some View {
        page
            .toolbar { toolbarContent }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .newProject: newProjectSheet
                case .briefing: briefingSheet
                }
            }
            // The one alert: the dashboard's (New project, Ask), else the
            // timeline's week page's.
            .alert("Projects", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
    }

    /// The dashboard's cards and their feeds run only while its page
    /// shows: the timeline's toolbar needs none of them.
    private func dashboardPage(_ page: some View) -> some View {
        page
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
    }

    private var shownContent: Content {
        Self.content(projectsSupported: viewModel.projectsSupported, timelineShown: timeline?.isShown == true)
    }

    @ViewBuilder private var page: some View {
        switch shownContent {
        case .legacy:
            dashboardPage(MissionsDashboardView(model: legacyModel, onAction: onLegacyAction,
                                                onRefresh: { await viewModel.refresh() })
                .navigationTitle("Projects"))
        case .home:
            home
        case .timeline:
            if let timeline, let timelineViewModel = phoneTimeline, let timelineActions, let session {
                TimelinePhoneRoot(state: timeline, viewModel: timelineViewModel, session: session,
                                  onOpenStory: timelineActions.onOpenStory, onOpenList: timelineActions.onOpenList,
                                  onOpenItem: timelineActions.onOpenItem)
            } else {
                home
            }
        }
    }

    private var home: some View {
        dashboardPage(ProjectsHomeView(model: homeModel, onAction: handle, onRefresh: { await viewModel.refresh() },
                                       onOpenBriefing: { sheet = .briefing },
                                       onRefreshBriefing: { Task { await viewModel.briefing?.requestRefresh() } })
            .navigationTitle("Projects"))
    }

    /// The timeline's view model when the root is its week page.
    private var phoneTimeline: TimelineViewModel? {
        guard shownContent == .timeline, timelineActions != nil, session != nil else { return nil }
        return timeline?.viewModel
    }

    private var homeModel: ProjectsHomeView.Model {
        ProjectsHomeView.Model(home: viewModel.home, isRefreshing: viewModel.isRefreshing, askedAt: viewModel.askedAt,
                               isAskEnabled: viewModel.canSendAsk, canCreateProject: viewModel.canCreateProject,
                               briefing: viewModel.briefing?.cardModel)
    }

    private var legacyModel: MissionsDashboardView.Model {
        MissionsDashboardView.Model(cards: viewModel.cards, looseSessions: viewModel.looseSessions, closed: viewModel.closed,
                                    isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
                                    askedAt: viewModel.askedAt, isAskEnabled: viewModel.canSendAsk)
    }

    private func handle(_ action: ProjectsHomeAction) {
        switch action {
        case .newProject: sheet = .newProject
        case .moveMission(let missionID, let projectID): Task { await viewModel.moveMission(missionID, to: projectID) }
        case .openProject, .openMission: onAction(action)
        case .openConversation, .openItem:
            sheet = nil
            onAction(action)
        }
    }

    /// The latest briefing in full (the card's tap). Read from the store at
    /// presentation, so a briefing published while it is open shows there.
    @ViewBuilder private var briefingSheet: some View {
        if let briefing = viewModel.briefing?.briefing {
            BriefingReaderSheet(briefing: briefing, session: session, onAction: handle,
                                onDone: { sheet = nil })
        }
    }

    private var newProjectSheet: some View {
        NewProjectSheet(onCreate: { title, body in
            guard let project = await viewModel.createProject(title: title, body: body) else {
                let failure = viewModel.error ?? "Couldn't create the project."
                viewModel.error = nil
                return failure
            }
            sheet = nil
            onAction(.openProject(project.id))
            return nil
        }, onCancel: { sheet = nil })
        .presentationDetents([.medium])
    }

    /// The dashboard's error; the New project sheet shows its own.
    private var dashboardError: String? { sheet == .newProject ? nil : viewModel.error }

    /// The week page's error, when it says one (`TimelineViewModel.showsError`).
    private var timelineError: String? {
        guard let timeline, let timelineViewModel = phoneTimeline,
              timelineViewModel.showsError(on: TimelinePhoneRoot.place(timeline)) else { return nil }
        return timelineViewModel.error
    }

    private var alertMessage: String? { dashboardError ?? timelineError }

    private var errorShown: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { shown in
            guard !shown else { return }
            if dashboardError != nil { viewModel.error = nil } else { timeline?.viewModel?.error = nil }
        })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if viewModel.canCreateProject {
            ToolbarItem(placement: .primaryAction) {
                Button { KeyboardDismiss.resign(); sheet = .newProject } label: { Label("New project", systemImage: "plus") }
                    .accessibilityIdentifier("projects.new")
            }
        }
        if viewModel.canAskCoordinator {
            ToolbarItem(placement: .primaryAction) {
                MissionsDashboardAskButton(isEnabled: viewModel.canSendAsk) { Task { await viewModel.askCoordinator() } }
            }
        }
        if let onOpenMemories {
            ToolbarItem(placement: .primaryAction) {
                Button { KeyboardDismiss.resign(); onOpenMemories() } label: { Label("Memories", systemImage: "brain") }
                    .accessibilityIdentifier("missions.memories")
            }
        }
    }
}
