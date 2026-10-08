import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Projects tab's root (spec 2026-09-30 §6). The view model is the
/// shell's session-long `MissionsDashboardViewModel` (its badge shows while
/// another tab does). A journal without `/projects` keeps today's missions
/// dashboard here (spec §7).
struct ProjectsTabRoot: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (ProjectsHomeAction) -> Void
    let onLegacyAction: (MissionsDashboardAction) -> Void
    var onOpenMemories: (() -> Void)? = nil
    @Environment(\.currentSession) private var session
    /// One `.sheet` for both: a second `.sheet` modifier on this root left
    /// a push on the Projects stack mid-transition for good (the Memories
    /// pages' pop in AppShellViewTests).
    @State private var sheet: ProjectsSheet?

    private enum ProjectsSheet: String, Identifiable {
        case newProject, briefing
        var id: String { rawValue }
    }

    var body: some View {
        content
            .navigationTitle("Projects")
            .toolbar { toolbarContent }
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .newProject: newProjectSheet
                case .briefing: briefingSheet
                }
            }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if viewModel.projectsSupported == false {
            MissionsDashboardView(model: legacyModel, onAction: onLegacyAction, onRefresh: { await viewModel.refresh() })
        } else {
            ProjectsHomeView(model: homeModel, onAction: handle, onRefresh: { await viewModel.refresh() },
                             onOpenBriefing: { sheet = .briefing },
                             onRefreshBriefing: { Task { await viewModel.briefing?.requestRefresh() } })
        }
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

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil && sheet != .newProject }, set: { if !$0 { viewModel.error = nil } })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if viewModel.canCreateProject {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .newProject } label: { Label("New project", systemImage: "plus") }
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
                Button { onOpenMemories() } label: { Label("Memories", systemImage: "brain") }
                    .accessibilityIdentifier("missions.memories")
            }
        }
    }
}
