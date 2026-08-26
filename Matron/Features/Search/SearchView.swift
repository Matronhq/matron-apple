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
    /// Grouped message-row tap: the chat's aggregate plus the query that
    /// produced it, so the parent can arm the opened chat's in-conversation
    /// search (the VM lives inside this sheet and dies with it).
    let onSelectMessage: (SearchChatHit, String) -> Void
    /// Live chat-list snapshot from the parent. `viewModel` is held as `@State`,
    /// so the `allChats` it was built with freezes when the sheet opens; folding
    /// later updates in here keeps new rooms and renamed titles searchable while
    /// the sheet stays open (bugbot "iOS search chat snapshot stale"). Defaulted
    /// so previews / tests that don't track the list keep compiling.
    var liveChats: [ChatSummary] = []

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
                            onTap: { onSelectMessage(group, viewModel.trimmedQuery) }
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
        .onChange(of: liveChats) { _, chats in
            viewModel.updateChats(chats)
        }
        .navigationTitle("Search")
    }
}
