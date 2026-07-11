import SwiftUI
import AppKit
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronSearch
import MatronSync
import MatronViewModels

/// Mac chat-list screen — the sidebar column of a `NavigationSplitView`
/// hosting a placeholder detail column until Task 14c lands `MacChatView`.
///
/// Selection is held as a `ChatSummary.ID` (a `String`) so the binding
/// survives snapshot updates. Phase 1 used the id; Phase 2 / Task 13c
/// briefly switched to the full `ChatSummary` struct, but `ChatSummary`
/// auto-synthesises `Hashable` from *all* stored properties — including
/// `lastActivity` and `unreadCount` — so any new snapshot with updated
/// values for those fields produced a `ChatSummary` whose hash didn't
/// match the stored selection, silently breaking the binding (round-3
/// bugbot finding #6). The id is a stable `String`, so re-selecting the
/// same room across snapshots works as long as the row exists. The
/// detail column looks up the full `ChatSummary` from `viewModel.groups`
/// when it needs the bot identity / title.
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
    @State private var selectedSummaryID: ChatSummary.ID?
    @State private var showingNewChat = false
    /// Phase 6 (Search): the shared search VM, built once the session + index
    /// resolve and the chat list has loaded (so chat-title hits have a snapshot).
    /// A non-empty `searchModel.query` swaps the detail column for
    /// `MacSearchResultsView`. `focusSearch` is flipped by ⌘F ("Find in Chat").
    @State private var searchModel: SearchViewModel?
    @State private var focusSearch = false
    /// The chat whose ⓘ button was tapped. Drives the
    /// `.sheet(item: $botProfileSummary)` presentation of
    /// `MacBotProfileSheet`. Cleared by the sheet's onDismiss / row tap /
    /// "Start new chat" callbacks.
    @State private var botProfileSummary: ChatSummary?
    /// Sidebar visibility toggle — wired to `.matronCommand(.toggleSidebar)`
    /// so the menu-bar item / toolbar button / ⌘⇧S keyboard shortcut all
    /// flip the same state. `.automatic` is the system default (sidebar
    /// shown); `.detailOnly` collapses it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Sign-out callback owned by `MatronMacApp`. Invoked by the
    /// `.onReceive(.signOut)` listener (this view is the active branch
    /// any time the user is signed in, so anchoring the listener here
    /// is reliable — the prior WindowGroup-root anchor silently dropped
    /// notifications when the `Group { … }`'s active branch changed
    /// type, which is what made File → Sign Out a no-op on macOS —
    /// Wave 6 / live-test #1).
    var onSignOut: (() -> Void)? = nil
    /// Latest user-facing connection state, fed by the host's
    /// `SyncService.stateStream()`. `.running` hides the banner;
    /// `.connecting` / `.offline` render it. Drives
    /// `ConnectionStatusBanner` directly — no async glue inside the
    /// View, just a `@State` mirror of the upstream stream.
    @State private var connectionState: SyncBannerState = .connecting
    /// Tracks whether sliding sync has ever been observed `.running` in
    /// this session, so the banner can pick "Connecting…" vs
    /// "Reconnecting…" copy. Sticky once true.
    @State private var hasEverConnected: Bool = false

    /// Flattened chat-list snapshot, used to seed and refresh the search VM.
    /// Hoisted into a typed property so the large `body` doesn't infer the
    /// `flatMap` result inline — that tipped the Xcode 16.4 type-checker over
    /// its time budget once the search-refresh `.onChange` was added.
    private var allChatSummaries: [ChatSummary] {
        viewModel.groups.flatMap(\.summaries)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
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
            if let searchModel, !searchModel.query.isEmpty {
                // Phase 6 (Search): a non-empty query replaces the chat detail
                // with the results panel. Selecting a result clears the query
                // (restoring the chat detail) and points the sidebar selection
                // at the chosen room.
                MacSearchResultsView(
                    viewModel: searchModel,
                    onSelectChat: { chat in
                        selectedSummaryID = chat.id
                        searchModel.query = ""
                    },
                    onSelectMessage: { hit in
                        // Opens the hit's room. Precise scroll-to-event
                        // (focused-timeline) is a Phase 6 follow-up — same scope
                        // as iOS jump-to-message.
                        selectedSummaryID = hit.roomID
                        searchModel.query = ""
                    }
                )
            } else {
                detail
            }
        }
        // Phase 6 (Search): the search field lives in the window toolbar at the
        // split-view level so it persists when the results panel replaces the
        // chat detail. ⌘F ("Find in Chat") focuses it via `focusSearch`.
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let searchModel {
                    MacSearchView(viewModel: searchModel, focusRequest: $focusSearch)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.findInChat))) { _ in
            focusSearch = true
        }
        // Build the shared search VM once the chat list has loaded (so chat-title
        // hits have a snapshot). Keyed on `groups.isEmpty` so it fires when the
        // first snapshot lands; the `searchModel == nil` guard keeps it a
        // one-shot build. Task 12 drops the backfill-progress wiring —
        // `SearchViewModel` no longer has `observeBackfill(_:)` (Task 11
        // dropped it on the iOS side of this same journal-stack rewire; the
        // journal server has no backfill concept to observe).
        .task(id: viewModel.groups.isEmpty) {
            guard searchModel == nil, !viewModel.groups.isEmpty,
                  let search = deps?.search else { return }
            searchModel = SearchViewModel(search: search, allChats: allChatSummaries)
        }
        // Keep the long-lived search VM's chat snapshot current: the toolbar
        // VM is built once, so without this new rooms and renamed titles never
        // reach chat-title search or `chatTitle(for:)` until relaunch (bugbot
        // "Mac chat search snapshot stale"). Keyed on the flattened summaries
        // because `GroupedSummaries` isn't Equatable.
        .onChange(of: allChatSummaries) { _, summaries in
            searchModel?.updateChats(summaries)
        }
        // Toggle Sidebar — menu-bar item (`Commands.swift`), ⌘⇧S, and the
        // sidebar-toggle toolbar button in `MacChatToolbar` all post the
        // same notification. Listener flips between `.automatic` (shown)
        // and `.detailOnly` (collapsed). QA finding #2 — previously the
        // notification was posted but had no listener, so toggle was a
        // silent no-op.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.toggleSidebar))) { _ in
            columnVisibility = (columnVisibility == .detailOnly) ? .automatic : .detailOnly
        }
        // Sign Out — Wave 6 / live-test #1 fix. Previously this listener
        // lived on `MatronMacApp`'s `WindowGroup`-root `Group { … }`
        // content. macOS SwiftUI did not reliably re-install the
        // subscription when the Group's active branch changed type
        // (sign-in → chat-list), so File → Sign Out silently posted into
        // the void. Anchoring on this view (the active branch any time a
        // signed-in user is reachable) is reliable — same shape as
        // `.toggleSidebar` above, which has always worked. The host owns
        // the actual side-effect (clear session) via the `onSignOut`
        // closure so the host's `@State` mutators stay co-located with
        // the host. The sign-in screen is intentionally not covered: a
        // user without a session has nothing to sign out of.
        // File → New Chat (⌘N from the menu bar). The toolbar `+` button
        // has its own .keyboardShortcut("n", modifiers: .command), but on
        // macOS the menu-bar's ⌘N takes priority and posts via the
        // command bus — so without a listener here the menu-bar shortcut
        // and the menu item itself were silent no-ops (PR #1 cursor[bot]
        // findings — both Commands.swift and MacChatListView).
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.newChat))) { _ in
            showingNewChat = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.signOut))) { _ in
            onSignOut?()
        }
        // Phase 4 Task 10 — notification-tap deep link. The Mac notification
        // handler posts `.matronOpenRoom` with `room_id` in userInfo when
        // the user taps a notification banner / Notification Center entry;
        // we route that into the existing sidebar selection state so the
        // `NavigationSplitView` detail column flips to the matching chat.
        // `selectedSummaryID` ↔ `selection: $selectedSummaryID` on the
        // sidebar `List` (line ~374) handles the actual UI flip; this
        // listener just feeds it the right ID.
        .onReceive(NotificationCenter.default.publisher(for: .matronOpenRoom)) { note in
            if let roomID = note.userInfo?[MacNotificationHandler.roomIDKey] as? String {
                selectedSummaryID = roomID
            }
        }
        // Cold-start tap drain (cursor PR #5 third-pass finding): a
        // notification tap that launched the app — `didReceive` fired
        // before this view mounted — would otherwise be lost because
        // `NotificationCenter` doesn't replay missed posts. The
        // handler buffers it; this `.task` drains on first
        // appearance. Mirrors iOS's `NotificationDelegate.consumePendingRoomID()`
        // call at `Matron/App/MatronApp.swift:177`.
        .task {
            if let pending = MacNotificationHandler.shared.consumePendingRoomID() {
                selectedSummaryID = pending
            }
        }
        // Wave 6 / live-test #4: dropped `.navigationTitle("Matron")`.
        // The detail column's `MacChatToolbar` (Task 14d) carries the
        // chat title in its `.principal` slot, and on macOS the
        // `NavigationSplitView`'s detail column was rendering "Matron"
        // as a window-bar label next to the sidebar toggle — visual
        // duplication next to the bot-room title in the toolbar's
        // principal slot. Sidebar column's existing `ContentUnavailable`
        // / list content already conveys "this is the chat list" without
        // needing a navigation title there either.
        .sheet(isPresented: $showingNewChat) {
            // Mac `AppDependencies` is a per-target type, so the sheet
            // wires off the Mac variant. The placeholder fallback keeps
            // previews / tests rendering when the environment isn't
            // populated.
            if let deps, let session {
                MacNewChatSheet(deps: deps, session: session) { _ in
                    showingNewChat = false
                }
            } else {
                MacNewChatPlaceholder(onDismiss: { showingNewChat = false })
            }
        }
        .sheet(item: $botProfileSummary) { summary in
            // Snapshot the sidebar's grouped summaries flat-list at
            // presentation time. The shared `BotProfileViewModel` filters
            // by `bot.matrixID`. Re-opening picks up a fresh snapshot.
            let allSummaries = viewModel.groups.flatMap(\.summaries)
            let bpVM = BotProfileViewModel(bot: summary.bot, allSummaries: allSummaries)
            MacBotProfileSheet(
                viewModel: bpVM,
                onSelectChat: { selected in
                    // Move selection to the tapped chat (Mac uses a
                    // sidebar-driven id selection rather than a pushed
                    // NavigationStack), then dismiss.
                    selectedSummaryID = selected.id
                    botProfileSummary = nil
                },
                onStartNewChat: {
                    botProfileSummary = nil
                    showingNewChat = true
                },
                onDismiss: { botProfileSummary = nil }
            )
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.cancel() }
        // Sync connection-state banner. Subscribes to the host's
        // long-lived `stateStream()` and mirrors yields into the local
        // `connectionState` so the banner reacts without bouncing
        // through the ViewModel. Keying on `session?.userID` so a
        // user-switch (sign out + sign back in) recycles the iterator
        // against the new session's sync service. Mirrors the iOS
        // ChatListView wiring.
        .task(id: session?.userID) {
            guard let deps, let session else { return }
            let sync = deps.syncService(for: session)
            for await state in await sync.stateStream() {
                connectionState = .from(state)
                if state == .running { hasEverConnected = true }
            }
        }
        // Dock-tile badge mirrors the chat list's running unread total.
        // `NSApp.dockTile.badgeLabel` accepts a String; `nil` removes
        // the badge so a zero count produces no overlay. AppKit handles
        // the rendering — capsule, white text, accent fill — so we
        // don't need to reproduce the iOS pill visual on the dock side.
        // No `initial: true` for the same reason as iOS — see
        // `ChatListView` for the rationale: firing on first appear
        // with a still-zero `totalUnread` actively clears any badge a
        // push notification set while the app was backgrounded.
        .onChange(of: viewModel.totalUnread) { _, newValue in
            NSApp.dockTile.badgeLabel = newValue > 0 ? "\(newValue)" : nil
        }
    }

    /// Sidebar column wrapper: when the connection-state banner is
    /// visible, stack it above the existing sidebar content. Empty /
    /// no-banner case (connected) falls straight through to `sidebar`.
    @ViewBuilder
    private var sidebarColumn: some View {
        let showConnection = (connectionState != .running)
        if showConnection {
            VStack(spacing: 0) {
                // Connection-state banner sits at the very top so the
                // user's first read of the sidebar is "what's the
                // current sync status?" before anything else competes
                // for attention. Hides on `.running` via the inner
                // switch (returns EmptyView).
                ConnectionStatusBanner(
                    state: connectionState,
                    hasEverConnected: hasEverConnected
                )
                .animation(.easeInOut(duration: 0.2), value: connectionState)
                sidebar
            }
        } else {
            sidebar
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if viewModel.isLoading {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.error, viewModel.groups.isEmpty {
            // QA finding #10: mirror the iOS error overlay so a
            // sliding-sync timeout doesn't leave the user with a silent
            // empty sidebar.
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
            List(selection: $selectedSummaryID) {
                ForEach(viewModel.groups) { group in
                    Section(group.group.rawValue) {
                        ForEach(group.summaries) { summary in
                            MacChatRow(summary: summary)
                                .tag(summary.id)
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
                // Phase 2.5: `⌘R` / sidebar pull drives a one-shot
                // `client.rooms()` snapshot through the live broadcaster
                // pipe via `ChatListViewModel.refresh()` →
                // `ChatService.forceSnapshot()`. Pre-2.5 this called
                // `chat.refresh()`, a `sync.waitUntilReady()` no-op once
                // running, so the gesture was purely cosmetic.
                await viewModel.refresh()
            }
        }
    }

    /// Detail column. Looks up the full `ChatSummary` from
    /// `viewModel.groups` by id, then routes it into `MacChatView`,
    /// which constructs its per-room `ChatViewModel` + `ComposerViewModel`
    /// from the cached `TimelineService` + `MediaService`. The
    /// "select a chat" content-unavailable view stays as the empty state
    /// for both `nil` selection and an id whose row has been removed
    /// from the latest snapshot (e.g. user left the room from another
    /// device while it was selected).
    @ViewBuilder
    private var detail: some View {
        if let id = selectedSummaryID, let summary = currentSummary(for: id) {
            chatDetail(for: summary)
        } else {
            ContentUnavailableView(
                "Select a chat",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Pick a conversation from the sidebar.")
            )
        }
    }

    /// Looks up the current `ChatSummary` for a sidebar selection id
    /// across all groups. Returns `nil` when the selected room has been
    /// removed from the latest snapshot (e.g. the user left it from
    /// another device). Re-evaluated on every `viewModel.groups` change
    /// because `@Observable` triggers `body` re-render, so the detail
    /// column always reflects the latest summary fields (title, unread
    /// count, last activity) without needing a stale captured value.
    private func currentSummary(for id: ChatSummary.ID) -> ChatSummary? {
        for group in viewModel.groups {
            if let match = group.summaries.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    /// Builds the `MacChatView` for the currently-selected summary. Wrapped
    /// in a helper so the missing-environment branch (no deps / session)
    /// stays out of the main `body` flow. The `id(summary.id)` modifier
    /// forces a fresh instance per row selection — so `@State` view
    /// models reset rather than holding stale data from the previous
    /// room.
    @ViewBuilder
    private func chatDetail(for summary: ChatSummary) -> some View {
        if let deps, let session {
            let timelineSvc = deps.timelineService(for: session, roomID: summary.id)
            let mediaSvc = deps.mediaService(for: session)
            let chatVM = ChatViewModel(roomID: summary.id, timeline: timelineSvc, media: mediaSvc)
            let composerVM = ComposerViewModel(roomID: summary.id, timeline: timelineSvc, commands: BotCommandCatalog.claudeBridge)
            MacChatView(
                viewModel: chatVM,
                composerVM: composerVM,
                chatTitle: summary.title,
                onShowBotProfile: { botProfileSummary = summary }
            )
            .id(summary.id)
        } else {
            ContentUnavailableView(
                "Session unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Sign in again to open this chat.")
            )
        }
    }

    private func runChatAction(_ action: @escaping (ChatService) async throws -> Void) {
        guard let deps, let session else { return }
        let chat = deps.chatService(for: session)
        Task { try? await action(chat) }
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
                        RelativeMinuteTimeView(lastActivity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            UnreadBadge(count: summary.unreadCount)
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
