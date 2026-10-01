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
    @State private var showNewProject = false

    var body: some View {
        content
            .navigationTitle("Projects")
            .toolbar { toolbarContent }
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .sheet(isPresented: $showNewProject) { newProjectSheet }
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
            ProjectsHomeView(model: homeModel, onAction: handle, onRefresh: { await viewModel.refresh() })
        }
    }

    private var homeModel: ProjectsHomeView.Model {
        ProjectsHomeView.Model(home: viewModel.home, isRefreshing: viewModel.isRefreshing, askedAt: viewModel.askedAt,
                               isAskEnabled: viewModel.canSendAsk, canCreateProject: viewModel.canCreateProject)
    }

    private var legacyModel: MissionsDashboardView.Model {
        MissionsDashboardView.Model(cards: viewModel.cards, looseSessions: viewModel.looseSessions, closed: viewModel.closed,
                                    isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
                                    askedAt: viewModel.askedAt, isAskEnabled: viewModel.canSendAsk)
    }

    private func handle(_ action: ProjectsHomeAction) {
        switch action {
        case .newProject: showNewProject = true
        case .moveMission(let missionID, let projectID): Task { await viewModel.moveMission(missionID, to: projectID) }
        case .openProject, .openMission: onAction(action)
        }
    }

    private var newProjectSheet: some View {
        NewProjectSheet(onCreate: { title, body in
            guard let project = await viewModel.createProject(title: title, body: body) else {
                let failure = viewModel.error ?? "Couldn't create the project."
                viewModel.error = nil
                return failure
            }
            showNewProject = false
            onAction(.openProject(project.id))
            return nil
        }, onCancel: { showNewProject = false })
        .presentationDetents([.medium])
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil && !showNewProject }, set: { if !$0 { viewModel.error = nil } })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if viewModel.canCreateProject {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewProject = true } label: { Label("New project", systemImage: "plus") }
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
