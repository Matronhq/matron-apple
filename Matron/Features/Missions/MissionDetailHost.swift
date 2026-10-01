import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One mission page on iOS. Owns its `MissionDetailViewModel` for the life
/// of the pushed screen and maps it into `MissionDetailView.Model`.
struct MissionDetailHost: View {
    let missionID: String
    let session: UserSession
    /// Opens a milestone's conversation at its anchor seq.
    let onOpenMilestone: (String, Int64) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @Environment(\.openProject) private var openProject
    /// "also on #N" / "moved to #N": that mission's page, on whichever
    /// stack this page is mounted (idempotent for the top). Every stack
    /// that mounts a mission page — Projects, Conversations, Coordinator —
    /// already sets this.
    @Environment(\.chatNavigationPath) private var chatNavigationPath
    @State private var viewModel: MissionDetailViewModel?

    var body: some View {
        Group {
            if let viewModel {
                MissionDetailView(
                    // The mapping itself lives on the model (Task 7) — the
                    // Mac page calls the same init, so the two platforms'
                    // pages cannot drift.
                    model: .init(mission: viewModel.mission, project: viewModel.project, milestones: viewModel.milestones,
                                 sessionTags: viewModel.sessionTags,
                                 openItems: viewModel.openItems, conversations: viewModel.conversations,
                                 moveTargets: viewModel.moveTargets,
                                 conversationGroups: viewModel.conversationGroups,
                                 showOnlyUserInput: viewModel.showOnlyUserInput,
                                 closeSummary: viewModel.closeSummaryDraft, isBusy: viewModel.isBusy),
                    onToggleUserInputOnly: { viewModel.showOnlyUserInput = $0 },
                    onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
                    onOpenItem: onOpenItem,
                    onOpenConversation: onOpenConversation,
                    onEditCloseSummary: { viewModel.closeSummaryDraft = $0 },
                    onClose: { Task { await viewModel.close() } },
                    onRefresh: { await viewModel.refresh() },
                    onOpenProject: openProject,
                    onMove: viewModel.canMove ? { target in Task { await viewModel.moveToProject(target) } } : nil,
                    onOpenMission: { ChatView.pushMission($0, onto: chatNavigationPath) })
                .alert("Projects", isPresented: Binding(get: { viewModel.error != nil },
                                                        set: { if !$0 { viewModel.error = nil } })) {
                    Button("OK") { viewModel.error = nil }
                } message: {
                    Text(viewModel.error ?? "")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel?.mission.map { "#\($0.num)" } ?? "Mission")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: missionID) {
            guard let deps else { return }
            viewModel?.stop()
            let vm = deps.makeMissionDetailViewModel(for: session, missionID: missionID)
            viewModel = vm
            vm.start()
        }
        .onDisappear { viewModel?.stop() }
        // App shell (spec §3): the tab bar shows only at a tab's root, like
        // ItemDetailHost and ChatDestinationView's pushed (non-root) case.
        .tabBarFollowsTheSelectedTab(otherwise: .hidden)
    }
}
