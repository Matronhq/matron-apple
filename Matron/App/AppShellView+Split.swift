import SwiftUI
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The iPad's split shell (`SplitShellRule`): the Mac window's layout on
/// iPad. The sidebar is the nav column (the Mac's `MacNavColumn`, ported)
/// beside a list — Conversations, For you or Search — and the detail
/// column shows what was chosen there, a conversation with its tracker
/// beside it when the column is wide enough (`ChatPager`).
///
/// It reads and writes the same `AppShellNavigation` as the tab bar, so
/// every deep link, notification tap and voice-note pill lands the same
/// way in both layouts, and a window resized across the line keeps its
/// place. Choosing a row in the sidebar replaces the detail stack, as a
/// selection does on the Mac; links inside the detail push onto it, so
/// Back returns to where the link sat.
extension AppShellView {
    var splitShell: some View {
        // A plain two-pane row rather than `NavigationSplitView`: on iPad
        // that clamps the sidebar to the system's narrow default whatever
        // width it is asked for, and the For you cards need an iPhone's
        // width.
        HStack(spacing: 0) {
            SplitNavColumn(selection: splitNavSelection, entries: splitNavEntries,
                           badges: splitNavBadges, needsYou: splitNavNeedsYou,
                           onSelect: selectSplitNav)
            splitSidebarList
                .frame(width: SplitShellRule.sidebarWidth(for: nav.tab) - SplitShellRule.navColumnWidth)
            Rectangle().fill(.separator).frame(width: 1 / 3).ignoresSafeArea()
            splitDetail
                .voiceNoteIndicator(voiceNotes) { nav.openVoiceNoteTarget($0) }
                .frame(maxWidth: .infinity)
        }
        .environment(\.isInSplitShell, true)
    }

    // MARK: Nav column

    private var splitNavEntries: [SplitNavEntry] {
        missionsVM.isSupported != false
            ? [.coordinator, .projects, .decisions, .conversations, .memories]
            : [.coordinator, .decisions, .conversations]
    }

    /// The entry drawn selected: the page on screen.
    private var splitNavSelection: SplitNavEntry {
        switch nav.tab {
        case .coordinator: return .coordinator
        case .decisions: return .decisions
        case .missions: return nav.missionsPath.first == MemoriesRoute.list ? .memories : .projects
        case .search: return .search
        case .settings: return .settings
        case .conversations, .more: return .conversations
        }
    }

    private var splitNavBadges: [SplitNavEntry: Int] {
        [.coordinator: chatListVM.hiddenCounts.unread,
         .decisions: decisionsVM.awaitingYouCount,
         .projects: missionsVM.isSupported != false ? missionsVM.needsYouTotal : 0]
    }

    private var splitNavNeedsYou: [SplitNavEntry: Int] {
        [.coordinator: chatListVM.hiddenCounts.needsYou]
    }

    private func selectSplitNav(_ entry: SplitNavEntry) {
        switch entry {
        case .coordinator: nav.tab = .coordinator
        case .projects:
            // Back to the Projects home from Memories, which shares its stack.
            if nav.missionsPath.first == MemoriesRoute.list { nav.setPath([], on: .missions) }
            nav.tab = .missions
        case .memories: nav.openMemories()
        case .decisions: nav.tab = .decisions
        case .conversations: nav.tab = .conversations
        case .search: nav.tab = .search
        case .settings: nav.tab = .settings
        }
    }

    // MARK: Sidebar list

    /// For you and Search list beside the nav column what the detail
    /// opens; every other page lists Conversations there, so a chat is
    /// always one tap away, as in the Mac's sidebar.
    @ViewBuilder private var splitSidebarList: some View {
        switch nav.tab {
        case .decisions: splitDecisionsList
        case .search: splitSearchList
        default: splitConversationsList
        }
    }

    /// Opens a conversation chosen in the sidebar: the detail shows it at
    /// the root of the Conversations stack. The Coordinator's own chat
    /// selects its page instead (`setPath`).
    private func openFromSidebar(_ path: [String]) {
        guard !path.isEmpty else { return }
        nav.tab = .conversations
        nav.setPath(path, on: .conversations)
    }

    private var splitConversationsList: some View {
        // The list's own rows push by value onto this stack; it never
        // holds anything, and what they push opens in the detail column.
        NavigationStack(path: Binding(get: { [] }, set: { openFromSidebar($0) })) {
            ChatListView(viewModel: chatListVM, ownsViewModel: false, vmCache: vmCache,
                         onSignOut: onSignOut, onOpenChat: { openFromSidebar([$0]) })
        }
        // What the list appends itself (Archived, a pinned desk) lands in
        // the detail's Conversations stack.
        .environment(\.chatNavigationPath, Binding(
            get: { nav.path(of: .conversations) },
            set: { openFromSidebar($0) }))
        .environment(\.selectedConversationID,
                     nav.tab == .conversations ? ChatListView.currentChat(in: nav.chatPath) : nil)
    }

