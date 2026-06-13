import SwiftUI
import MatronSearch
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem  // SearchResultRow

/// iOS search screen — pushed from the chat list. Two sections: Chats
/// (title/bot matches, filtered in-memory from the chat-list snapshot) and
/// Messages (FTS hits via `SearchViewModel.search()`). Tapping a result routes
/// back through `onSelectChat` / `onSelectMessage`.
struct SearchView: View {
    @State var viewModel: SearchViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onSelectMessage: (SearchHit) -> Void
    /// Optional backfill progress stream from the app's `BackfillCoordinator`.
    /// When present, the empty state shows "Indexing chats… (X of Y rooms)"
    /// while history is still being indexed (Task 9 wires it).
    var backfillProgress: AsyncStream<AggregateBackfillProgress>? = nil

    var body: some View {
        List {
            if !viewModel.chatHits.isEmpty {
                Section("Chats") {
                    ForEach(viewModel.chatHits) { chat in
                        Button { onSelectChat(chat) } label: {
                            VStack(alignment: .leading) {
                                Text(chat.title)
                                Text(chat.bot.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !viewModel.messageHits.isEmpty {
                Section("Messages") {
                    ForEach(viewModel.messageHits) { hit in
                        SearchResultRow(
                            hit: hit,
                            chatTitle: viewModel.chatTitle(for: hit.roomID),
                            onTap: { onSelectMessage(hit) }
                        )
                    }
                }
            }
            if viewModel.query.isEmpty {
                Section { Text("Search across chat titles, bots, and messages.").foregroundStyle(.secondary) }
            } else if viewModel.chatHits.isEmpty && viewModel.messageHits.isEmpty && !viewModel.isSearching {
                Section { Text(viewModel.emptyResultsMessage).foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always))
        .onChange(of: viewModel.query) { _, _ in
            Task { await viewModel.search() }
        }
        .task {
            if let backfillProgress { await viewModel.observeBackfill(backfillProgress) }
        }
        .navigationTitle("Search")
    }
}
