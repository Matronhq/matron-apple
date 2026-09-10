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
    @State private var viewModel: MissionDetailViewModel?

    var body: some View {
        Group {
            if let viewModel {
                MissionDetailView(
                    // The mapping itself lives on the model (Task 7) — the
                    // Mac page calls the same init, so the two platforms'
                    // pages cannot drift.
                    model: .init(mission: viewModel.mission, milestones: viewModel.milestones,
                                 sessionTags: viewModel.sessionTags,
                                 openItems: viewModel.openItems, conversations: viewModel.conversations,
                                 showOnlyUserInput: viewModel.showOnlyUserInput,
                                 closeSummary: viewModel.closeSummaryDraft, isBusy: viewModel.isBusy),
                    onToggleUserInputOnly: { viewModel.showOnlyUserInput = $0 },
                    onOpenMilestone: { onOpenMilestone($0.convoID, $0.seq) },
                    onOpenItem: onOpenItem,
                    onOpenConversation: onOpenConversation,
                    onEditCloseSummary: { viewModel.closeSummaryDraft = $0 },
                    onClose: { Task { await viewModel.close() } })
                .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
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
    }
}
