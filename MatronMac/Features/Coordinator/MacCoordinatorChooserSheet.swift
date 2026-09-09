import SwiftUI
import AppKit
import MatronChat
import MatronModels
import MatronViewModels

/// Mac chooser for the coordinator conversation (app shell, spec §5b):
/// the chat-list rows with a search field on top, plus "New coordinator
/// chat…" which runs the existing New Chat sheet and stores the result.
/// Owns its own `ChatListViewModel` so Settings (a separate scene with no
/// list) can present it.
struct MacCoordinatorChooserSheet: View {
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

    static func filtered(_ chats: [ChatSummary], query: String) -> [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    private var chats: [ChatSummary] {
        Self.filtered(viewModel.groups.flatMap(\.summaries), query: query)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Choose the coordinator conversation").font(.headline)
            TextField("Search conversations", text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                Button {
                    showingNewChat = true
                } label: {
                    Label("New coordinator chat…", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
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
        .frame(width: 480, height: 460)
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
        .sheet(isPresented: $showingNewChat) {
            MacNewChatSheet(deps: deps, session: session,
                            windowSize: NSApp.keyWindow?.contentLayoutRect.size) { convoID in
                showingNewChat = false
                onPick(convoID)
            }
        }
    }
}
