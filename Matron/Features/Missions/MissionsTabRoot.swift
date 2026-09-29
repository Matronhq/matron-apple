import SwiftUI
import MatronDesignSystem
import MatronModels
import MatronViewModels

/// The Missions tab's root: the dashboard (spec 2026-09-28 §3.1). The view
/// model is owned by `AppShellView` (its badge is read while another tab
/// shows), so this view only maps it and reports taps. The roster poll and
/// the detail refresh run while this root is on screen.
struct MissionsTabRoot: View {
    let viewModel: MissionsDashboardViewModel
    let onAction: (MissionsDashboardAction) -> Void
    /// The Memories entry (decision #3948): a toolbar button on this root.
    var onOpenMemories: (() -> Void)? = nil

    var body: some View {
        MissionsDashboardView(model: model, onAction: onAction, onRefresh: { await viewModel.refresh() })
            .navigationTitle("Missions")
            .toolbar { toolbarContent }
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

    private var errorShown: Binding<Bool> {
        Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if viewModel.canAskCoordinator {
            ToolbarItem(placement: .primaryAction) {
                MissionsDashboardAskButton { Task { await viewModel.askCoordinator() } }
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
