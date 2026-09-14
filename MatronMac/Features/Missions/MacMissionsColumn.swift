import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// The Missions list in the Mac sidebar column. A thin mapper, like
/// `MacChatListView.decisionsColumn` — the view model lives for the session
/// on the host so the nav badge stays live while another entry shows.
struct MacMissionsColumn: View {
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
        .alert("Missions", isPresented: Binding(get: { viewModel.error != nil },
                                                set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}
