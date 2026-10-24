import SwiftUI
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels
import MatronDesignSystem
import MatronPush
import MatronVoice

/// The signed-in shell (app shell, spec §3): a bottom tab bar over the
/// Conversations stack (the pre-existing chat list + every deep-link path),
/// the Decisions stack and Settings. Owns the per-session Decisions view model —
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
    /// The one voice-note recording, above every page so a
    /// note carries on while the user moves between conversations, items and
    /// projects. Composers reach it through the environment; each tab
    /// carries its pill (`voiceNoteIndicator`).
    @State private var voiceNotes = VoiceNoteSession()
    /// Voice mode's settings (spec 2026-10-03 §6): one object for the
    /// settings screen and for voice mode itself.
    @State private var voiceSettings = VoiceSettings()
    /// Conversation links in message bodies and their pills (decision
    /// #2954), for every tab: titles from the journal store, taps routed
    /// through `AppShellNavigation.openConversationLink`.
    @State private var conversationLinkHost = ConversationLinkHost()
    /// Mission and project links (`matron://mission/<n>`,
    /// `matron://project/<n>`) for every tab, routed through
    /// `AppShellNavigation.openPageLink`.
    @State private var pageLinkRelay = MatronPageLinkRelay()
    /// The host for the user's own shareable tracker links; set per session.
    @State private var trackerNumberLinks: TrackerNumberLinks?
    @State private var incomingLinks = IncomingTrackerLinks.shared
    /// The Search tab's view model: built once per session, so coming
    /// back to the tab shows the text and its results again.
    @State private var globalSearch: GlobalSearchViewModel?
    /// Why a Search row's number did not open.
    @State private var searchOpenError: String?
    @State private var decisionsVM: ItemsPanelViewModel
    @State private var missionsVM: MissionsDashboardViewModel
    /// The Memories screen's view model. Built with the shell, but it loads
    /// nothing until the screen appears (`MemoriesScreen`), and the shell
    /// stops its live refetch once the screen leaves the Missions stack.
    @State private var memoriesVM: MemoriesViewModel
    /// The Memories screen's "On your boxes" section. Asks no box until
    /// the screen appears, and is stopped with it.
    @State private var localMemoriesVM: LocalMemoriesViewModel
    /// Origin conversation labels for the For you rows (`itemOriginLabels()`
    /// is a cheap id→label scan, re-run when the set of origins changes).
    /// The coordinator conversation (spec §5b), live through `@AppStorage`
    /// on the per-user key so Settings' Change/Clear flip the tab at once.
    @AppStorage private var coordinatorConvoID: String?
    @Environment(\.scenePhase) private var scenePhase

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
        _missionsVM = State(initialValue: deps.makeMissionsDashboardViewModel(for: session))
        _memoriesVM = State(initialValue: deps.makeMemoriesViewModel(for: session))
        _localMemoriesVM = State(initialValue: deps.makeLocalMemoriesViewModel(for: session))
        _coordinatorConvoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))
    }

    /// Read state: a tapped notification's message was on screen in the
    /// banner. Drained wherever a tap is handled.
    private func reportTappedNotificationsSeen() {
        let seen = deps.seenTracker(for: session)
        for tap in NotificationSeenInbox.shared.drain() { seen.markSeen(convoID: tap.convoID, seq: tap.seq) }
    }

    /// The tabs and what they share. Split from `body` so that neither
    /// modifier chain is too long for the type-checker in a Release build.
    private var tabShell: some View {
        TabView(selection: Binding(get: { nav.barTab }, set: { nav.selectBarTab($0) })) {
            Tab("Coordinator", systemImage: "person.crop.circle.badge.checkmark", value: AppTab.coordinator) {
                coordinatorTab
                    .voiceNoteIndicator(voiceNotes) { nav.openVoiceNoteTarget($0) }
            }
            // What needs the user there as a count, else the chat-list
            // unread rule as a dot.
            .badge(Self.coordinatorBadge(chatListVM.hiddenCounts).map { Text($0) })
            Tab("For you", systemImage: "tray", value: AppTab.decisions) {
                decisionsTab
                    .voiceNoteIndicator(voiceNotes) { nav.openVoiceNoteTarget($0) }
            }
            // `.badge(Int)` hides itself at zero.
            .badge(decisionsVM.awaitingYouCount)
            Tab("Conversations", systemImage: "bubble.left.and.bubble.right", value: AppTab.conversations) {
                conversationsTab
                    .voiceNoteIndicator(voiceNotes) { nav.openVoiceNoteTarget($0) }
            }
            // Projects and Settings: four tabs is the most the system's
            // round Search button sits beside.
            Tab("More", systemImage: "ellipsis", value: AppTab.more) {
                moreTab
                    .voiceNoteIndicator(voiceNotes) { nav.openVoiceNoteTarget($0) }
            }
            .badge(missionsVM.isSupported != false ? missionsVM.needsYouTotal : 0)
            // Always there, and last: the system's search tab.
            Tab(value: AppTab.search, role: .search) {
                searchTab
                    .voiceNoteIndicator(voiceNotes) { nav.openVoiceNoteTarget($0) }
            }
        }
        .environment(\.appDependencies, deps)
        .environment(\.currentSession, session)
        .environment(voiceNotes)
        .environment(voiceSettings)
        .environment(\.openVoiceMode, voiceModeOpener)
        .environment(\.goToNumber, GoToNumberActions(open: openNumber))
        .fullScreenCover(item: $nav.voiceMode, content: voiceModeCover)
        .modifier(CarPlayMicrophoneRule(voiceNotes: voiceNotes, nav: nav))
    }

    var body: some View {
        tabShell
        // One rule for the one tab bar (`tabBarFollowsTheSelectedTab`).
        .environment(\.selectedTabIsAtRoot, nav.isAtRoot)
        // A project opened from wherever a mission page is mounted (a chat
        // stack, the Coordinator, For you): pushed onto that tab's stack, as
        // its link would be, so Back returns to the mission page.
        .environment(\.openProject) { nav.openPageLink(.project(id: $0)) }
        // Project pages pushed on the other tabs' stacks read their
        // mission rows from the shell's Projects view model.
        .environment(missionsVM)
        .conversationLinks(conversationLinkHost) { nav.openConversationLink($0) }
        .pageLinks(pageLinkRelay, resolve: { await deps.pageLinkOutcome($0, session: session) },
                   open: { nav.openPageLink($0) })
        // The user's own shareable links open in-app through the item and
        // page hosts. Held in state so every rendered body reads the same
        // value.
        .environment(\.trackerNumberLinks, trackerNumberLinks)
        .background(ConversationLinkTitleFeed(host: conversationLinkHost) { [chatListVM] in
            chatListVM.allSummaries.map { .init(id: $0.id, title: $0.title) }
        })
        // A shareable link opened from outside the app waits in
        // `IncomingTrackerLinks` until this shell is up.
        .onChange(of: incomingLinks.pending, initial: true) { _, url in
            guard url != nil, let url = incomingLinks.take() else { return }
            openIncomingLink(url)
        }
        .task(id: session.userID) {
            trackerNumberLinks = deps.trackerNumberLinks(for: session)
            globalSearch = makeGlobalSearch()
            let store = deps.journalStore(for: session)
            conversationLinkHost.reset(titleLookup: { try await store.conversationTitle(id: $0) })
        }
        // Notification-tap deep link: NotificationDelegate publishes the
        // room id; the shell switches to Conversations and sets the path.
        // Idempotent on duplicate sends.
        .onReceive(NotificationDelegate.shared.tappedRoomID) { roomID in
            reportTappedNotificationsSeen()
            nav.openChat(roomID)
        }
        #if DEBUG || MATRON_PERF_PROBE
        // Perf gate (UIKit timeline plan, Task 29): open a conversation
        // straight from the launch environment — no UI automation needed.
        // The timeline's controller starts the probe.
        .task {
            guard let convo = ProcessInfo.processInfo.environment["MATRON_PERF_OPEN_CONVO"] else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            nav.openChat(convo)
        }
        #endif
        // A conversation born while we're live. Only one this device
        // asked for (a /start sent from here) opens; a session an agent or
        // a routine started is marked new in the list and nothing moves.
        .task(id: session.userID) {
            for await born in await deps.syncService(for: session).newConversations() {
                if nav.conversationBorn(born) { chatListVM.markNew(born.id) }
            }
        }
        // Opening a conversation, by any route, ends its "New" marker.
        .onChange(of: nav.chatPath) { _, path in
            for id in path { chatListVM.markOpened(id) }
        }
        .onChange(of: nav.coordinatorPath) { _, path in
            for id in path { chatListVM.markOpened(id) }
        }
        .onChange(of: nav.missionsPath) { _, path in
            for id in path { chatListVM.markOpened(id) }
        }
        .onChange(of: nav.decisionsPath) { _, path in
            for id in path { chatListVM.markOpened(id) }
        }
        // Cold-start tap drain: a lock-screen tap that launched the app
        // ran `didReceive` before `.onReceive` above subscribed; the
        // delegate buffered it.
        .task(id: session.userID) {
            reportTappedNotificationsSeen()
            if let pending = NotificationDelegate.shared.consumePendingRoomID() {
                nav.openChat(pending)
            }
        }
        // Mirror the cached setting into the nav rules and the list filter.
        .onChange(of: coordinatorConvoID, initial: true) { _, id in
            nav.coordinatorConvoID = id
            chatListVM.hiddenConversationID = id
            missionsVM.coordinatorConvoID = id
            deps.pinsStore(for: session).coordinatorConvoID = id
        }
        // Pinned desk chats leave the Conversations list for its Pinned
        // section.
        .onChange(of: deps.pinsStore(for: session).pinnedIDs, initial: true) { _, ids in
            chatListVM.pinnedConversationIDs = ids
        }
        // Just the wire: the clamp that walks a selected `.missions` tab
        // back to Conversations on the false edge lives on
        // `AppShellNavigation.missionsSupported` itself (MAJOR-2), so it is
        // testable without this view.
        .onChange(of: missionsVM.isSupported) { _, supported in nav.missionsSupported = supported != false }
        // The share sheet's conversation picker reads this list.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            ShareTargetsPublisher.publish(chatListVM.allSummaries, coordinatorID: coordinatorConvoID,
                                          userID: session.userID)
        }
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
        .onDisappear { memoriesVM.stop() }
        .onDisappear { localMemoriesVM.stop() }
        // Sign-out: the old account's note neither keeps recording nor sends.
        .onDisappear { voiceNotes.reset() }
        .onChange(of: nav.memoriesShown) { _, shown in
            if !shown {
                memoriesVM.stop()
                localMemoriesVM.stop()
            }
        }
    }

    /// The voice-mode buttons' action, or `nil` (no buttons) where voice
    /// mode cannot run: below iOS 26, with no on-device recogniser, or
    /// while a voice note is being recorded (it owns the microphone).
    private var voiceModeOpener: ((VoiceModeEntry) -> Void)? {
        // The switch is read first: the recogniser is not asked whether
        // it is available on a phone where voice mode is not switched on.
        // One microphone: not while voice mode is running on a car's display.
        guard !CarPlayLink.shared.carIsActive,
              VoiceModeAvailability.isSwitchedOn(debug: MatronDebug.enabled, debugTools: voiceSettings.debugTools),
              VoiceModeAvailability.canOpen(supported: VoiceModeAvailability.isSupported,
                                            recordingVoiceNote: voiceNotes.isRecording) else { return nil }
        return { entry in
            // The button may be pressed after the car took the microphone.
            guard !CarPlayLink.shared.carIsActive else { return }
            nav.openVoiceMode(entry)
        }
    }

    /// A search row for a number: opened outright, as Go does. `nil` when
    /// it opened, otherwise why not, for the search sheet to say (it is
    /// still up, so the field cannot be presented over it).
    private func openNumber(_ num: Int) async -> String? {
        let resolution = await deps.goToNumberResolver(for: session).resolve(num: num)
        if case .open(let target, _) = resolution {
            nav.openNumberTarget(target)
            return nil
        }
        return resolution.message(num: num) ?? "Couldn't open #\(num)."
    }

    /// A link opened from outside the app: the user's own number on this
    /// journal opens like Go to number does; anything else, and a number
    /// that does not open here, goes to the browser.
    private func openIncomingLink(_ url: URL) {
        guard let origin = TrackerLinkOrigin(serverURL: session.homeserverURL, user: session.userID),
              case .number(let num) = origin.route(incoming: url)
        else {
            TrackerNumberLinks.openInBrowser(url)
            return
        }
        Task { @MainActor in
            if await openNumber(num) != nil { TrackerNumberLinks.openInBrowser(url) }
        }
    }

    /// Voice mode, over the whole shell (spec 2026-10-03 §6). Hoisted out
    /// of `body` for CI's type-checker budget.
    private func voiceModeCover(_ entry: VoiceModeEntry) -> some View {
        VoiceModeCover(entry: entry, session: session, deps: deps, settings: voiceSettings,
                       onClose: { nav.closeVoiceMode() })
            .environment(voiceNotes)
    }

    /// The Coordinator tab's badge: its needs-you count (items awaiting the
    /// user that it raised) when there is one, else a dot for unread
    /// activity, else nothing. Read from the counts alone, not the whole
    /// summary, so a Coordinator message that moves no count does not
    /// re-run the shell.
    static func coordinatorBadge(_ counts: ChatCounts) -> String? {
        if counts.needsYou > 0 { return counts.needsYou > 99 ? "99+" : "\(counts.needsYou)" }
        return counts.unread > 0 ? "•" : nil
    }

    /// The Coordinator's chat (or the setup view) as the
    /// first tab, with its own stack.
    private var coordinatorTab: some View {
        CoordinatorTabView(session: session, deps: deps, chatListVM: chatListVM, vmCache: vmCache,
                           path: coordinatorPath, convoID: coordinatorConvoID,
                           onSetupSwipe: swipeRoot,
                           onBack: nav.coordinatorReturnTab == nil ? nil : { nav.returnFromCoordinator() })
    }

    /// Stack bindings whose setters redirect the coordinator id before it
    /// can mount (see `AppShellNavigation.setChatPath`).
    private var chatPath: Binding<[String]> {
        Binding(get: { nav.chatPath }, set: { nav.setChatPath($0) })
    }

    private var coordinatorPath: Binding<[String]> {
        Binding(get: { nav.coordinatorPath }, set: { nav.setCoordinatorPath($0) })
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
            .tabBarFollowsTheSelectedTab(otherwise: .visible)
        }
        // Lets the running-subagent strip / sub-chat switcher push a child
        // chat or switch siblings on THIS tab's stack.
        .environment(\.chatNavigationPath, chatPath)
    }

    // MARK: More

    /// The More tab: its list, or the page picked from it in its place,
    /// each with its own stack as when they were tabs.
    @ViewBuilder private var moreTab: some View {
        switch nav.tab {
        case .missions: missionsTab
        case .settings: settingsTab
        default: moreList
        }
    }

    private var moreList: some View {
        NavigationStack {
            List {
                ForEach(AppShellNavigation.moreEntries(missionsSupported: missionsVM.isSupported != false),
                        id: \.self, content: moreRow)
            }
            .tabBarFollowsTheSelectedTab(otherwise: .visible)
            .navigationTitle("More")
        }
    }

    private func moreRow(_ entry: AppTab) -> some View {
        let isProjects = entry == .missions
        return Button { nav.tab = entry } label: {
            HStack {
                Label {
                    Text(isProjects ? "Projects" : "Settings")
                } icon: {
                    Image(systemName: isProjects ? ProjectGlyph.symbol : "gear")
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if isProjects, missionsVM.needsYouTotal > 0 {
                    Text("\(missionsVM.needsYouTotal)").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        // A row that reads as a list entry, not a blue button.
        .tint(.primary)
        .accessibilityIdentifier(isProjects ? "more.projects" : "more.settings")
    }

    /// A More page's way back to the list, at its root.
    private var backToMore: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { nav.tab = .more } label: { Label("More", systemImage: "chevron.left") }
                .accessibilityIdentifier("more.back")
        }
    }

    private var settingsPath: Binding<[String]> {
        Binding(get: { nav.settingsPath }, set: { nav.setPath($0, on: .settings) })
    }

    /// Settings, under More (it used to be a sheet from the Conversations
    /// list's menu, then the last tab). Its pages push with their own
    /// `NavigationLink`s. `onSignOut` is what Manage Devices calls when
    /// this device is revoked; Sign Out itself stays in the list's menu.
    private var settingsTab: some View {
        NavigationStack(path: settingsPath) {
            DeviceSettingsView(session: session,
                               devicesAPI: deps.devicesService(for: session),
                               linkAPI: deps.deviceLinkService(for: session),
                               agentChatAPI: deps.agentChatService(for: session),
                               onSignOut: onSignOut,
                               deps: deps)
                .simultaneousGesture(rootSwipe)
                .toolbar { backToMore }
        }
    }

    /// Swipe between the conversation list and the
    /// decisions list. Attached to each tab's ROOT view only (a pushed
    /// chat or item covers it), `simultaneous` so the lists keep their
    /// own vertical scroll; the rule itself is `AppShellNavigation.swipeRoot`.
    private var rootSwipe: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { v in swipeRoot(v.translation) }
    }

    private func swipeRoot(_ translation: CGSize) {
        withAnimation { _ = nav.swipeRoot(translation: translation) }
    }

    private var decisionsPath: Binding<[String]> {
        Binding(get: { nav.decisionsPath }, set: { nav.setPath($0, on: .decisions) })
    }

    /// The chat-list summary for a conversation hosted on the Projects or
    /// Decisions stack, the Coordinator's included.
    private func summary(for id: String) -> ChatSummary? {
        chatListVM.allSummaries.first { $0.id == id }
    }

    private var decisionsTab: some View {
        NavigationStack(path: decisionsPath) {
            DecisionsTabRoot(
                vm: decisionsVM,
                loadOriginLabels: { [deps, session] in
                    (try? await deps.journalStore(for: session).itemOriginLabels()) ?? ItemOriginLabels()
                },
                onSelect: { nav.pushDecision($0) },
                onOpenConversation: { nav.openConversation(fromDecisions: $0) })
            .simultaneousGesture(rootSwipe)
            .tabBarFollowsTheSelectedTab(otherwise: .visible)
            .navigationTitle("For you")
            .toolbar {
                VoiceModeQueueButton()
            }
            .navigationDestination(for: String.self) {
                decisionsDestination($0).leadsBackToTheRoot(named: "For you")
            }
        }
        // A conversation opened from an item rides this stack (mission
        // 7047), so its sub-chat strip, title tap and item links push here.
        .environment(\.chatNavigationPath, decisionsPath)
    }

    /// Every value the Decisions stack can carry: an item, and what a
    /// conversation opened from one pushes on top of it. Hoisted out of
    /// `decisionsTab` for CI's type-checker budget.
    @ViewBuilder private func decisionsDestination(_ value: String) -> some View {
        if let item = ItemRoute(pathValue: value) {
            // The chat underneath, when this item was opened from one on
            // this stack: its "opened from…" link would only point back.
            let current = ChatListView.currentChat(in: nav.decisionsPath)
            ItemDetailHost(itemID: item.id, session: session, currentConvoID: current,
                           onOpenConversation: { nav.openConversation(fromDecisions: $0) },
                           // An item link inside a body/comment pushes
                           // onto THIS tab's stack; a number
                           // this device hasn't synced stays put and
                           // alerts — the host owns that path.
                           onOpenItem: { nav.pushDecision($0) })
        } else if let mission = MissionRoute(pathValue: value) {
            MissionRouteDestination(route: mission, session: session, deps: deps, vmCache: vmCache,
                                    onOpenConversation: { nav.openConversation(fromDecisions: $0) },
                                    onOpenItem: { nav.pushDecision($0) })
        } else if let project = ProjectRoute(pathValue: value) {
            ProjectRouteDestination(route: project, session: session, deps: deps, vmCache: vmCache,
                                    onOpenConversation: { nav.openConversation(fromDecisions: $0) },
                                    onOpenItem: { nav.pushDecision($0) },
                                    onOpenMission: { nav.push(MissionRoute(id: $0).pathValue, on: .decisions) })
        } else {
            ChatDestinationView(id: value, summary: summary(for: value), vmCache: vmCache)
        }
    }


    private var missionsPath: Binding<[String]> {
        Binding(get: { nav.missionsPath }, set: { nav.setPath($0, on: .missions) })
    }

    private var missionsTab: some View {
        NavigationStack(path: missionsPath) {
            ProjectsTabRoot(viewModel: missionsVM, onAction: handleProjectsHome,
                            onLegacyAction: { nav.handleDashboard($0) },
                            onOpenMemories: { nav.openMemories() })
                .simultaneousGesture(rootSwipe)
                .toolbar { backToMore }
                .tabBarFollowsTheSelectedTab(otherwise: .visible)
                .navigationDestination(for: String.self) {
                    projectsDestination($0).leadsBackToTheRoot(named: "Projects")
                }
        }
        .environment(\.chatNavigationPath, missionsPath)
        // On its own stack a project opens by pushing, not by a tab switch.
        .environment(\.openProject) { nav.pushProject($0) }
    }

    /// Every value the Projects stack can carry. Hoisted out of
    /// `missionsTab` for CI's type-checker budget.
    @ViewBuilder private func projectsDestination(_ value: String) -> some View {
        if value == MemoriesRoute.list {
            MemoriesScreen(viewModel: memoriesVM, localViewModel: localMemoriesVM,
                           onOpen: { nav.openMemory($0) }, onOpenLocal: { nav.openLocalMemory($0) },
                           onNew: { nav.openNewMemory() })
                .tabBarFollowsTheSelectedTab(otherwise: .hidden)
        } else if let ref = LocalMemoryRoute(pathValue: value)?.ref {
            LocalMemoryHost(viewModel: memoriesVM, localViewModel: localMemoriesVM, ref: ref,
                            onOpenJournalMemory: { nav.openMemory($0) })
                .tabBarFollowsTheSelectedTab(otherwise: .hidden)
        } else if value == MemoriesRoute.newMemory || MemoryRoute(pathValue: value) != nil {
            MemoryEditorHost(viewModel: memoriesVM, name: MemoryRoute(pathValue: value)?.id,
                             onSaved: { nav.memorySaved(name: $0, wasNew: $1) }, onDeleted: { nav.memoryDeleted() })
                .tabBarFollowsTheSelectedTab(otherwise: .hidden)
        } else if let project = ProjectRoute(pathValue: value) {
            ProjectDetailHost(projectID: project.id, session: session, missionsViewModel: missionsVM,
                              onOpenMission: { nav.pushMission($0) }, onOpenItem: { nav.pushMissionItem($0) },
                              onOpenSession: { nav.openConversation(fromMissions: $0) },
                              onOpenMilestone: openMilestone)
        } else if let mission = MissionRoute(pathValue: value) {
            MissionDetailHost(missionID: mission.id, session: session, onOpenMilestone: openMilestone,
                              onOpenItem: { nav.pushMissionItem($0) },
                              onOpenConversation: { nav.openConversation(fromMissions: $0) })
        } else if let item = ItemRoute(pathValue: value) {
            ItemDetailHost(itemID: item.id, session: session,
                           currentConvoID: ChatListView.currentChat(in: nav.missionsPath),
                           onOpenConversation: { nav.openConversation(fromMissions: $0) },
                           onOpenItem: { nav.pushMissionItem($0) })
        } else {
            // A conversation opened from a page on this stack (mission
            // 7047): Back pops to that page.
            ChatDestinationView(id: value, summary: summary(for: value), vmCache: vmCache)
        }
    }

    /// Every Projects home tap. "Open in chat" from the briefing reader
    /// lands on the briefing's own message, as a milestone tap does.
    private func handleProjectsHome(_ action: ProjectsHomeAction) {
        if case .openConversation(let convoID, let seq) = action {
            openMilestone(convoID: convoID, seq: seq)
        } else {
            nav.handleProjectsHome(action)
        }
    }

    /// A milestone tap: open its conversation on this stack, then park the jump on that
    /// room's cached `ChatViewModel`. Parking (rather than passing a seq
    /// through the route) is what makes the tap work before the room's
    /// stream is up — `focusOrPark` fires it on the first snapshot, and a
    /// seq that no longer exists lands on the nearest earlier row.
    private func openMilestone(convoID: String, seq: Int64) {
        nav.openConversation(fromMissions: convoID)
        let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
        Task { await chat.jumpToMilestone(seq: seq) }
    }

    // MARK: Search

    private var searchPath: Binding<[String]> {
        Binding(get: { nav.searchPath }, set: { nav.setPath($0, on: .search) })
    }

    /// The Search tab: the shared Search page at its root, and what a
    /// result opens pushed on its own stack, so Back returns to the
    /// results. A memory opens on the Projects tab, where Memories lives.
    private var searchTab: some View {
        NavigationStack(path: searchPath) {
            searchRoot
                .tabBarFollowsTheSelectedTab(otherwise: .visible)
                .navigationTitle("Search")
                .navigationDestination(for: String.self) {
                    searchDestination($0).leadsBackToTheRoot(named: "Search")
                }
        }
        .environment(\.chatNavigationPath, searchPath)
        .alert("Couldn't open", isPresented: searchOpenErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(searchOpenError ?? "")
        }
    }

    @ViewBuilder private var searchRoot: some View {
        if let globalSearch {
            SearchTabView(viewModel: globalSearch, onOpen: openSearchResult)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchOpenErrorShown: Binding<Bool> {
        Binding(get: { searchOpenError != nil }, set: { if !$0 { searchOpenError = nil } })
    }

    private func makeGlobalSearch() -> GlobalSearchViewModel {
        GlobalSearchViewModel(searcher: deps.globalSearcher(for: session),
                              chats: { [chatListVM] in chatListVM.allSummaries },
                              resolver: deps.goToNumberResolver(for: session),
                              openNumber: { nav.openNumberTarget($0) })
    }

    /// A Search row, opened the way the same thing opens elsewhere.
    private func openSearchResult(_ target: GlobalSearchTarget) {
        switch target {
        case .number(let num):
            Task { @MainActor in
                if let message = await openNumber(num) { searchOpenError = message }
            }
        case .memory(let name):
            nav.openMemories()
            nav.openMemory(name)
        case .conversation(let id):
            nav.openChat(id)
        case .message(let convoID, let seq):
            nav.openChat(convoID)
            // Only top-level chats get the in-conversation search bar; a
            // subagent chat opens without one (see `ChatListView`).
            guard let query = globalSearch?.page.query, !query.isEmpty,
                  chatListVM.allSummaries.contains(where: { $0.id == convoID }) else { return }
            let (chat, _) = vmCache.viewModels(for: convoID, deps: deps, session: session)
            Task { await chat.beginChatSearch(query: query, startingAt: String(seq)) }
        }
    }

    /// Every value the Search stack can carry. Hoisted out of `searchTab`
    /// for CI's type-checker budget.
    @ViewBuilder private func searchDestination(_ value: String) -> some View {
        if let item = ItemRoute(pathValue: value) {
            ItemDetailHost(itemID: item.id, session: session,
                           currentConvoID: ChatListView.currentChat(in: nav.searchPath),
                           onOpenConversation: { nav.openConversationLink($0) },
                           onOpenItem: { nav.push(ItemRoute(id: $0).pathValue, on: .search) })
        } else if let mission = MissionRoute(pathValue: value) {
            MissionRouteDestination(route: mission, session: session, deps: deps, vmCache: vmCache,
                                    onOpenConversation: { nav.openConversationLink($0) },
                                    onOpenItem: { nav.push(ItemRoute(id: $0).pathValue, on: .search) })
        } else if let project = ProjectRoute(pathValue: value) {
            ProjectRouteDestination(route: project, session: session, deps: deps, vmCache: vmCache,
                                    onOpenConversation: { nav.openConversationLink($0) },
                                    onOpenItem: { nav.push(ItemRoute(id: $0).pathValue, on: .search) },
                                    onOpenMission: { nav.push(MissionRoute(id: $0).pathValue, on: .search) })
        } else {
            ChatDestinationView(id: value, summary: summary(for: value), vmCache: vmCache)
        }
    }
}
