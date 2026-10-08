import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Projects home in the Mac detail, full width. A thin host like
/// `MacMissionsDashboard`: it owns the New project sheet and the move
/// write, and hands navigation to the shell.
struct MacProjectsHome: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (ProjectsHomeAction) -> Void
    @Environment(\.currentSession) private var session
    @State private var showNewProject = false
    @State private var showBriefing = false

    var body: some View {
        ProjectsHomeView(model: model, onAction: handle, onRefresh: { await viewModel.refresh() }, onAsk: askAction,
                         onOpenBriefing: { showBriefing = true },
                         onRefreshBriefing: { Task { await viewModel.briefing?.requestRefresh() } })
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .sheet(isPresented: $showNewProject) {
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
                .frame(width: 440)
            }
            .sheet(isPresented: $showBriefing) { briefingSheet }
            .alert("Projects", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    private var model: ProjectsHomeView.Model {
        ProjectsHomeView.Model(home: viewModel.home, isRefreshing: viewModel.isRefreshing, askedAt: viewModel.askedAt,
                               isAskEnabled: viewModel.canSendAsk, canCreateProject: viewModel.canCreateProject,
                               briefing: viewModel.briefing?.cardModel)
    }

    private func handle(_ action: ProjectsHomeAction) {
        switch action {
        case .newProject: showNewProject = true
        case .moveMission(let missionID, let projectID): Task { await viewModel.moveMission(missionID, to: projectID) }
        case .openProject, .openMission: onAction(action)
        case .openConversation, .openItem:
            showBriefing = false
            onAction(action)
        }
    }

    /// The latest briefing in full (the card's click). Read from the store
    /// at presentation, so a briefing published while it is open shows there.
    @ViewBuilder private var briefingSheet: some View {
        if let briefing = viewModel.briefing?.briefing {
            MacBriefingReaderSheet(briefing: briefing, session: session, onAction: handle,
                                   onDone: { showBriefing = false })
        }
    }

    private var askAction: (() -> Void)? {
        guard viewModel.canAskCoordinator else { return nil }
        return { Task { await viewModel.askCoordinator() } }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil && !showNewProject }, set: { if !$0 { viewModel.error = nil } })
    }
}
