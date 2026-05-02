import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

struct MacChatListView: View {
    @State var viewModel: ChatListViewModel
    @State private var selectedChat: ChatSummary.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Matron")
        .task { viewModel.start() }
    }

    @ViewBuilder
    private var sidebar: some View {
        if viewModel.isLoading {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.groups.isEmpty {
            ContentUnavailableView(
                "No chats yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Provision a bot via dev-boxer to get started.")
            )
        } else {
            List(selection: $selectedChat) {
                ForEach(viewModel.groups) { group in
                    Section(group.group.rawValue) {
                        ForEach(group.summaries) { summary in
                            MacChatRow(summary: summary)
                                .tag(summary.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        // Phase 2 replaces this with MacChatView(roomID: selectedChat).
        VStack {
            Spacer()
            Text(selectedChat == nil ? "Select a chat" : "Chat detail — Phase 2")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MacChatRow: View {
    let summary: ChatSummary

    var body: some View {
        HStack {
            Circle().fill(.secondary.opacity(0.2)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body)
                Text(summary.bot.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(summary.lastActivity, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if summary.unreadCount > 0 {
                Circle().fill(.blue).frame(width: 6, height: 6)
            }
        }
    }
}
