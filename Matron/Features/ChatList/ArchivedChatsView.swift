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
    /// Opens a conversation, with its summary for the chat header (it is
    /// not in the list the header normally reads).
    private let onOpen: (ChatSummary) -> Void

    init(chat: ChatService, notifyStore: NotifySettingsStore?, onOpen: @escaping (ChatSummary) -> Void) {
        self.init(viewModel: ArchivedChatsViewModel(chat: chat), notifyStore: notifyStore, onOpen: onOpen)
    }

    /// For tests and previews: a view model the caller already holds.
    init(viewModel: ArchivedChatsViewModel, notifyStore: NotifySettingsStore? = nil,
         onOpen: @escaping (ChatSummary) -> Void = { _ in }) {
        _viewModel = State(initialValue: viewModel)
        self.notifyStore = notifyStore
        self.onOpen = onOpen
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
                Button { onOpen(summary) } label: {
                    ChatRow(summary: summary,
                            isNotifySilenced: notifyStore?.state(for: summary.id).isSilenced ?? false)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
