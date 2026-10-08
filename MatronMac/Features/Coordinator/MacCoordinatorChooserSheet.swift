import SwiftUI
import AppKit
import MatronChat
import MatronModels
import MatronViewModels

/// Mac chooser for the coordinator conversation (app shell, spec §5b):
/// the chat-list rows with a search field on top — and, for a user with
/// two or more boxes, the project page's box chips under it — plus "New
/// coordinator chat…" which runs the existing New Chat sheet and stores
/// the result.
/// Owns its own `ChatListViewModel` so Settings (a separate scene with no
/// list) can present it. Pinned desk chats reuse it for "Move pin…" and
/// Settings → Pinned chats → Add, with their own heading, without the
/// new-chat row, and leaving out the chats that cannot be picked there.
struct MacCoordinatorChooserSheet: View {
    let deps: AppDependencies
    let session: UserSession
    var heading = "Choose the coordinator conversation"
    /// The top row's label; `nil` drops the row.
    var newChatLabel: String? = "New coordinator chat…"
    /// Conversations the list leaves out.
    var excluding: Set<String> = []
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ChatListViewModel
    @State private var query = ""
    /// The box the list is narrowed to (a click on its chip).
    @State private var selectedBox: String?
    @State private var showingNewChat = false

    init(deps: AppDependencies, session: UserSession, heading: String = "Choose the coordinator conversation",
         newChatLabel: String? = "New coordinator chat…", excluding: Set<String> = [],
         onPick: @escaping (String) -> Void) {
        self.deps = deps
        self.session = session
        self.heading = heading
        self.newChatLabel = newChatLabel
        self.excluding = excluding
        self.onPick = onPick
        _viewModel = State(initialValue: ChatListViewModel(chat: deps.chatService(for: session)))
    }

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
        VStack(spacing: 12) {
            Text(heading).font(.headline)
            TextField("Search conversations", text: $query)
                .textFieldStyle(.roundedBorder)
            if ChatBoxFilter.shows(counts) {
                MacProjectBoxFilter(counts: counts, selected: box, enabled: true) { selectedBox = $0 }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List {
                if let newChatLabel {
                    Button {
                        showingNewChat = true
                    } label: {
                        Label(newChatLabel, systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                }
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
                ForEach(chats) { summary in
                    Button { onPick(summary.id) } label: { MacChatRow(summary: summary) }
                        .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 480, height: 500)
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
        .sheet(isPresented: $showingNewChat) {
            MacNewChatSheet(deps: deps, session: session,
                            windowSize: NSApp.keyWindow?.contentLayoutRect.size,
                            pinnedModel: CoordinatorSetting.newChatModel) { convoID in
                showingNewChat = false
                onPick(convoID)
            }
        }
    }
}

/// "No Coordinator yet": the Coordinator page's empty state, offering the
/// chooser.
struct MacCoordinatorChooserPrompt: View {
    let onChoose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Coordinator", systemImage: MacNav.coordinator.symbol)
        } description: {
            Text("Pick the conversation that hands out your work as missions.")
        } actions: {
            Button("Choose a conversation…", action: onChoose)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }
}
