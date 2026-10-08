import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// Picks the coordinator conversation (app shell, spec §5b): the user's
/// existing conversations (the chat-list rows, search box on top, and a
/// Box picker for a user with two or more boxes) plus a
/// "New coordinator chat…" row that runs the existing New Chat flow and
/// stores the resulting id. Owns its own `ChatListViewModel` so it can be
/// presented from Settings, which has no list of its own. Pinned desk
/// chats reuse it for "Move pin…" and Settings → Pinned chats → Add, with
/// their own title, without the new-chat row, and leaving out the chats
/// that cannot be picked there.
struct CoordinatorChooserSheet: View {
    let deps: AppDependencies
    let session: UserSession
    var title = "Coordinator"
    /// The top row's label; `nil` drops the row.
    var newChatLabel: String? = "New coordinator chat…"
    /// Conversations the list leaves out.
    var excluding: Set<String> = []
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChatListViewModel
    @State private var query = ""
    /// The box the list is narrowed to; nil shows every box.
    @State private var selectedBox: String?
    @State private var showingNewChat = false

    init(deps: AppDependencies, session: UserSession, title: String = "Coordinator",
         newChatLabel: String? = "New coordinator chat…", excluding: Set<String> = [],
         onPick: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.title = title
        self.newChatLabel = newChatLabel
        self.excluding = excluding
        self.onPick = onPick
        _viewModel = State(initialValue: ChatListViewModel(chat: deps.chatService(for: session)))
    }

    /// Title match, case-insensitive, whitespace-trimmed (an empty query
    /// keeps every chat), on `box` when one is picked. Static so it's
    /// unit-testable without rendering.
    static func filtered(_ chats: [ChatSummary], query: String, box: String? = nil) -> [ChatSummary] {
        ChatBoxFilter.filtered(chats, query: query, box: box)
    }

    /// Every conversation that can be picked, before search and box.
    private var candidates: [ChatSummary] {
        viewModel.groups.flatMap(\.summaries).filter { !excluding.contains($0.id) }
    }

    var body: some View {
        let candidates = candidates
        let counts = ChatBoxFilter.counts(candidates)
        let box = ChatBoxFilter.activeBox(selectedBox, in: counts)
        let chats = Self.filtered(candidates, query: query, box: box)
        NavigationStack {
            List {
                if let newChatLabel {
                    Section {
                        Button {
                            showingNewChat = true
                        } label: {
                            Label(newChatLabel, systemImage: "square.and.pencil")
                        }
                    }
                }
                if ChatBoxFilter.shows(counts) {
                    Section {
                        Picker("Box", selection: Binding(get: { box }, set: { selectedBox = $0 })) {
                            Text("All boxes").tag(String?.none)
                            ForEach(counts, id: \.box) { count in
                                Text("\(count.box) (\(count.count))").tag(String?.some(count.box))
                            }
                        }
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { viewModel.start() }
            .onDisappear { viewModel.cancel() }
            .sheet(isPresented: $showingNewChat) {
                NewChatSheet(deps: deps, session: session, pinnedModel: CoordinatorSetting.newChatModel) { convoID in
                    showingNewChat = false
                    onPick(convoID)
                }
            }
        }
    }
}
