import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// One mission page in the Mac detail column. `backConvoID` is set when the
/// page was reached from a conversation's title, so the reader has a way
/// back to where they were (spec: "the detail column switches to it with a
/// back affordance").
struct MacMissionPage: View {
    let missionID: String
    let session: UserSession
    let backConvoID: String?
    let onBack: (String) -> Void
    let onOpenMilestone: (String, Int64) -> Void
    let onOpenItem: (String) -> Void
    let onOpenConversation: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: MissionDetailViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if let backConvoID {
                HStack {
                    Button { onBack(backConvoID) } label: { Label("Back to the conversation", systemImage: "chevron.backward") }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 6)
                Divider()
            }
            if let viewModel {
                MissionDetailView(
                    // Same `Model` init the iOS host calls (Task 7) — the
                    // mapping exists once, so the pages cannot drift.
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
