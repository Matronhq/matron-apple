import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

struct ChatListView: View {
    @State var viewModel: ChatListViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("Connecting…")
                } else if viewModel.groups.isEmpty {
                    ContentUnavailableView(
                        "No chats yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Provision a bot via dev-boxer to get started.")
                    )
                } else {
                    List {
                        ForEach(viewModel.groups) { group in
                            Section(group.group.rawValue) {
                                ForEach(group.summaries) { summary in
                                    ChatRow(summary: summary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Matron")
            .task { viewModel.start() }
            .onDisappear { viewModel.cancel() }
        }
    }
}

private struct ChatRow: View {
    let summary: ChatSummary

    var body: some View {
        HStack {
            Circle().fill(.secondary.opacity(0.2)).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body)
                Text(summary.bot.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let lastActivity = summary.lastActivity {
                Text(lastActivity, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if summary.unreadCount > 0 {
                Circle().fill(.blue).frame(width: 8, height: 8)
            }
        }
    }
}
