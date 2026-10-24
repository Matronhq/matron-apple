import SwiftUI
import MatronSearch
import MatronChat       // ChatSummary
import MatronModels
import MatronViewModels
import MatronDesignSystem  // SearchResultRow

/// Mac search results panel. Replaces the chat detail column while the toolbar
/// search field has a non-empty query. Renders the same layout as iOS
/// `SearchView` (a number's row, then Chats / Messages) using the shared
/// `SearchViewModel` + `SearchResultRow`, so the two platforms can't drift
/// on snippet rendering.
struct MacSearchResultsView: View {
    @Bindable var viewModel: SearchViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onSelectMessage: (SearchChatHit) -> Void
    /// The row for a query that is a number (`#412`): opens what it names,
    /// as the Search page does.
    var onSelectNumber: ((GoToNumberHit) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            if let hit = viewModel.numberHit, let onSelectNumber {
                Section("Go to") {
                    Button { onSelectNumber(hit) } label: {
                        Label(hit.label, systemImage: "number")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search.number-hit")
                }
            }
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
                            hit: group.topHit,
                            chatTitle: line.title,
                            sessionShort: line.sessionShort,
                            boxLetter: line.boxLetter,
                            boxName: line.boxName,
                            roomBoxNames: line.roomBoxNames,
                            roomBoxShorts: line.roomBoxShorts,
                            subChatTitle: line.subChatTitle,
                            senderLabel: viewModel.senderLabel(for: group.topHit),
                            matchCount: group.count,
                            onTap: { onSelectMessage(group) }
                        )
                    }
                }
            }
            if viewModel.hasNoResults && !viewModel.isSearching {
                Section { Text(viewModel.emptyResultsMessage).foregroundStyle(.secondary) }
            }
        }
    }
}
