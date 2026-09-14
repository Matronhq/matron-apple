import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// The Missions tab's root list. The view model is owned by `AppShellView`
/// (its badge is read while another tab shows), so this view only maps it
/// into the leaf view's `Model` and reports selections.
struct MissionsTabRoot: View {
    let viewModel: MissionsListViewModel
    let onSelect: (String) -> Void

    var body: some View {
        MissionsListView(
            model: .init(open: viewModel.open, closed: viewModel.closed,
                         // Not proven false yet ⇒ treated as supported,
                         // same as every other `isSupported` consumer
                         // (CodeRabbit #209 fix round 2, H2).
                         isSupported: viewModel.isSupported != false, isRefreshing: viewModel.isRefreshing),
            onSelect: onSelect,
            onRefresh: { await viewModel.refresh() })
        .navigationTitle("Missions")
        .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}
