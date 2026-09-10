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
    @State private var missionsVM: MissionsListViewModel
    /// Origin conversation labels for the Decisions rows (`conversationOriginLabels()`
    /// is a cheap id→label scan, re-run when the set of origins changes).
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
        _missionsVM = State(initialValue: deps.makeMissionsListViewModel(for: session))
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
            if missionsVM.isSupported {
                missionsTab
                    .tabItem { Label("Missions", systemImage: "flag.checkered") }
                    .badge(missionsVM.needsYouTotal)
                    .tag(AppTab.missions)
            }
            decisionsTab
                .tabItem { Label("Decisions", systemImage: "checkmark.circle") }
                // `.badge(Int)` hides itself at zero.
                .badge(decisionsVM.awaitingYouCount)
                .tag(AppTab.decisions)
            conversationsTab
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.conversations)
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
        .task { decisionsVM.start() }
        // The Conversations list VM needs to keep running even while
        // another tab shows: the coordinator badge and title read it.
        // `ChatListViewModel.start()` is idempotent — it cancels any prior
        // `observationTask` before subscribing — so this and
        // `ChatListView`'s own `.task { viewModel.start() }` don't race.
        .task { chatListVM.start() }
        .task { missionsVM.start() }
        .onDisappear { decisionsVM.stop() }
        .onDisappear { chatListVM.cancel() }
        .onDisappear { missionsVM.stop() }
    }

    private var coordinatorHasUnread: Bool {
        guard let id = coordinatorConvoID else { return false }
        return (chatListVM.groups.flatMap(\.summaries).first { $0.id == id }?.unreadCount ?? 0) > 0
    }

    /// Stack bindings whose setters redirect the coordinator id before it
    /// can mount (see `AppShellNavigation.setChatPath`).
    private var chatPath: Binding<[String]> {
        Binding(get: { nav.chatPath }, set: { nav.setChatPath($0) })
    }

    private var coordinatorPath: Binding<[String]> {
        Binding(get: { nav.coordinatorPath }, set: { nav.setCoordinatorPath($0) })
    }

    private var coordinatorTab: some View {
        CoordinatorTabView(session: session, deps: deps, chatListVM: chatListVM, vmCache: vmCache,
                           path: coordinatorPath, convoID: $coordinatorConvoID)
    }

    private var conversationsTab: some View {
        NavigationStack(path: chatPath) {
            ChatListView(
                viewModel: chatListVM,
                // The shell owns this view model's lifetime (its `.task`
                // above starts it, its `.onDisappear` cancels it): the
                // Coordinator badge and title read it while this tab is
                // away, so the list must not cancel it on tab switch
                // (CodeRabbit, PR #197).
                ownsViewModel: false,
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
        .environment(\.chatNavigationPath, chatPath)
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
                               onOpenConversation: { nav.openConversation(fromDecisions: $0) },
                               // An item link inside a body/comment pushes
                               // onto THIS tab's stack (item #115); a number
                               // this device hasn't synced stays put and
                               // alerts — the host owns that path.
                               onOpenItem: { nav.pushDecision($0) })
            }
            .task(id: decisionsVM.awaitingYou.map(\.originConvoID)) {
                originTitles = (try? deps.journalStore(for: session).conversationOriginLabels()) ?? [:]
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

    private var missionsPath: Binding<[String]> {
        Binding(get: { nav.missionsPath }, set: { nav.missionsPath = $0 })
    }

    private var missionsTab: some View {
        NavigationStack(path: missionsPath) {
            MissionsTabRoot(viewModel: missionsVM, onSelect: { nav.pushMission($0) })
                .simultaneousGesture(rootSwipe)
                .navigationDestination(for: String.self) { value in
                    if let mission = MissionRoute(pathValue: value) {
                        MissionDetailHost(missionID: mission.id, session: session,
                                          onOpenMilestone: openMilestone,
                                          onOpenItem: { nav.pushMissionItem($0) },
                                          onOpenConversation: { nav.openConversation(fromMissions: $0) })
                    } else if let item = ItemRoute(pathValue: value) {
                        ItemDetailHost(itemID: item.id, session: session, currentConvoID: nil,
                                       onOpenConversation: { nav.openConversation(fromMissions: $0) },
                                       onOpenItem: { nav.pushMissionItem($0) })
                    }
                }
        }
        .environment(\.chatNavigationPath, missionsPath)
    }

    /// A milestone tap: open its conversation, then park the jump on that
    /// room's cached `ChatViewModel`. Parking (rather than passing a seq
    /// through the route) is what makes the tap work before the room's
    /// stream is up — `focusOrPark` fires it on the first snapshot, and a
    /// seq that no longer exists lands on the nearest earlier row.
    private func openMilestone(convoID: String, seq: Int64) {
        nav.openConversation(fromMissions: convoID)
        let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
        Task { await chat.jumpToMilestone(seq: seq) }
    }
}