    private var splitDecisionsList: some View {
        NavigationStack {
            DecisionsTabRoot(
                vm: decisionsVM,
                loadOriginLabels: { [deps, session] in
                    (try? await deps.journalStore(for: session).itemOriginLabels()) ?? ItemOriginLabels()
                },
                onSelect: { nav.setPath([ItemRoute(id: $0).pathValue], on: .decisions) },
                onOpenConversation: { nav.setPath([$0], on: .decisions) })
            .navigationTitle("For you")
            .toolbar { VoiceModeQueueButton() }
        }
    }

    private var splitSearchList: some View {
        NavigationStack {
            Group {
                if let globalSearch {
                    // A result replaces what the detail shows, as a row
                    // chosen in any list does here.
                    SearchTabView(viewModel: globalSearch,
                                  onOpen: { openSearchResult($0, replacingDetail: true) },
                                  isShowing: true)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Search")
        }
        .alert("Couldn't open", isPresented: searchOpenErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(searchOpenError ?? "")
        }
    }

    // MARK: Detail

    @ViewBuilder private var splitDetail: some View {
        switch nav.tab {
        case .coordinator:
            // Its own page in the split view, never a jump with a way
            // back: the nav column is always there.
            CoordinatorTabView(session: session, deps: deps, chatListVM: chatListVM, vmCache: vmCache,
                               path: coordinatorPath, convoID: coordinatorConvoID,
                               onSetupSwipe: { _ in }, onBack: nil)
        case .missions: splitProjects
        case .settings: splitSettings
        case .decisions:
            selectionStack(.decisions, rootName: "For you",
                           empty: ("Nothing chosen", "tray", "Choose an item from For you.")) {
                decisionsDestination($0)
            }
        case .search:
            selectionStack(.search, rootName: "Search",
                           empty: ("Search", "magnifyingglass", "Results open here.")) {
                searchDestination($0)
            }
        case .conversations, .more:
            selectionStack(.conversations, rootName: "Conversations",
                           empty: ("No conversation open", "bubble.left.and.bubble.right",
                                   "Choose a conversation from the list.")) {
                conversationsDestination($0)
            }
        }
    }

    /// The detail column for a page chosen in a sidebar list: the first
    /// entry of `tab`'s stack is its root, drawn without a Back button, and
    /// the rest is pushed on top of it. Nothing chosen: a placeholder.
    private func selectionStack<Destination: View>(
        _ tab: AppTab, rootName: String, empty: (title: String, symbol: String, hint: String),
        @ViewBuilder destination: @escaping (String) -> Destination
    ) -> some View {
        let full = Binding<[String]>(
            get: { nav.path(of: tab) },
            set: { nav.setPath(SplitShellRule.keepingRoot($0, old: nav.path(of: tab)), on: tab) })
        let pushed = Binding<[String]>(
            get: { Array(nav.path(of: tab).dropFirst()) },
            set: { new in
                guard let root = nav.path(of: tab).first else { return }
                nav.setPath([root] + new, on: tab)
            })
        return NavigationStack(path: pushed) {
            Group {
                if let root = nav.path(of: tab).first {
                    destination(root).id(root)
                } else {
                    ContentUnavailableView(empty.title, systemImage: empty.symbol,
                                           description: Text(empty.hint))
                }
            }
            .navigationDestination(for: String.self) {
                destination($0).leadsBackToTheRoot(named: rootName)
            }
        }
        .environment(\.chatNavigationPath, full)
        .id(tab)
    }

    /// Every value the Conversations stack carries here, as the list's own
    /// destinations do on iPhone (`ChatListView`).
    @ViewBuilder private func conversationsDestination(_ value: String) -> some View {
        let current = ChatListView.currentChat(in: nav.chatPath)
        if let item = ItemRoute(pathValue: value) {
            ItemDetailHost(itemID: item.id, session: session, currentConvoID: current,
                           onOpenConversation: { convoID in
                               guard convoID != current else { return }
                               nav.push(convoID, on: .conversations)
                           },
                           onOpenItem: { nav.push(ItemRoute(id: $0).pathValue, on: .conversations) })
        } else if let mission = MissionRoute(pathValue: value) {
            MissionRouteDestination(route: mission, session: session, deps: deps, vmCache: vmCache,
                                    onOpenConversation: openConversationOnChatStack,
                                    onOpenItem: { nav.push(ItemRoute(id: $0).pathValue, on: .conversations) })
        } else if let project = ProjectRoute(pathValue: value) {
            ProjectRouteDestination(route: project, session: session, deps: deps, vmCache: vmCache,
                                    onOpenConversation: openConversationOnChatStack,
                                    onOpenItem: { nav.push(ItemRoute(id: $0).pathValue, on: .conversations) },
                                    onOpenMission: { nav.push(MissionRoute(id: $0).pathValue, on: .conversations) })
        } else if value == ArchivedRoute.list {
            ArchivedChatsView(chat: deps.chatService(for: session),
                              notifyStore: deps.notifySettings(for: session)) { summary in
                chatListVM.keepSummary(summary)
                nav.push(summary.id, on: .conversations)
            }
        } else {
            ChatDestinationView(id: value, summary: splitSummary(for: value), vmCache: vmCache)
        }
    }

    private func openConversationOnChatStack(_ convoID: String) {
        nav.setPath(ChatListView.path(afterOpeningConversation: convoID, from: nav.chatPath), on: .conversations)
    }

    /// The list summary for a conversation, pinned and opened-from-Archived
    /// ones included (`ChatListView.currentSummary`).
    private func splitSummary(for id: String) -> ChatSummary? {
        chatListVM.pinnedSummaries[id] ?? summary(for: id) ?? chatListVM.openedOutsideList[id]
    }

    private var splitProjects: some View {
        NavigationStack(path: missionsPath) {
            ProjectsTabRoot(viewModel: missionsVM, onAction: handleProjectsHome,
                            onLegacyAction: { nav.handleDashboard($0) },
                            onOpenMemories: { nav.openMemories() })
                .navigationDestination(for: String.self) {
                    projectsDestination($0).leadsBackToTheRoot(named: "Projects")
                }
        }
        .environment(\.chatNavigationPath, missionsPath)
        .environment(\.openProject) { nav.pushProject($0) }
    }

    private var splitSettings: some View {
        NavigationStack(path: settingsPath) {
            DeviceSettingsView(session: session,
                               devicesAPI: deps.devicesService(for: session),
                               linkAPI: deps.deviceLinkService(for: session),
                               agentChatAPI: deps.agentChatService(for: session),
                               onSignOut: onSignOut,
                               deps: deps)
        }
    }
}

/// The split shell's nav column entries, top to bottom; Search and
/// Settings sit at its foot.
enum SplitNavEntry: Hashable {
    case coordinator
    case projects
    case decisions
    case conversations
    case memories
    case search
    case settings

    var title: String {
        switch self {
        case .coordinator: return "Coordinator"
        case .projects: return "Projects"
        case .decisions: return "For you"
        case .conversations: return "Chats"
        case .memories: return "Memories"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .coordinator: return "person.crop.circle.badge.checkmark"
        case .projects: return ProjectGlyph.symbol
        case .decisions: return "tray"
        case .conversations: return "bubble.left.and.bubble.right"
        case .memories: return "brain"
        case .search: return "magnifyingglass"
        case .settings: return "gear"
        }
    }

    var accessibilityID: String {
        switch self {
        case .decisions: return "nav.foryou"
        default: return "nav.\(String(describing: self))"
        }
    }
}

/// The Mac's nav column (`MacNavColumn`) on iPad: a fixed-width column of
/// large icons with labels beneath, a red unread count at the top-trailing
/// corner and an orange needs-you count at the top-leading one.
struct SplitNavColumn: View {
    let selection: SplitNavEntry
    let entries: [SplitNavEntry]
    let badges: [SplitNavEntry: Int]
    let needsYou: [SplitNavEntry: Int]
    let onSelect: (SplitNavEntry) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(entries, id: \.self) { entry($0) }
            Spacer(minLength: 0)
            entry(.search)
            entry(.settings)
        }
        .padding(.vertical, 8)
        .frame(width: SplitShellRule.navColumnWidth)
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
    }

    private func entry(_ entry: SplitNavEntry) -> some View {
        let count = badges[entry].flatMap { $0 > 0 ? $0 : nil }
        let needs = needsYou[entry].flatMap { $0 > 0 ? $0 : nil }
        let selected = selection == entry
        return Button { onSelect(entry) } label: {
            VStack(spacing: 4) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 22))
                    .frame(height: 28)
                    .overlay(alignment: .topTrailing) {
                        if let count { countBadge(count) }
                    }
                    .overlay(alignment: .topLeading) {
                        if let needs { countBadge(needs, color: .orange, leading: true) }
                    }
                Text(entry.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: SplitShellRule.navColumnWidth - 12, height: 56)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(entry.title + (needs.map { ", \($0) need you" } ?? "")
                            + (count.map { ", \($0) unread" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(entry.accessibilityID)
    }

    private func countBadge(_ count: Int, color: Color = .red, leading: Bool = false) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(color, in: Capsule())
            .offset(x: leading ? -8 : 8, y: -6)
    }
}
