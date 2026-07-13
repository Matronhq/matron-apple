import SwiftUI
import UserNotifications
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronSearch
import MatronSync
import MatronViewModels

/// iOS chat-list screen. Phase 2 wires `NavigationLink(value:)` rows that
/// push a `ChatView` via `navigationDestination(for: ChatSummary.ID.self)`.
/// The hosting `NavigationStack` lives in `MatronApp` so the environment
/// values (`appDependencies`, `currentSession`) propagate into the
/// destination column.
///
/// The destination value is the `ChatSummary.ID` (a stable `String`), not
/// the full `ChatSummary` struct. `ChatSummary` auto-synthesises
/// `Hashable` from *all* stored properties — including `lastActivity`
/// and `unreadCount` — so a destination keyed on the struct receives a
/// snapshot frozen at navigation time. When the underlying snapshot
/// updates (a new message arrives, unread count changes), the pushed
/// destination still holds the stale struct. Mirrors the round-3 fix to
/// `MacChatListView` (`currentSummary(for:)`): the destination looks up
/// the current `ChatSummary` from `viewModel.groups` by id.
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
    /// Phase 6 (Search): drives the `.sheet` presenting `SearchView`.
    @State private var showingSearch = false
    /// The chat whose ⓘ button was tapped. Setting this drives the
    /// `.sheet(item:)` presentation of `BotProfileView`. Cleared back to
    /// `nil` either by the sheet's onDismiss or when the user picks a chat
    /// from inside the sheet.
    @State private var botProfileSummary: ChatSummary?
    /// Settings → Device sheet visibility.
    @State private var showingDeviceSettings = false
    /// Sign-out callback owned by `MatronApp` (drops the in-memory session
    /// + clears persistent state). Optional so previews / tests that
    /// don't wire the full app can still construct the view. Phase-7
    /// spec lands a Settings → Account → Sign Out flow; this Phase-2
    /// hook keeps the user from being stranded once Sign Out is exposed
    /// from the menu (QA finding #7).
    var onSignOut: (() -> Void)? = nil
    /// Phase 6 (Search): opens a room by ID. Owned by `MatronApp` (it holds the
    /// `NavigationStack` path); wired so a search result can navigate to its
    /// chat after the search sheet dismisses. Optional so previews / tests
    /// without the full nav stack still construct the view.
    var onOpenChat: ((String) -> Void)? = nil
    /// Latest user-facing connection state, fed by the host's
    /// `SyncService.stateStream()`. `.running` hides the banner;
    /// `.connecting` / `.offline` render it. Drives
    /// `ConnectionStatusBanner` directly — no async glue inside the
    /// View, just a `@State` mirror of the upstream stream.
    @State private var connectionState: SyncBannerState = .connecting
    /// Tracks whether sliding sync has ever been observed `.running` in
    /// this session, so the banner can pick "Connecting…" vs
    /// "Reconnecting…" for the connecting state. Sticky once true —
    /// resets only when the View itself remounts (e.g. sign-out + back-in).
    @State private var hasEverConnected: Bool = false

    /// Flattened chat-list snapshot. Hoisted into a typed property so the large
    /// `body` doesn't infer the `flatMap` result inline (keeps the Xcode 16.4
    /// type-checker under its budget) and so the search sheet's seed + live
    /// refresh share one source.
    private var allChatSummaries: [ChatSummary] {
        viewModel.groups.flatMap(\.summaries)
    }

    var body: some View {
        chatListColumn
        .navigationTitle("Matron")
        .toolbar {
            // Phase 6 (Search): leading search button → SearchView sheet. Only
            // shown when the index is available (deps.search non-nil).
            if deps?.search != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewChat = true } label: { Image(systemName: "square.and.pencil") }
            }
            // Sign-out lives in an overflow menu next to the New-Chat
            // button until Phase 7 ships the full Settings UI. Without
            // this hook the only way to swap accounts on iOS was
            // deleting the app's Application Support directory (QA
            // finding #7). The menu only renders when the host wired
            // an `onSignOut` callback so previews / tests stay clean.
            if let onSignOut {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Settings sits above Sign Out so the destructive
                        // action stays at the bottom of the menu (iOS HIG
                        // — destructive actions live last). Hidden when
                        // the host doesn't wire `deps` / `session` so
                        // tests / previews stay clean.
                        if deps != nil, session != nil {
                            Button {
                                showingDeviceSettings = true
                            } label: {
                                Label("Settings", systemImage: "gear")
                            }
                        }
                        Button("Sign Out", role: .destructive, action: onSignOut)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
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
        .sheet(isPresented: $showingDeviceSettings) {
            // Settings → Device. Wraps `DeviceSettingsView` in a
            // `NavigationStack` so the navigationTitle renders + the
            // sheet has a Done button.
            if let session {
                NavigationStack {
                    DeviceSettingsView(session: session)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showingDeviceSettings = false }
                            }
                        }
                }
            } else {
                Text("Settings unavailable")
                    .padding()
            }
        }
        .sheet(isPresented: $showingSearch) {
            // Phase 6 (Search): dedicated two-section search screen. Built with
            // the current chat-list snapshot so chat (title/bot) hits resolve
            // without another fetch. Selecting a result dismisses the sheet and
            // routes through `onOpenChat` (MatronApp owns the nav path).
            if let deps, let search = deps.search {
                NavigationStack {
                    SearchView(
                        viewModel: SearchViewModel(
                            search: search,
                            allChats: allChatSummaries
                        ),
                        onSelectChat: { chat in
                            showingSearch = false
                            onOpenChat?(chat.id)
                        },
                        onSelectMessage: { hit in
                            // Opens the hit's room. Precise scroll-to-event
                            // (focused-timeline) is a Phase 6 follow-up — see
                            // the search plan's jump-to-message note.
                            showingSearch = false
                            onOpenChat?(hit.roomID)
                        },
                        // Keep `allChats` fresh while the sheet is open — the VM
                        // is `@State` inside SearchView and freezes otherwise
                        // (bugbot "iOS search chat snapshot stale").
                        liveChats: allChatSummaries
                    )
                }
            }
        }
        .navigationDestination(for: ChatSummary.ID.self) { id in
            chatDestination(for: id)
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
        // Sync connection-state banner. Subscribes to the host's
        // long-lived `stateStream()` and mirrors yields into the local
        // `connectionState` so the banner reacts without bouncing
        // through the ViewModel. Keying on `session?.userID` so a
        // user-switch (sign out + sign back in) recycles the iterator
        // against the new session's sync service. The async-let pattern
        // here matches the verification-center observation in
        // `MatronApp` (one .task per long-lived async loop).
        .task(id: session?.userID) {
            guard let deps, let session else { return }
            let sync = deps.syncService(for: session)
            for await state in await sync.stateStream() {
                connectionState = .from(state)
                if state == .running { hasEverConnected = true }
            }
        }
        // App-icon badge mirrors the chat list's running unread total.
        // No `initial: true` — on cold start `totalUnread` is 0
        // before sync delivers the first snapshot, and firing the
        // badge update with that 0 would actively clear any badge
        // a push notification (Phase 4 NSE) had set while the app
        // was backgrounded. Letting the closure run only on actual
        // changes means we'll write the right count once the chat
        // list lands its first real snapshot, and we'll keep
        // tracking decrements as the user reads rooms after that.
        .onChange(of: viewModel.totalUnread) { _, newValue in
            UNUserNotificationCenter.current().setBadgeCount(newValue) { _ in }
        }
    }

    /// Column wrapper: when the connection-state banner is visible, stack
    /// it above the existing chat-list content. Empty / no-banner case
    /// falls straight through to `chatListContent` so the loading
    /// `ProgressView` keeps its full-screen vertical centering — wrapping
    /// the content in a top-down `VStack` unconditionally (the prior
    /// shape) collapsed the progress view to the top of the column.
    /// Mirrors `MacChatListView.sidebarColumn`.
    @ViewBuilder
    private var chatListColumn: some View {
        let showConnection = (connectionState != .running)
        if showConnection {
            VStack(spacing: 0) {
                // Connection-state banner sits at the very top so the
                // user's first read of the list is "what's the current
                // sync status?" before anything else competes for
                // attention. Hides on `.running` via the inner switch
                // (returns EmptyView). Animates in/out so the banner
                // doesn't snap.
                ConnectionStatusBanner(
                    state: connectionState,
                    hasEverConnected: hasEverConnected
                )
                .animation(.easeInOut(duration: 0.2), value: connectionState)
                chatListContent
            }
        } else {
            chatListContent
        }
    }

    /// Extracted to keep `body` readable now that the connection-state
    /// banner sits above this list. Same render branches as before —
    /// loading / error / empty / populated — just lifted out.
    @ViewBuilder
    private var chatListContent: some View {
        if viewModel.isLoading {
            ProgressView("Connecting…")
        } else if let errorMessage = viewModel.error, viewModel.groups.isEmpty {
            // QA finding #10: surface upstream stream failures
            // (e.g. `SyncReadyError.timeout`) instead of leaving
            // the user staring at an empty list. If we have a prior
            // good snapshot we keep showing it (the banner above
            // would render too) — this branch only handles the
            // first-load failure case.
            ContentUnavailableView(
                "Couldn't load chats",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
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
                            // Navigate by id (stable `String`), not the
                            // full struct — see file header for the
                            // stale-capture rationale.
                            NavigationLink(value: summary.id) {
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
                // Phase 2.5: pull-to-refresh drives a one-shot
                // `client.rooms()` snapshot through the live broadcaster
                // pipe via `ChatListViewModel.refresh()` →
                // `ChatService.forceSnapshot()`. Pre-2.5 this called
                // `chat.refresh()`, a `sync.waitUntilReady()` no-op once
                // running, so the gesture was purely cosmetic.
                await viewModel.refresh()
            }
        }
    }

    /// Builds the `ChatView` destination for a tapped row. Wrapped in a
    /// helper so `body` stays readable and the `nil`-environment branch
    /// doesn't leak SwiftUI conditional-content quirks into the main flow.
    ///
    /// Resolves the destination's `ChatSummary` from `viewModel.groups`
    /// by id rather than capturing it at navigation time — see the file
    /// header for the stale-capture rationale. The lookup can legitimately
    /// return `nil` for a valid, open room: a conversation the bridge just
    /// created (`/start`) auto-opens the instant its first frame hits the
    /// store, but the chat-list snapshot arrives a GRDB `ValueObservation`
    /// main-hop later — so `currentSummary` is briefly `nil` for a room
    /// that is very much live. We therefore build the `ChatView` for any
    /// valid id whenever the session is present; the title falls back to
    /// empty and fills in live when the snapshot lands (the `ChatView`'s
    /// `@State` view models and the roomID-keyed timeline persist across
    /// that re-render). The `Session unavailable` placeholder is reserved
    /// for the case its copy actually describes — no session / signed out.
    @ViewBuilder
    func chatDestination(for id: ChatSummary.ID) -> some View {
        if let deps, let session {
            let summary = currentSummary(for: id)
            let timelineSvc = deps.timelineService(for: session, roomID: id)
            let mediaSvc = deps.mediaService(for: session)
            let chatVM = ChatViewModel(roomID: id, timeline: timelineSvc, media: mediaSvc)
            let composerVM = ComposerViewModel(roomID: id, timeline: timelineSvc, commands: BotCommandCatalog.claudeBridge)
            ChatView(
                viewModel: chatVM,
                composerVM: composerVM,
                chatTitle: summary?.title ?? "",
                onShowBotProfile: { if let summary { botProfileSummary = summary } }
            )
        } else {
            ContentUnavailableView(
                "Session unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Sign in again to open this chat.")
            )
        }
    }

    /// Looks up the current `ChatSummary` for a navigation id across all
    /// groups. Returns `nil` when the room has been removed from the
    /// latest snapshot (e.g. user left from another device while the
    /// destination was on screen). Re-evaluated on every
    /// `viewModel.groups` change because `@Observable` triggers `body`
    /// re-render — so the destination always reflects the latest summary
    /// fields (title, unread count, last activity) without holding the
    /// stale value frozen at navigation time. Mirrors
    /// `MacChatListView.currentSummary(for:)`.
    func currentSummary(for id: ChatSummary.ID) -> ChatSummary? {
        for group in viewModel.groups {
            if let match = group.summaries.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
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

}

private struct ChatRow: View {
    let summary: ChatSummary

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.body).lineLimit(1)
                if !summary.snippet.isEmpty {
                    Text(summary.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let lastActivity = summary.lastActivity {
                RelativeMinuteTimeView(lastActivity)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            UnreadBadge(count: summary.unreadCount)
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
