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
    /// "All missions": back to the dashboard. The Mac sidebar no longer
    /// lists missions, so a page reached from the dashboard needs a visible
    /// way back beside the window's Back (spec 2026-09-28 §3.1).
    var onShowDashboard: (() -> Void)? = nil

    @Environment(\.appDependencies) private var deps
    @State private var viewModel: MissionDetailViewModel?

    var body: some View {
        VStack(spacing: 0) {
            if backConvoID != nil || onShowDashboard != nil {
                navigationBar
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
                    onClose: { Task { await viewModel.close() } },
                    onRefresh: { await viewModel.refresh() })
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

    /// "All missions" always, so the dashboard is reachable from every
    /// page (review I1); "Back to the conversation" beside it when the
    /// page was opened from a conversation's title.
    private var navigationBar: some View {
        HStack(spacing: 16) {
            if let onShowDashboard {
                Button { onShowDashboard() } label: { Label("All missions", systemImage: "square.grid.2x2") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("missions.allMissions")
            }
            if let backConvoID {
                Button { onBack(backConvoID) } label: { Label("Back to the conversation", systemImage: "chevron.backward") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("missions.backToConversation")
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 6)
    }
}
