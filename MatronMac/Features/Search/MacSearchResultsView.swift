import SwiftUI
import MatronSearch
import MatronChat       // ChatSummary
import MatronModels
import MatronViewModels
import MatronDesignSystem  // SearchResultRow

/// Mac search results panel. Replaces the chat detail column while the toolbar
/// search field has a non-empty query. Renders the same two-section layout as
/// iOS `SearchView` (Chats / Messages) using the shared `SearchViewModel` +
/// `SearchResultRow`, so the two platforms can't drift on snippet rendering.
struct MacSearchResultsView: View {
    @Bindable var viewModel: SearchViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onSelectMessage: (SearchHit) -> Void

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
                        .buttonStyle(.plain)
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
            if viewModel.chatHits.isEmpty && viewModel.messageHits.isEmpty && !viewModel.isSearching {
                Section { Text(viewModel.emptyResultsMessage).foregroundStyle(.secondary) }
            }
        }
    }
}
