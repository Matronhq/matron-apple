import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// Conversations → Archived: every archived conversation, most recently
/// active first, with a search field. Tapping a row opens the
/// conversation (a message sent there brings it back to the list); swipe
/// or long-press to Unarchive.
struct ArchivedChatsView: View {
    @State private var viewModel: ArchivedChatsViewModel
    private let notifyStore: NotifySettingsStore?

    init(chat: ChatService, notifyStore: NotifySettingsStore?) {
        _viewModel = State(initialValue: ArchivedChatsViewModel(chat: chat))
        self.notifyStore = notifyStore
    }

    /// For tests and previews: a view model the caller already holds.
    init(viewModel: ArchivedChatsViewModel, notifyStore: NotifySettingsStore? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.notifyStore = notifyStore
    }

    var body: some View {
        content
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search archived")
            .task { viewModel.start() }
            .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        let rows = viewModel.filtered
        if viewModel.isLoading {
            ProgressView()
        } else if viewModel.summaries.isEmpty {
            ContentUnavailableView(
                "No archived conversations",
                systemImage: "archivebox",
                description: Text("Conversations you archive, or that sit idle long enough, appear here.")
            )
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: viewModel.query)
        } else {
            List(rows) { summary in
                // Same chevron-less link as the Conversations rows.
                ZStack {
                    NavigationLink(value: summary.id) { EmptyView() }
                        .opacity(0)
                    ChatRow(summary: summary,
                            isNotifySilenced: notifyStore?.state(for: summary.id).isSilenced ?? false)
                }
                .contextMenu {
                    Button { unarchive(summary.id) } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button { unarchive(summary.id) } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                    .tint(.indigo)
                }
            }
            .listStyle(.plain)
        }
    }

    private func unarchive(_ id: String) {
        Task { await viewModel.unarchive([id]) }
    }
}
