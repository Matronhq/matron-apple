import SwiftUI
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The signed-in shell (app shell, spec §3): a bottom tab bar over the
/// Conversations stack (the pre-existing chat list + every deep-link path)
/// and the Decisions stack. Owns the per-session Decisions view model —
/// one `ItemsPanelViewModel(convoID: nil)` started here, stopped when the
/// shell leaves the hierarchy on sign-out — so the tab badge is live
/// app-wide. `MatronApp` is left with bootstrap / sign-in gating and the
/// process-level services (push, background refresh, lock).
struct AppShellView: View {
    let session: UserSession
    let deps: AppDependencies
    let onSignOut: () -> Void

    @State private var nav: AppShellNavigation
    @State private var chatListVM: ChatListViewModel
    /// Shared per-room chat/composer VM cache — one for the whole shell so
    /// a room opened from any tab rebinds to the same live view models.
    @State private var vmCache = ChatVMCache()
    @State private var decisionsVM: ItemsPanelViewModel
    /// Origin conversation titles for the Decisions rows (`conversationTitles()`
    /// is a cheap id→title scan, re-run when the set of origins changes).
    @State private var originTitles: [String: String] = [:]
    /// The coordinator conversation (spec §5b), live through `@AppStorage`
    /// on the per-user key so Settings' Change/Clear flip the tab at once.
    @AppStorage private var coordinatorConvoID: String?

    /// `navigation` is optional rather than defaulted to
    /// `AppShellNavigation()`: default-argument expressions are evaluated
    /// nonisolated under the Swift 5.10 language mode, and the navigation
    /// object is `@MainActor`. Tests inject a pre-set state; the app takes
    /// the fresh one built here.
    init(session: UserSession, deps: AppDependencies, onSignOut: @escaping () -> Void,
         navigation: AppShellNavigation? = nil) {
        self.session = session
        self.deps = deps
        self.onSignOut = onSignOut
        _nav = State(initialValue: navigation ?? AppShellNavigation())
        _chatListVM = State(initialValue: ChatListViewModel(chat: deps.chatService(for: session)))
        _decisionsVM = State(initialValue: deps.makeDecisionsViewModel(for: session))
        _coordinatorConvoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))
    }

    var body: some View {
        TabView(selection: $nav.tab) {
            coordinatorTab
                .tabItem { Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark") }
                // The chat-list unread rule as a dot: any unread activity in
                // that conversation.
                .badge(coordinatorHasUnread ? "•" : nil as String?)
                .tag(AppTab.coordinator)
            conversationsTab
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.conversations)
            decisionsTab
                .tabItem { Label("Decisions", systemImage: "checkmark.circle") }
                // `.badge(Int)` hides itself at zero.
                .badge(decisionsVM.awaitingYouCount)
                .tag(AppTab.decisions)
        }
        .environment(\.appDependencies, deps)
        .environment(\.currentSession, session)
        // Notification-tap deep link: NotificationDelegate publishes the
        // room id; the shell switches to Conversations and sets the path.
        // Idempotent on duplicate sends.
        .onReceive(NotificationDelegate.shared.tappedRoomID) { roomID in
            nav.openChat(roomID)
        }
        // Auto-open a conversation the bridge just created while we're
        // live (e.g. /start in another chat). The engine only emits ids
        // for convos born while running.
        .task(id: session.userID) {
            for await roomID in await deps.syncService(for: session).newConversations() {
                nav.openChat(roomID)
            }
        }
        // Cold-start tap drain: a lock-screen tap that launched the app
        // ran `didReceive` before `.onReceive` above subscribed; the
        // delegate buffered it.
        .task(id: session.userID) {
            if let pending = NotificationDelegate.shared.consumePendingRoomID() {
                nav.openChat(pending)
            }
        }
        // The nav rules route the coordinator conversation to its own tab
        // (Bugbot, PR #197): mirror the setting into the nav object, and
        // hand off a chat-list row push of that conversation.
        .onChange(of: coordinatorConvoID, initial: true) { _, id in nav.coordinatorConvoID = id }
        .onChange(of: nav.chatPath) { _, _ in nav.redirectCoordinatorPush() }
        .onChange(of: nav.coordinatorPath) { _, _ in nav.redirectCoordinatorPush() }
        .task { decisionsVM.start() }
        // The Conversations list VM needs to keep running even while
        // another tab shows: the coordinator badge and title read it.
        // `ChatListViewModel.start()` is idempotent — it cancels any prior
        // `observationTask` before subscribing — so this and
        // `ChatListView`'s own `.task { viewModel.start() }` don't race.
        .task { chatListVM.start() }
        .onDisappear { decisionsVM.stop() }
        .onDisappear { chatListVM.cancel() }
    }

    private var coordinatorHasUnread: Bool {
        guard let id = coordinatorConvoID else { return false }
        return (chatListVM.groups.flatMap(\.summaries).first { $0.id == id }?.unreadCount ?? 0) > 0
    }

    private var coordinatorTab: some View {
        CoordinatorTabView(session: session, deps: deps, chatListVM: chatListVM, vmCache: vmCache,
                           path: $nav.coordinatorPath, convoID: $coordinatorConvoID)
    }

    private var conversationsTab: some View {
        NavigationStack(path: $nav.chatPath) {
            ChatListView(
                viewModel: chatListVM,
                vmCache: vmCache,
                onSignOut: onSignOut,
                // A search result / new chat navigates via the path the
                // shell owns (same mechanism as a notification tap).
                onOpenChat: { roomID in nav.openChat(roomID) }
            )
            .simultaneousGesture(rootSwipe)
        }
        // Lets the running-subagent strip / sub-chat switcher push a child
        // chat or switch siblings on THIS tab's stack.
        .environment(\.chatNavigationPath, $nav.chatPath)
    }

    /// Dan, 2026-09-09: swipe between the conversation list and the
    /// decisions list. Attached to each tab's ROOT view only (a pushed
    /// chat or item covers it), `simultaneous` so the lists keep their
    /// own vertical scroll; the rule itself is `AppShellNavigation.swipeRoot`.
    private var rootSwipe: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { v in
            withAnimation { _ = nav.swipeRoot(translation: v.translation) }
        }
    }

    private var decisionsTab: some View {
        NavigationStack(path: $nav.decisionsPath) {
            DecisionsListView(
                model: .init(
                    rows: decisionsVM.awaitingYou.map { .init(item: $0, originTitle: originTitles[$0.originConvoID]) },
                    isSupported: decisionsVM.isSupported,
                    isRefreshing: decisionsVM.isRefreshing),
                onSelect: { nav.pushDecision($0) },
                onOpenConversation: { nav.openConversation(fromDecisions: $0) },
                onRefresh: { await decisionsVM.refresh() }
            )
            .simultaneousGesture(rootSwipe)
            .navigationTitle("Decisions")
            .navigationDestination(for: ItemRoute.self) { route in
                ItemDetailHost(itemID: route.id, session: session, currentConvoID: nil,
                               onOpenConversation: { nav.openConversation(fromDecisions: $0) })
            }
            .task(id: decisionsVM.awaitingYou.map(\.originConvoID)) {
                originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:]
            }
            // Refresh failures surface through the VM's `error` — the same
            // alert the tracker uses (spec §7).
            .alert("Tracker", isPresented: Binding(get: { decisionsVM.error != nil }, set: { if !$0 { decisionsVM.error = nil } })) {
                Button("OK") { decisionsVM.error = nil }
            } message: {
                Text(decisionsVM.error ?? "")
            }
        }
    }
}
