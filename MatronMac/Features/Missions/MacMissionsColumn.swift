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
                         isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing),
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
