import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// Picks the coordinator conversation (app shell, spec §5b): the user's
/// existing conversations (the chat-list rows, search box on top) plus a
/// "New coordinator chat…" row that runs the existing New Chat flow and
/// stores the resulting id. Owns its own `ChatListViewModel` so it can be
/// presented from Settings, which has no list of its own.
struct CoordinatorChooserSheet: View {
    let deps: AppDependencies
    let session: UserSession
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChatListViewModel
    @State private var query = ""
    @State private var showingNewChat = false

    init(deps: AppDependencies, session: UserSession, onPick: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.onPick = onPick
        _viewModel = State(initialValue: ChatListViewModel(chat: deps.chatService(for: session)))
    }

    /// Title match, case-insensitive, whitespace-trimmed; an empty query
    /// keeps every chat. Static so it's unit-testable without rendering.
    static func filtered(_ chats: [ChatSummary], query: String) -> [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var chats: [ChatSummary] {
        Self.filtered(viewModel.groups.flatMap(\.summaries), query: query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingNewChat = true
                    } label: {
                        Label("New coordinator chat…", systemImage: "square.and.pencil")
                    }
                }
                Section("Conversations") {
                    if viewModel.isLoading {
                        ProgressView()
                    } else if chats.isEmpty {
                        Text("No conversations match.").foregroundStyle(.secondary)
                    }
                    ForEach(chats) { summary in
                        Button { onPick(summary.id) } label: { ChatRow(summary: summary) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.primary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search conversations")
            .navigationTitle("Coordinator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { viewModel.start() }
            .onDisappear { viewModel.cancel() }
            .sheet(isPresented: $showingNewChat) {
                NewChatSheet(deps: deps, session: session) { convoID in
                    showingNewChat = false
                    onPick(convoID)
                }
            }
        }
    }
}
