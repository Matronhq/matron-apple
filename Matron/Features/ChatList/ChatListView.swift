import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// iOS chat-list screen. Phase 2 wires `NavigationLink(value:)` rows that
/// push a `ChatView` via `navigationDestination(for: ChatSummary.self)`.
/// The hosting `NavigationStack` lives in `MatronApp` so the environment
/// values (`appDependencies`, `currentSession`) propagate into the
/// destination column.
///
/// Long-press / swipe context menu surfaces Mute + Leave actions wired to
/// `ChatService.mute(roomID:)` / `.leave(roomID:)`. Pull-to-refresh hits
/// `ChatService.refresh()` which makes the next room-list snapshot
/// re-sync. The `+` toolbar button's sheet binding is in place but the
/// `NewChatSheet` itself lands in Task 14.
struct ChatListView: View {
    @State var viewModel: ChatListViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var showingNewChat = false
    /// The chat whose ⓘ button was tapped. Setting this drives the
    /// `.sheet(item:)` presentation of `BotProfileView`. Cleared back to
    /// `nil` either by the sheet's onDismiss or when the user picks a chat
    /// from inside the sheet.
    @State private var botProfileSummary: ChatSummary?

    var body: some View {
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
                                NavigationLink(value: summary) {
                                    ChatRow(summary: summary)
                                }
                                .contextMenu {
                                    Button {
                                        runChatAction { try await $0.mute(roomID: summary.id) }
                                    } label: {
                                        Label("Mute", systemImage: "bell.slash")
                                    }
                                    Button(role: .destructive) {
                                        runChatAction { try await $0.leave(roomID: summary.id) }
                                    } label: {
                                        Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await runChatActionAwaiting { try await $0.refresh() }
                }
            }
        }
        .navigationTitle("Matron")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewChat = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showingNewChat) {
            // `deps` / `session` come from the environment so the sheet
            // body is conditional. Without either we render the original
            // placeholder so the toolbar button is still observable in
            // tests / previews where the environment isn't injected.
            if let deps, let session {
                NewChatSheet(deps: deps, session: session) { _ in
                    showingNewChat = false
                }
            } else {
                NewChatPlaceholder(onDismiss: { showingNewChat = false })
            }
        }
        .sheet(item: $botProfileSummary) { summary in
            // Snapshot the current grouped summaries flat-list — the
            // BotProfileViewModel filters by bot.matrixID at construction.
            // Re-opening the sheet picks up a fresh snapshot from the
            // groups state at that moment.
            let allSummaries = viewModel.groups.flatMap(\.summaries)
            let bpVM = BotProfileViewModel(bot: summary.bot, allSummaries: allSummaries)
            BotProfileView(
                viewModel: bpVM,
                onSelectChat: { _ in
                    // Phase-2 simply closes the sheet; in-sheet navigation
                    // to a different chat with the same bot is a Phase-3
                    // task. The user's already inside *some* chat with the
                    // bot, so dismissing returns them there.
                    botProfileSummary = nil
                },
                onStartNewChat: {
                    botProfileSummary = nil
                    showingNewChat = true
                }
            )
        }
        .navigationDestination(for: ChatSummary.self) { summary in
            chatDestination(for: summary)
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    /// Builds the `ChatView` destination for a tapped row. Wrapped in a
    /// helper so `body` stays readable and the `nil`-environment branch
    /// doesn't leak SwiftUI conditional-content quirks into the main flow.
    @ViewBuilder
    private func chatDestination(for summary: ChatSummary) -> some View {
        if let deps, let session {
            let timelineSvc = deps.timelineService(for: session, roomID: summary.id)
            let mediaSvc = deps.mediaService(for: session)
            let chatVM = ChatViewModel(roomID: summary.id, timeline: timelineSvc, media: mediaSvc)
            let composerVM = ComposerViewModel(timeline: timelineSvc, commands: BotCommandCatalog.claudeBridge)
            ChatView(
                viewModel: chatVM,
                composerVM: composerVM,
                chatTitle: summary.title,
                onShowBotProfile: { botProfileSummary = summary }
            )
        } else {
            ContentUnavailableView(
                "Session unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Sign in again to open this chat.")
            )
        }
    }

    /// Fires a chat-service action without awaiting its result. Used for
    /// row context-menu items where the UI doesn't need to block on the
    /// network response — Mute/Leave optimistically dismiss the menu and
    /// the next sync snapshot reflects the change.
    private func runChatAction(_ action: @escaping (ChatService) async throws -> Void) {
        guard let deps, let session else { return }
        let chat = deps.chatService(for: session)
        Task { try? await action(chat) }
    }

    /// Awaiting variant for `.refreshable`, which expects an `async`
    /// closure so it can spin its progress indicator until completion.
    private func runChatActionAwaiting(_ action: @escaping (ChatService) async throws -> Void) async {
        guard let deps, let session else { return }
        let chat = deps.chatService(for: session)
        try? await action(chat)
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

/// Phase 2 placeholder for the `+` toolbar button's sheet. Task 14 lands
/// the real `NewChatSheet`. Keeping the binding in place now means the
/// sheet wiring is testable end-to-end; replacing the body in Task 14 is
/// a one-line swap.
private struct NewChatPlaceholder: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("New chat — Task 14")
                .font(.headline)
            Text("Bot picker lands in Task 14.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Dismiss", action: onDismiss)
        }
        .padding(40)
    }
}
