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
    let onSelectMessage: (SearchChatHit) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            if !viewModel.chatHits.isEmpty {
                Section("Chats") {
                    ForEach(viewModel.chatHits) { chat in
                        let line = viewModel.hitTitle(for: chat.id)
                        Button { onSelectChat(chat) } label: {
                            VStack(alignment: .leading) {
                                SessionTagText.titleLine(
                                    title: line.title, boxLetter: line.boxLetter,
                                    boxName: line.boxName, sessionShort: line.sessionShort,
                                    roomBoxNames: line.roomBoxNames,
                                    roomBoxShorts: line.roomBoxShorts,
                                    colorScheme: colorScheme)
                                Text(chat.bot.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !viewModel.messageHits.isEmpty {
                Section("Messages") {
                    // One row per CHAT (newest hit's snippet + match count),
                    // not one per message — see `SearchViewModel.messageHits`.
                    ForEach(viewModel.messageHits) { group in
                        let line = viewModel.hitTitle(for: group.roomID)
                        SearchResultRow(
                            hit: group.newestHit,
                            chatTitle: line.title,
                            sessionShort: line.sessionShort,
                            boxLetter: line.boxLetter,
                            boxName: line.boxName,
                            roomBoxNames: line.roomBoxNames,
                            roomBoxShorts: line.roomBoxShorts,
                            matchCount: group.count,
                            onTap: { onSelectMessage(group) }
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
