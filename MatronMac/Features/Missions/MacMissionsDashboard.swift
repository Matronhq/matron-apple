import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Missions dashboard in the Mac detail, full width (spec 2026-09-28
/// §3.1). A thin mapper: the view model lives for the session on the shell
/// so the nav badge stays live while another entry shows; the roster poll
/// and detail refresh run only while this is on screen — opening a mission
/// page or picking another nav entry unmounts it, which ends them.
struct MacMissionsDashboard: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (MissionsDashboardAction) -> Void

    var body: some View {
        MissionsDashboardView(model: model, onAction: onAction, onRefresh: { await viewModel.refresh() },
                              onAsk: askAction)
            .onAppear { viewModel.pageDidAppear() }
            .onDisappear { viewModel.pageDidDisappear() }
            .alert("Missions", isPresented: errorShown) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    private var model: MissionsDashboardView.Model {
        MissionsDashboardView.Model(
            cards: viewModel.cards, looseSessions: viewModel.looseSessions, closed: viewModel.closed,
            // Not proven false yet ⇒ supported (CodeRabbit #209, H2).
            isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing,
            askedAt: viewModel.askedAt)
    }

    /// Hidden with no Coordinator (spec §3.4).
    private var askAction: (() -> Void)? {
        guard viewModel.canAskCoordinator else { return nil }
        return { Task { await viewModel.askCoordinator() } }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })
    }
}
