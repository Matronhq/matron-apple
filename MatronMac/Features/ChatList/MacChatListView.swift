import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// Mac chat-list screen — the sidebar column of a `NavigationSplitView`
/// hosting a placeholder detail column until Task 14c lands `MacChatView`.
///
/// Selection is held as a `ChatSummary?` (rather than just the id) so the
/// detail column has the full row data — title, bot identity, last
/// activity — without re-querying the view-model. List-selection in
/// SwiftUI on Mac binds to a `Hashable` value; `ChatSummary` was made
/// `Hashable` in Task 13.
///
/// Right-click context menu surfaces Mute + Leave (the Mac analogue of
/// iOS long-press). `.refreshable` is reachable from the keyboard via
/// `⌘R` once Task 14e wires the menu bar; until then the gesture itself
/// is reachable on the trackpad. Hover tint state is held locally on
/// each `MacChatRow` so it doesn't muddy the view-model.
struct MacChatListView: View {
    @State var viewModel: ChatListViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var selectedSummary: ChatSummary?
    @State private var showingNewChat = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingNewChat = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New chat")
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
        } detail: {
            detail
        }
        .navigationTitle("Matron")
        .sheet(isPresented: $showingNewChat) {
            // Task 14 lands the real `NewChatSheet`. Until then the sheet
            // shows a small placeholder so the toolbar wiring is testable.
            MacNewChatPlaceholder(onDismiss: { showingNewChat = false })
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
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
            List(selection: $selectedSummary) {
                ForEach(viewModel.groups) { group in
                    Section(group.group.rawValue) {
                        ForEach(group.summaries) { summary in
                            MacChatRow(summary: summary)
                                .tag(summary)
                                .contextMenu {
                                    Button("Mute") {
                                        runChatAction { try await $0.mute(roomID: summary.id) }
                                    }
                                    Button("Leave", role: .destructive) {
                                        runChatAction { try await $0.leave(roomID: summary.id) }
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .refreshable {
                await runChatActionAwaiting { try await $0.refresh() }
            }
        }
    }

    /// Detail column. Task 14c lands `MacChatView`; until then we render
    /// either a "select a chat" placeholder or a "selected chat" header so
    /// selection wiring is observable without the chat view itself.
    @ViewBuilder
    private var detail: some View {
        if let summary = selectedSummary {
            MacChatDetailPlaceholder(summary: summary)
        } else {
            ContentUnavailableView(
                "Select a chat",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Pick a conversation from the sidebar.")
            )
        }
    }

    private func runChatAction(_ action: @escaping (ChatService) async throws -> Void) {
        guard let deps, let session else { return }
        let chat = deps.chatService(for: session)
        Task { try? await action(chat) }
    }

    private func runChatActionAwaiting(_ action: @escaping (ChatService) async throws -> Void) async {
        guard let deps, let session else { return }
        let chat = deps.chatService(for: session)
        try? await action(chat)
    }
}

/// Row view with hover-tint state held locally so it doesn't muddy the
/// view-model. Keeps the same column composition as the iOS row but with
/// Mac-appropriate sizing (28pt avatar vs 36pt on iPhone).
private struct MacChatRow: View {
    let summary: ChatSummary
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.secondary.opacity(0.2)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    Text(summary.bot.displayName).font(.caption).foregroundStyle(.secondary)
                    if let lastActivity = summary.lastActivity {
                        Text("·").foregroundStyle(.secondary)
                        Text(lastActivity, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if summary.unreadCount > 0 {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.gray.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Phase 2 detail-column placeholder. Task 14c replaces this with
/// `MacChatView(viewModel:composerVM:chatTitle:onShowBotProfile:)`. The
/// placeholder still constructs the per-room `TimelineService` /
/// `MediaService` so the cache priming and selection contract are
/// exercised end-to-end before the chat view itself lands.
private struct MacChatDetailPlaceholder: View {
    let summary: ChatSummary
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session

    var body: some View {
        VStack(spacing: 8) {
            Text(summary.title).font(.title2)
            Text(summary.bot.displayName).font(.caption).foregroundStyle(.secondary)
            Text("Mac chat view — Task 14c lands the timeline + composer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Prime the per-room caches so navigating in/out of this room is
        // free of network churn once Task 14c hooks the real view in.
        .task(id: summary.id) {
            guard let deps, let session else { return }
            _ = deps.timelineService(for: session, roomID: summary.id)
            _ = deps.mediaService(for: session)
        }
    }
}

/// Phase 2 placeholder for the `+` toolbar button's sheet. Task 14 lands
/// the real `NewChatSheet`. Replacing the body in Task 14 is a one-line
/// swap once the iOS sheet is shared cross-platform.
private struct MacNewChatPlaceholder: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("New chat — Task 14").font(.headline)
            Text("Bot picker lands in Task 14.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Dismiss", action: onDismiss)
        }
        .padding(40)
        .frame(width: 320)
    }
}
