import SwiftUI
import AppKit
import os
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronSearch
import MatronSync
import MatronViewModels

/// Un-gated breadcrumbs for detail-column lifecycle anomalies. The
/// 2026-07-13 19:12 incident showed three fresh ChatViewModel boots in
/// 20 seconds (chat panel blanking while a 2000-item room re-mapped from
/// scratch) with nothing recording WHY the detail column remounted —
/// selection churn, the search-branch swap, and auto-open were all
/// indistinguishable after the fact.
private let listLogger = Logger(subsystem: "chat.matron", category: "mac-chat-list")

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
    /// Per-room chat/composer view models, cached for the life of this
    /// screen. `chatDetail(for:)` used to construct fresh instances on
    /// every mount, so ANY detail-column remount (selection churn during
    /// a sidebar rebuild, the search branch swap) rebooted the timeline
    /// from zero — the panel sat blank for seconds while a large room
    /// re-mapped (2026-07-13 19:12 incident: three boots in 20s, one
    /// with 2106 items). A remount now rebinds to the live VM: `items`
    /// survive `stop()`, so the previous content paints on the first
    /// frame and the restarted stream just refreshes it.
    @State private var vmCache = ChatVMCache()
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var selectedSummaryID: ChatSummary.ID?
    @State private var showingNewChat = false
    /// The chat detail's pane route — the tasks-and-decisions pane with
    /// its push stack, or an open sub-chat — per WINDOW (spec 2026-09-23
    /// §3). Lives HERE, not in `MacChatView` (which is `.id(id)`-keyed per
    /// selection and torn down on every conversation switch), so it
    /// survives a switch and is part of the place the Back/Forward
    /// history records. Tagged with its owning conversation: each chat
    /// reads it through `paneRouteBinding(for:)`, which shows a non-owner
    /// the switch reset. `MacChatView` keeps its local states in step
    /// through that binding. (Replaces the I5-era `itemsPaneOpen` Bool.)
    @State private var paneRoute = MacOwnedPaneRoute()
    /// The window's Back/Forward history (spec 2026-09-23 §2, §4). Fed by
    /// `recordPlace` from the `onChange` on `currentPlace`; read from the
    /// body only through `canGoBack` / `canGoForward` (the two buttons).
    @State private var history = MacNavigationHistory()
    /// A conversation Back/Forward restored after it left the list (see
    /// `restore`). Shown as "Select a chat" while it's selected and still
    /// absent; a rejoin brings its summary back and it opens again.
    @State private var staleRestoredID: String?
    /// App shell (spec §5): which top-level surface the sidebar's nav
    /// column has selected. Internal (not private) so tests can read the
    /// default. Also driven by ⌘1/⌘2/⌘3 via the command bus.
    @State var nav: MacNav = .conversations
    /// The per-session Decisions view model (`ItemsPanelViewModel(convoID:
    /// nil)`): created and started once the session resolves, kept
    /// running whichever entry is selected so the badge is live, stopped
    /// in `onDisappear` (sign-out tears this view down).
    @State private var decisionsVM: ItemsPanelViewModel?
    @State private var decisionsPaneState = MacItemsPaneState(surfaceName: "decisions")
    @State private var selectedDecisionID: String?
    @State private var decisionsOriginTitles: [String: String] = [:]
    /// The per-session Missions list view model, started/stopped the same
    /// way as `decisionsVM` so the nav badge stays live across entries.
    @State private var missionsVM: MissionsListViewModel?
    /// Mirrors `missionsVM?.isSupported`, treating `nil` (VM absent, or
    /// its own `isSupported` not yet known) the same way `isSupported ==
    /// nil` is treated everywhere else — as supported, not hidden — so
    /// this defaults `true` (CodeRabbit #209 fix round 2, H2: a `false`
    /// default only ever deferred showing the entry by the one tick
    /// between VM creation and `supportedStream()`'s first, optimistic
    /// yield, and diverged from how `DecisionsListView.Model.isSupported`
    /// treats its own `nil`). Wired by
    /// `.onChange(of: missionsVM?.isSupported)`; kept as its own `@State`
    /// (rather than read inline) because `setMissionsSupported` is the
    /// one place, mirroring iOS `AppShellNavigation.missionsSupported`'s
    /// `didSet`, that walks a selected `.missions` `nav` back to
    /// `.conversations` the instant support is PROVEN false.
    @State private var missionsSupported = true
    @State private var selectedMissionID: String?
    /// Set when a mission page was opened from a conversation title, so the
    /// page can offer a way back to it.
    @State private var missionBackConvoID: String?
    /// Phase 6 (Search): the shared search VM, built once the session + index
    /// resolve and the chat list has loaded (so chat-title hits have a snapshot).
    /// A non-empty `searchModel.query` swaps the detail column for
    /// `MacSearchResultsView`. `focusSearch` is flipped by ⌘F ("Find in Chat").
    @State private var searchModel: SearchViewModel?
    @State private var focusSearch = false
    /// The coordinator conversation (spec §5b). `session` arrives through
    /// the environment, so this can't be an `@AppStorage` with a per-user
    /// key; it mirrors the defaults key instead and refreshes on every
    /// `UserDefaults` change (Settings' Change/Clear). Read only through
    /// `coordinatorConvoID`.
    @State private var coordinatorSettingID: String?
    /// Whether the setting has been read from the cache yet — see
    /// `resolvedCoordinatorID` (Bugbot B2, PR #234).
    @State private var coordinatorResolved = false
    @State private var showingCoordinatorChooser = false
    @State private var coordinatorError: String?
    /// The Coordinator panel (spec §3b), per window: `SceneStorage` restores
    /// each window's own open/closed and width. The container reads both,
    /// and reports the width it draws to the header (so the header's
    /// inset has no second source).
    @SceneStorage("coordinator.panel.open") private var coordinatorPanelOpen = false
    @SceneStorage("coordinator.panel.width") private var coordinatorPanelWidth: Double = Double(MacCoordinatorPanelLayout.idealWidth)
    /// The panel chat's own view models — see `MacCoordinatorPanel.vmCache`.
    @State private var coordinatorVMCache = ChatVMCache()
    /// The panel's screen region, asked by ⌘F whether keyboard focus sits
    /// in the panel (tracker #2864 A).
    @State private var coordinatorFocusRegion = MacFocusRegion()
    /// Whether the detail's / the panel's chat column is on screen, for
    /// ⌘F (review I3) — see `MacChatColumnPresence`.
    @State private var mainColumnPresence = MacChatColumnPresence()
    @State private var panelColumnPresence = MacChatColumnPresence()
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

    /// Every chat-list summary, the Coordinator's included (it is left out
    /// of the list, not out of search or stale-restore checks). Used to
    /// seed and refresh the search VM. Hoisted into a typed property so the
    /// large `body` doesn't infer it inline — that tipped the Xcode 16.4
    /// type-checker over its time budget once the search-refresh
    /// `.onChange` was added.
    private var allChatSummaries: [ChatSummary] {
        viewModel.allSummaries
    }

    private func isStaleRestore(_ id: String) -> Bool {
        id == staleRestoredID && !allChatSummaries.contains { $0.id == id }
    }

    /// Hoisted for the same type-checker-budget reason as
    /// `allChatSummaries`: `searchModel?.query.isEmpty ?? true` inline in
    /// an `.onChange` broke Xcode 16.4's `body` type-check on CI.
    private var searchQueryIsEmpty: Bool {
        searchModel?.query.isEmpty ?? true
    }

    private func handleSelectionChange(_ old: ChatSummary.ID?, _ new: ChatSummary.ID?) {
        listLogger.notice("sidebar selection: \(old ?? "nil", privacy: .public) → \(new ?? "nil", privacy: .public)")
        // Navigating to a conversation — sidebar click, notification tap,
        // auto-open — means "show me that chat". While search results occupy
        // the detail column only a *result* click cleared the query, so a
        // sidebar click changed the selection underneath but left the results
        // panel covering the chat (Dan, 2026-08-06: "stuck on the search
        // results"). Clearing here swaps the detail back for every selection
        // source; the search-hit handlers' own clear becomes a no-op.
        // Every path that selects a conversation — sidebar click, deep link,
        // auto-open, search hit, "Open conversation" from Decisions — means
        // "show me that chat": bring the Conversations entry forward first.
        if new != nil { nav = .conversations }
        if new != nil, searchQueryIsEmpty == false {
            searchModel?.query = ""
        }
    }

    private func logDetailSwap(_ wasEmpty: Bool, _ isEmpty: Bool) {
        listLogger.notice("detail column swapped: \(isEmpty ? "search → chat" : "chat → search", privacy: .public)")
    }

    /// The sidebar column's content: the fixed nav column plus whichever
    /// list the selected entry shows. Hoisted out of `body` — with the
    /// width triple below it tipped Xcode 16.4's type-checker budget on
    /// CI ("unable to type-check this expression in reasonable time").
    @ViewBuilder
    private var sidebarStack: some View {
        HStack(spacing: 0) {
            MacNavColumn(selection: $nav,
                         badges: [.decisions: decisionsVM?.awaitingYouCount ?? 0,
                                  .missions: missionsVM?.needsYouTotal ?? 0],
                         missionsSupported: missionsSupported)
            Divider()
            switch nav {
            case .conversations:
                sidebarColumn
            case .missions:
                missionsColumn
            case .decisions:
                decisionsColumn
            }
        }
    }

    /// Sidebar column min/ideal/max: the list's 260/400/600 plus the fixed
    /// 72 pt nav column (spec §5), the same for every entry.
    static let sidebarWidths: (min: CGFloat, ideal: CGFloat, max: CGFloat) =
        (260 + MacNavColumn.width, 400 + MacNavColumn.width, 600 + MacNavColumn.width)

    /// The place the shell's state describes (spec §1), normalised: only
    /// the fields the selected nav entry shows are carried, so a change
    /// to something off-screen (an auto-open moving the Conversations
    /// selection while a mission is read) is not a new place. "Select a
    /// chat" (`nil` selection) shows no pane, so it carries no route.
    static func place(nav: MacNav, selectedSummaryID: String?, selectedMissionID: String?,
                      selectedDecisionID: String?, paneRoute: MacChatPaneRoute?) -> MacPlace {
        switch nav {
        case .conversations:
            return MacPlace(detail: .conversation(id: selectedSummaryID, pane: selectedSummaryID == nil ? nil : paneRoute))
        case .missions:
            return MacPlace(detail: .mission(id: selectedMissionID))
        case .decisions:
            return MacPlace(detail: .decision(id: selectedDecisionID))
        }
    }

    /// The owned route after the window lands on `place` (spec §3).
    /// Landing on a chat that doesn't own the route (a click, ⌘1, a
    /// notification) claims the switch reset for it, so the old owner's
    /// pushed item or sub-chat can't resurface on a later click back
    /// (CodeRabbit, PR #233). A restore already set the owner to the
    /// place's chat, so it's kept as restored. A place that shows no chat
    /// drops the owner but keeps the route, so coming back to a chat by
    /// any means but Back resets like a click, and an open pane stays open
    /// on its list. The place itself never changes here: it reads the
    /// same `route(for:)` value either way.
    static func paneRoute(_ owned: MacOwnedPaneRoute, landingOn place: MacPlace) -> MacOwnedPaneRoute {
        guard let shown = place.displayedConversationID else {
            return owned.owner == nil ? owned : MacOwnedPaneRoute(owner: nil, route: owned.route)
        }
        guard shown != owned.owner else { return owned }
        return MacOwnedPaneRoute(owner: shown, route: owned.route(for: shown))
    }

    /// The route binding handed to the chat `id` shows. Reads resolve
    /// through `MacOwnedPaneRoute.route(for:)`, and writes claim the route
    /// for `id`.
    private func paneRouteBinding(for id: String) -> Binding<MacChatPaneRoute?> {
        Binding(
            get: { paneRoute.route(for: id) },
            set: { route in
                let next = MacOwnedPaneRoute(owner: id, route: route)
                if paneRoute != next { paneRoute = next }
            }
        )
    }

    private var currentPlace: MacPlace {
        Self.place(nav: nav, selectedSummaryID: selectedSummaryID, selectedMissionID: selectedMissionID,
                   selectedDecisionID: selectedDecisionID,
                   paneRoute: paneRoute.route(for: selectedSummaryID))
    }

    /// The detail column for the selected nav entry. Hoisted out of
    /// `body` for the same type-checker-budget reason as `sidebarStack`.
    @ViewBuilder
    private var detailContent: some View {
        switch nav {
        case .conversations:
            if let searchModel, !searchModel.query.isEmpty {
                // Phase 6 (Search): a non-empty query replaces the chat detail
                // with the results panel. Selecting a result clears the query
                // (restoring the chat detail) and points the sidebar selection
                // at the chosen room.
                MacSearchResultsView(
                    viewModel: searchModel,
                    onSelectChat: { chat in
                        listLogger.notice("selection set by search-chat-hit: \(chat.id, privacy: .public)")
                        showConversation(chat.id)
                    },
                    onSelectMessage: { group in
                        // Opens the chat with its in-conversation search
                        // armed: the bar comes up, and the timeline jumps
                        // to the newest match (paging history back as
                        // needed — same machinery as a TOC jump).
                        listLogger.notice("selection set by search-message-hit: \(group.roomID, privacy: .public)")
                        let query = searchModel.trimmedQuery
                        // The Coordinator's hits open the panel (spec §3b).
                        showConversation(group.roomID)
                        // Only top-level chats get the bar: a hit in a
                        // subagent child (indexed like any convo, but
                        // absent from the list snapshot) opens in
                        // MacSubChatPane, which renders no ChatSearchBar —
                        // arming there would run an invisible, undismissable
                        // search (review 2026-08-26).
                        if let deps, let session,
                           allChatSummaries.contains(where: { $0.id == group.roomID }) {
                            let (chat, _) = chatCache(for: group.roomID).viewModels(for: group.roomID, deps: deps, session: session)
                            Task { await chat.beginChatSearch(query: query) }
                        }
                    }
                )
            } else {
                detail
            }
        case .missions:
            missionDetail
        case .decisions:
            decisionsDetail
        }
    }

    /// The split view itself — sidebar (nav column + list) and detail —
    /// kept apart from the two modifier stacks below so each expression
    /// stays inside Xcode 16.4's type-checker budget on CI (it timed out
    /// twice on `body` once the nav column landed).
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarStack
                // Drop the system sidebar-collapse toolbar button. The
                // ⌘⇧S menu item / `.toggleSidebar` notification handler
                // still collapses the sidebar; only the redundant toolbar
                // chevron is removed.
                .toolbar(removing: .sidebarToggle)
                // MUST come after `.toolbar(removing: .sidebarToggle)`
                // (macOS 26).
                .navigationSplitViewColumnWidth(min: Self.sidebarWidths.min, ideal: Self.sidebarWidths.ideal,
                                                max: Self.sidebarWidths.max)
                .toolbar {
                    // Spec 2026-09-23 §5: the window's Back/Forward,
                    // top-left in the SIDEBAR section — see
                    // `MacHistoryToolbarItems`.
                    MacHistoryToolbarItems(history: history, goBack: goBack, goForward: goForward)
                    // Coordinator redesign §3b: the panel toggle, also in
                    // the SIDEBAR section — nothing may sit under the chat
                    // header accessory (#2608).
                    MacCoordinatorToolbarToggle(isOpen: coordinatorPanelOpen,
                                                hasUnread: MacCoordinatorToolbarToggle.hasUnread(viewModel.hiddenSummary)) {
                        toggleCoordinatorPanel()
                    }
                    // With the sidebar toggle removed the new-chat button
                    // is the only item in the sidebar section and packs
                    // to its leading edge; the flexible spacer pushes it
                    // to the sidebar's trailing edge (Dan, 2026-07-15).
                    // `ToolbarSpacer` needs the macOS 26 SDK (Swift 6.2
                    // toolchain) — CI's Xcode 16.4 compiles without it.
                    #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                    }
                    #endif
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingNewChat = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New chat")
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
        } detail: {
            // The chat header rides in the window's title bar, fed by
            // whichever chat column is mounted in here — `MacChatHeaderHost`.
            // The Coordinator panel sits beside every nav entry's detail,
            // inside the host so it reports the width it draws.
            MacChatHeaderHost {
                MacCoordinatorPanelContainer(isOpen: coordinatorPanelOpen, width: $coordinatorPanelWidth) {
                    // Through the environment, not a `MacChatView` argument:
                    // the chat sits inside `MacChatDetailGate`, whose key
                    // would otherwise have to carry it.
                    detailContent
                        .environment(\.macComposerSoleInWindow, !coordinatorPanelOpen)
                        .environment(\.macChatColumnPresence, mainColumnPresence)
                } panel: {
                    coordinatorPanel
                        .environment(\.macChatColumnPresence, panelColumnPresence)
                        .background(MacFocusRegionProbe(region: coordinatorFocusRegion))
                }
            }
        }
    }

    private func toggleCoordinatorPanel() { coordinatorPanelOpen.toggle() }

    /// The Coordinator id in this user's cached setting (nil signed out).
    private func cachedCoordinatorConvoID() -> String? {
        guard let session else { return nil }
        return CoordinatorSetting(userID: session.userID).convoID
    }

    private func readCoordinatorSetting() {
        coordinatorSettingID = cachedCoordinatorConvoID()
        if session != nil { coordinatorResolved = true }
    }

    /// The Coordinator id for EVERY consumer — the panel, `showConversation`,
    /// `chatCache`, the detail, restores and the list filter — so they can
    /// never disagree (Bugbot, PR #238: a cold-start notification tap routed
    /// on the unread state while a restored panel showed the cached id, and
    /// both columns mounted the Coordinator on different view-model caches).
    private var coordinatorConvoID: String? {
        Self.resolvedCoordinatorID(state: coordinatorSettingID, resolved: coordinatorResolved,
                                   cached: cachedCoordinatorConvoID)
    }

    /// Until the `.task` has read the cache, the cache is read directly —
    /// otherwise a panel restored open by `@SceneStorage` flashes "Choose a
    /// conversation…" (Bugbot B2, PR #234) and routing sees no Coordinator.
    static func resolvedCoordinatorID(state: String?, resolved: Bool, cached: () -> String?) -> String? {
        resolved ? state : cached()
    }

    /// Hides the new Coordinator from the list and, when it is the chat
    /// open in the detail, moves it into the panel.
    private func coordinatorChanged(to id: String?) {
        viewModel.hiddenConversationID = id
        let landing = Self.landingAfterCoordinatorChange(selected: selectedSummaryID, coordinatorConvoID: id)
        if landing.selection != selectedSummaryID { selectedSummaryID = landing.selection }
        if landing.opensPanel { coordinatorPanelOpen = true }
    }

    private var coordinatorPanel: some View {
        MacCoordinatorPanel(
            coordinatorConvoID: coordinatorConvoID,
            chatListVM: viewModel, vmCache: coordinatorVMCache,
            onChoose: { showingCoordinatorChooser = true },
            onClose: { coordinatorPanelOpen = false },
            onOpenConversation: openFromCoordinator,
            onOpenMission: { showMission($0, from: nil) })
    }

    /// "Open" on a session the Coordinator started: shown in the detail,
    /// the panel stays.
    private func openFromCoordinator(_ roomID: String) {
        guard let deps, let session else { return }
        Task { @MainActor in
            await deps.prepareConversation(for: session, id: roomID)
            showConversation(roomID)
        }
    }

    /// The view-model cache that owns `convoID`'s chat: the panel's for the
    /// Coordinator, the detail's for everything else.
    private func chatCache(for convoID: String) -> ChatVMCache {
        Self.conversationTarget(convoID, coordinatorConvoID: coordinatorConvoID) == .panel ? coordinatorVMCache : vmCache
    }

    /// Where "show me that conversation" lands (spec §3b). A pure helper so
    /// `MacMissionsNavTests` pins it.
    enum ConversationTarget: Equatable { case panel, detail }

    /// Back/Forward onto a place showing the Coordinator's conversation
    /// opens the panel. The selection keeps the place's id (rewriting it
    /// would record a new place and cut Forward off); `detailShowsChat`
    /// keeps the detail on "Select a chat" meanwhile.
    static func restoreOpensPanel(_ id: String?, coordinatorConvoID: String?) -> Bool {
        guard let id else { return false }
        return conversationTarget(id, coordinatorConvoID: coordinatorConvoID) == .panel
    }

    /// Whether the detail builds a chat for the selection: never for a
    /// stale restore, and never for the Coordinator — it lives in the
    /// panel, and two mounts of one conversation would share a composer.
    static func detailShowsChat(_ id: String?, coordinatorConvoID: String?, isStaleRestore: Bool) -> Bool {
        guard let id, !isStaleRestore else { return false }
        return conversationTarget(id, coordinatorConvoID: coordinatorConvoID) == .detail
    }

    struct ConversationLanding: Equatable { var selection: String?; var opensPanel: Bool }

    /// The open conversation just became the Coordinator (Settings, the
    /// chooser, another device): it moves out of the detail into the panel.
    static func landingAfterCoordinatorChange(selected: String?, coordinatorConvoID: String?) -> ConversationLanding {
        guard let selected, conversationTarget(selected, coordinatorConvoID: coordinatorConvoID) == .panel else {
            return .init(selection: selected, opensPanel: false)
        }
        return .init(selection: nil, opensPanel: true)
    }

    static func conversationTarget(_ convoID: String, coordinatorConvoID: String?) -> ConversationTarget {
        if let coordinatorConvoID, !coordinatorConvoID.isEmpty, convoID == coordinatorConvoID { return .panel }
        return .detail
    }

    /// Menu-bar / command-bus listeners and the search wiring.
    private func withCommandListeners(_ content: some View) -> some View {
        content
            // Build the shared search VM once the chat list has loaded (so chat-title
            // hits have a snapshot). Keyed on `groups.isEmpty` so it fires when the
            // first snapshot lands; the `searchModel == nil` guard keeps it a
            // one-shot build. Task 12 drops the backfill-progress wiring —
            // `SearchViewModel` no longer has `observeBackfill(_:)` (Task 11
            // dropped it on the iOS side of this same journal-stack rewire; the
            // journal server has no backfill concept to observe).
            .task(id: viewModel.hasChats) {
                guard searchModel == nil, viewModel.hasChats,
                      let search = deps?.search else { return }
                searchModel = SearchViewModel(search: search, allChats: allChatSummaries)
            }
            // Breadcrumb every selection flip — user click, auto-open,
            // notification tap, or (the pathological case) the List clearing
            // its own selection during a snapshot rebuild. Rare + un-gated.
            // Log bodies live in helper funcs: inline interpolations here
            // helped tip Xcode 16.4's type-checker budget for this `body`
            // (CI "unable to type-check in reasonable time" — same class as
            // the `allChatSummaries` hoist above).
            .onChange(of: selectedSummaryID, handleSelectionChange)
            // The search branch swap destroys/remounts the chat detail — log
            // the flips so a detail remount can be attributed to it.
            .onChange(of: searchQueryIsEmpty, logDetailSwap)
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
                    listLogger.notice("selection set by notification-tap: \(roomID, privacy: .public)")
                    showConversation(roomID)
                }
            }
    }

    /// Nav-entry commands, coordinator wiring and the Back/Forward history
    /// observers. Split from `withCommandListeners` so neither chain blows
    /// CI Xcode 16.4's type-checker budget (PR #233).
    private func withNavigationListeners(_ content: some View) -> some View {
        content
            // ⌘1/⌘2/⌘3 (Commands.swift) — same bus shape as `.toggleSidebar`.
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showMissions))) { _ in
                // An old journal has no Missions entry to select.
                if missionsSupported { nav = .missions }
            }
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showConversations))) { _ in nav = .conversations }
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showDecisions))) { _ in nav = .decisions }
            // Go ▸ Back / Forward, ⌘[ / ⌘] (spec 2026-09-23 §5): published
            // to the menu bar for THIS window only, unlike the bus above;
            // history is per window (PR #233 review I1).
            .focusedSceneValue(\.macNavigation, navigationActions)
            // Leaving Decisions through the nav column (Bugbot, PR #195): the
            // detail host has no teardown of its own (I6 — a same-item rebuild
            // must keep the draft), so stop its VM and any recording here and
            // clear the pane's item id so re-entering rebuilds the detail.
            .task(id: session?.userID) { readCoordinatorSetting() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                readCoordinatorSetting()
            }
            .onChange(of: nav, navChanged)
            // Spec 2026-09-23 §4: every way of moving between places ends in
            // one of the states `currentPlace` derives from, so this single
            // observer records them all — clicks, ⌘1/2/3, notification taps,
            // search hits, item links, milestone jumps, pane pushes and pops.
            // `initial: true` seeds the history with the first place so the
            // first move away has somewhere to go back to.
            .onChange(of: currentPlace, initial: true) { _, place in recordPlace(place) }
            // A later selection of anything else ends a stale restore, so a
            // notification tap or auto-open of that id opens it normally
            // (Bugbot, #233).
            .onChange(of: selectedSummaryID) { _, id in
                if id != staleRestoredID { staleRestoredID = nil }
            }
            // Optional chaining through `missionsVM?` already flattens to
            // a plain `Bool?` (fix round 3, N4: the earlier `?? nil` was
            // a no-op) — nil either way means "not proven false," never
            // coerced with `??` into a premature answer, so it reaches
            // `setMissionsSupported`'s `!= false` comparison untouched.
            .onChange(of: missionsVM?.isSupported) { _, supported in setMissionsSupported(supported != false) }
    }

    /// Coordinator wiring: the list filter, the chooser (opened from the
    /// panel's empty state) and its save error. Its own helper for CI's
    /// Xcode 16.4 type-checker budget (PR #233).
    private func withCoordinatorPanel(_ content: some View) -> some View {
        content
            // The Coordinator's conversation lives in the panel, not the
            // Conversations list (spec §3b).
            .onChange(of: coordinatorConvoID, initial: true) { _, id in coordinatorChanged(to: id) }
            .sheet(isPresented: $showingCoordinatorChooser) {
                if let deps, let session {
                    MacCoordinatorChooserSheet(deps: deps, session: session) { id in
                        showingCoordinatorChooser = false
                        // The cache (and so `coordinatorConvoID`, via the
                        // UserDefaults observer) follows the journal.
                        Task { @MainActor in coordinatorError = await deps.setCoordinator(id, for: session) }
                    }
                }
            }
            .alert("Coordinator", isPresented: Binding(get: { coordinatorError != nil },
                                                       set: { if !$0 { coordinatorError = nil } })) {
                Button("OK") { coordinatorError = nil }
            } message: {
                Text(coordinatorError ?? "")
            }
    }

    /// Origins whose labels the Decisions and Unassigned rows draw — a
    /// typed property, not an inline expression, for CI's Xcode 16.4
    /// type-checker.
    private var originConvoIDs: [String] {
        let decisions: [String] = decisionsVM?.awaitingYou.map(\.originConvoID) ?? []
        let unassigned: [String] = missionsVM?.unassigned.map(\.originConvoID) ?? []
        return decisions + unassigned
    }

    /// Lifecycle: view-model start/stop, decisions VM, sync-state and
    /// auto-open streams, the New Chat sheet, and the dock badge.
    private func withLifecycle(_ content: some View) -> some View {
        content
            // The Decisions VM lives for the session (spec §5b): one instance,
            // started here, feeding both the list and the nav badge.
            .task(id: session?.userID) {
                guard let deps, let session else { return }
                decisionsVM?.stop()
                let vm = deps.makeDecisionsViewModel(for: session)
                decisionsVM = vm
                vm.start()
            }
            .task(id: originConvoIDs) {
                guard let deps, let session else { return }
                let labels = (try? await deps.journalStore(for: session).conversationOriginLabels()) ?? [:]
                // A cancelled task's read still completes (GRDB's async read
                // does not honour cancellation); it must not overwrite what
                // its successor wrote (CodeRabbit, PR #223).
                guard !Task.isCancelled else { return }
                decisionsOriginTitles = labels
            }
            // The Missions VM lives for the session too, same reasoning as
            // decisionsVM above — one instance, feeding both the list and
            // the nav badge.
            .task(id: session?.userID) {
                guard let deps, let session else { return }
                missionsVM?.stop()
                let vm = deps.makeMissionsListViewModel(for: session)
                missionsVM = vm
                vm.start()
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
                    listLogger.notice("selection set by cold-start-tap-drain: \(pending, privacy: .public)")
                    showConversation(pending)
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
                    MacNewChatSheet(deps: deps, session: session,
                                    windowSize: NSApp.keyWindow?.contentLayoutRect.size) { convoID in
                        showingNewChat = false
                        // Select the new chat; the newConversations auto-open
                        // (below) may deliver the same id when the convo_meta
                        // lands — setting an identical selection is a no-op.
                        listLogger.notice("selection set by new-chat-sheet: \(convoID, privacy: .public)")
                        showConversation(convoID)
                    }
                } else {
                    MacNewChatPlaceholder(onDismiss: { showingNewChat = false })
                }
            }
            .task { viewModel.start() }
            #if DEBUG
            // Screenshot-rig hook: MATRON_DEBUG_OPEN_CONVO=<id> selects that
            // conversation once it syncs in, so an unattended capture can show
            // a chat without injected clicks. See DebugSnapshot.swift.
            .task {
                guard let target = ProcessInfo.processInfo.environment["MATRON_DEBUG_OPEN_CONVO"] else { return }
                for _ in 0..<100 {
                    if viewModel.groups.contains(where: { $0.summaries.contains(where: { $0.id == target }) }) {
                        selectedSummaryID = target
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            #endif
            .onDisappear {
                viewModel.cancel()
                decisionsVM?.stop()
                missionsVM?.stop()
                decisionsPaneState.releaseAllSlots()
                decisionsPaneState.cancelRecording()
            }
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
                    // Catch-up counts: the socket IS established there, so a
                    // drop mid-replay should come back as "Reconnecting…".
                    if state == .running || state == .catchingUp { hasEverConnected = true }
                }
            }
            // Auto-open a conversation the bridge just created while we're live
            // (e.g. the user sent /start). The engine only emits ids for convos
            // born while running, so this won't fire for the cold-start /
            // reconnect backlog. Drives the same `selectedSummaryID` the
            // notification-tap deep link uses, so the detail column flips to the
            // new chat without the user hunting for it. Mirrors the iOS host.
            .task(id: session?.userID) {
                guard let deps, let session else { return }
                for await roomID in await deps.syncService(for: session).newConversations() {
                    listLogger.notice("selection set by auto-open: \(roomID, privacy: .public)")
                    showConversation(roomID)
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

    var body: some View {
        withLifecycle(withCoordinatorPanel(withNavigationListeners(withCommandListeners(splitView))))
    }

    /// Sidebar column wrapper: connection banner (when not `.running`)
    /// stacked over the search field stacked over the chat list. The
    /// search field lives at the top of the conversation list — it used
    /// to sit in the window toolbar's `.principal` slot, which floated
    /// it over the detail column instead of with the list it filters.
    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            if connectionState != .running {
                // Connection-state banner sits at the very top so the
                // user's first read of the sidebar is "what's the
                // current sync status?" before anything else competes
                // for attention.
                ConnectionStatusBanner(
                    state: connectionState,
                    hasEverConnected: hasEverConnected
                )
                .animation(.easeInOut(duration: 0.2), value: connectionState)
            }
            if let searchModel {
                // Top padding is tighter than bottom so the field sits a
                // few px higher, closer to the toolbar.
                MacSearchView(viewModel: searchModel, focusRequest: $focusSearch)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
            sidebar
        }
        .onAppear { LaunchTimeline.shared.mark(.firstListPaint) }
    }

    private var sidebar: some View {
        MacChatSidebarList(
            viewModel: viewModel, selection: $selectedSummaryID,
            onSummariesChange: { searchModel?.updateChats($0) },
            runChatAction: runChatAction
        )
    }

    /// Decisions selected (spec §5): the list column is the shared
    /// `DecisionsListView`; a row selects the detail on the right.
    @ViewBuilder
    private var decisionsColumn: some View {
        if let decisionsVM {
            DecisionsListView(
                model: .init(
                    rows: decisionsVM.awaitingYou.map { .init(item: $0, originTitle: decisionsOriginTitles[$0.originConvoID]) },
                    isSupported: decisionsVM.isSupported,
                    isRefreshing: decisionsVM.isRefreshing),
                // Ends any in-flight recording that belongs to a
                // DIFFERENT item before the re-select commits — a row
                // click is a navigation like any other (#115, fix round
                // 8).
                onSelect: { id in showDecisionsItem(id) },
                onOpenConversation: openConversationFromDecisions,
                onRefresh: { await decisionsVM.refresh() }
            )
            .alert("Tracker", isPresented: Binding(get: { decisionsVM.error != nil }, set: { if !$0 { decisionsVM.error = nil } })) {
                Button("OK") { decisionsVM.error = nil }
            } message: {
                Text(decisionsVM.error ?? "")
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var decisionsDetail: some View {
        if let id = selectedDecisionID, let session {
            // The `\.openTrackerItem` host for this surface is
            // `MacItemDetailHost` itself (item #115) — one install, on the
            // container that owns the navigation, rather than a wrapper
            // here re-applying it around every child.
            MacItemDetailHost(itemID: id, session: session, currentConvoID: nil,
                              state: decisionsPaneState, onOpenConversation: openConversationFromDecisions,
                              // Decisions is a two-column list+detail with
                              // NO navigation stack of its own, so an item
                              // link genuinely can only re-select — the same
                              // thing a row tap does. Everywhere there IS a
                              // stack (the Mac items pane, both iOS
                              // surfaces) the link pushes instead.
                              onOpenItem: { id in showDecisionsItem(id) },
                              // No navigation stack here — `decisionsPaneState.path`
                              // stays empty, so this host owns its own slot
                              // release and is on screen whenever it exists.
                              surface: .stackless)
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "checkmark.circle",
                description: Text("Pick something that needs you from the list."))
        }
    }

    /// "Open conversation" from a Decisions row or its detail: switch the
    /// nav entry, then select that chat (spec §5).
    private func openConversationFromDecisions(_ convoID: String) {
        listLogger.notice("selection set by decisions: \(convoID, privacy: .public)")
        showConversation(convoID)
    }

    /// Open a Decisions item — the three-way "select a row / re-select from
    /// its own detail / arrive from another nav entry" triplet, in one
    /// place so they cannot diverge (MINOR-9; the mission page's own site
    /// used to be the one that added `nav = .decisions` and the other two
    /// didn't).
    private func showDecisionsItem(_ id: String, switchingNav: Bool = false) {
        if switchingNav { nav = .decisions }
        decisionsPaneState.cancelRecordingIfNavigating(to: id)
        selectedDecisionID = id
    }

    /// Every place change lands here (the `onChange` on `currentPlace`).
    /// A restore's own landing is a no-op inside `visit`. Leaving every
    /// chat drops the route's owner (`paneRoute(_:landingOn:)`); that
    /// doesn't change the place, so it can't record twice.
    private func recordPlace(_ place: MacPlace) {
        let owned = Self.paneRoute(paneRoute, landingOn: place)
        if owned != paneRoute { paneRoute = owned }
        guard Self.isRecordable(place, historyIsEmpty: history.current == nil) else { return }
        history.visit(place)
    }

    /// The empty launch state ("Select a chat" before anything is picked)
    /// isn't a place to go back to. A cold-start notification tap or a
    /// new-chat auto-open selects a chat a beat after the first frame, and
    /// recording that first frame made the first Back land on an empty
    /// detail (PR #233 review M3). Once history has a place, "Select a
    /// chat" records like any other place.
    static func isRecordable(_ place: MacPlace, historyIsEmpty: Bool) -> Bool {
        !(historyIsEmpty && place == MacPlace(detail: .conversation(id: nil, pane: nil)))
    }

    /// Writes a popped place back into the shell's state (spec §4). Direct
    /// assignments, not `showConversation` — the place already says which
    /// entry it was under — keeping the two side effects that protect other
    /// state: a decision's recording guard, and the search-query clear so
    /// the results panel cannot stay over a restored chat.
    private func restore(_ place: MacPlace) {
        listLogger.log("history restore \(String(describing: place.detail), privacy: .public)")
        switch place.detail {
        case .conversation(let id, let pane):
            nav = .conversations
            if searchQueryIsEmpty == false { searchModel?.query = "" }
            // A conversation left since this place was recorded: keep the
            // selection (so the place, and Forward past it, stay intact)
            // but show "Select a chat" instead of building a dead chat.
            // Only restores do this; a fresh room selected before its
            // summary lands still opens (see `detail`).
            staleRestoredID = id.flatMap { id in allChatSummaries.contains { $0.id == id } ? nil : id }
            selectedSummaryID = id
            paneRoute = MacOwnedPaneRoute(owner: id, route: pane)
            // The Coordinator's conversation shows in the panel only.
            if Self.restoreOpensPanel(id, coordinatorConvoID: coordinatorConvoID) { coordinatorPanelOpen = true }
        case .mission(let id):
            // A restored page offers no "back to the conversation": the
            // global Back covers that now (spec §4).
            missionBackConvoID = nil
            selectedMissionID = id
            nav = .missions
        case .decision(let id):
            if let id {
                decisionsPaneState.cancelRecordingIfNavigating(to: id)
            } else {
                // Back onto an empty Decisions selection: no host stays on
                // screen, and `navChanged` won't run if the window is
                // already on Decisions (CodeRabbit, PR #233).
                decisionsPaneState.releaseAllSlots()
                decisionsPaneState.cancelRecording()
            }
            selectedDecisionID = id
            nav = .decisions
        }
    }

    /// The window's Back/Forward for the Go menu.
    private var navigationActions: MacNavigationActions {
        MacNavigationActions(canGoBack: history.canGoBack, canGoForward: history.canGoForward,
                             goBack: { goBack() }, goForward: { goForward() },
                             isCoordinatorOpen: coordinatorPanelOpen,
                             toggleCoordinator: { toggleCoordinatorPanel() },
                             findInChat: Self.canFindInChat(panelHasChat: panelChatID() != nil,
                                                            panelColumnShown: panelColumnPresence.isShown,
                                                            onConversations: nav == .conversations)
                                 ? { findInChat() } : nil,
                             searchAllChats: Self.canSearchAllChats(onConversations: nav == .conversations)
                                 ? { searchAllChats() } : nil)
    }

    /// Edit ▸ Find in Chat (tracker #2864 A): opens the search bar, empty
    /// and focused, on the chat with focus in THIS window — the panel's
    /// when focus is in the panel, else the main chat. With no chat on
    /// screen it falls back to the sidebar field, ⌘F's job before.
    private func findInChat() {
        let panelChatID = panelChatID().flatMap { panelColumnPresence.isShown ? $0 : nil }
        let mainChatID = mainChatOnScreen()
        let target = MacFindInChatRouting.target(
            focusInPanel: coordinatorPanelOpen && coordinatorFocusRegion.containsFirstResponder(),
            panelHasChat: panelChatID != nil, mainHasChat: mainChatID != nil,
            globalSearchAvailable: nav == .conversations)
        switch target {
        case .panel: openChatSearch(panelChatID, in: coordinatorVMCache)
        case .main: openChatSearch(mainChatID, in: vmCache)
        case .globalSearch: searchAllChats()
        case nil: break
        }
    }

    /// The Coordinator chat in the open panel, if one is set.
    private func panelChatID() -> String? {
        guard coordinatorPanelOpen else { return nil }
        guard let id = coordinatorConvoID, !id.isEmpty else { return nil }
        return id
    }

    /// The chat the detail column shows — see `mainChatForFind`.
    private func mainChatOnScreen() -> String? {
        let shownID = selectedSummaryID.flatMap { id in
            Self.detailShowsChat(id, coordinatorConvoID: coordinatorConvoID,
                                 isStaleRestore: isStaleRestore(id)) ? id : nil
        }
        return Self.mainChatForFind(onConversations: nav == .conversations,
                                    searchResultsShown: !(searchModel?.query.isEmpty ?? true),
                                    selectedChatShown: shownID, columnShown: mainColumnPresence.isShown)
    }

    /// ⌘F's main-chat target: on Conversations, no search results over the
    /// detail, a selection that renders a chat, and that chat's column
    /// actually on screen — not replaced by a sub-chat or the items pane
    /// in a narrow detail, where the bar would open invisibly (review I3).
    static func mainChatForFind(onConversations: Bool, searchResultsShown: Bool,
                                selectedChatShown: String?, columnShown: Bool) -> String? {
        guard onConversations, !searchResultsShown, columnShown else { return nil }
        return selectedChatShown
    }

    /// Whether Edit ▸ Find in Chat is enabled (review M2): a Coordinator
    /// chat in the open panel with its column on screen (Tasks or a
    /// sub-chat can take the always-narrow panel over — Bugbot, PR #236),
    /// or Conversations, whose sidebar field is the fallback when no chat
    /// is on screen.
    static func canFindInChat(panelHasChat: Bool, panelColumnShown: Bool, onConversations: Bool) -> Bool {
        (panelHasChat && panelColumnShown) || onConversations
    }

    private func openChatSearch(_ convoID: String?, in cache: ChatVMCache) {
        guard let convoID, let deps, let session else { return }
        cache.viewModels(for: convoID, deps: deps, session: session).0.openChatSearch()
    }

    /// Whether Edit ▸ Search All Chats is enabled: its field lives in the
    /// Conversations sidebar (Bugbot, PR #236).
    static func canSearchAllChats(onConversations: Bool) -> Bool {
        onConversations
    }

    /// Edit ▸ Search All Chats (⇧⌘F). Only while the field is mounted
    /// (Conversations): the field consumes the flag in `onChange` and
    /// clears it, so a `true` set while it is absent would stick and turn
    /// every later request into a no-op (Bugbot, PR #195). `navChanged`
    /// clears it on the way out for the same reason.
    private func searchAllChats() {
        guard nav == .conversations else { return }
        focusSearch = true
    }

    private func goBack() {
        guard let place = history.goBack() else { return }
        restore(place)
    }

    private func goForward() {
        guard let place = history.goForward() else { return }
        restore(place)
    }

    @ViewBuilder
    private var missionsColumn: some View {
        if let missionsVM {
            MacMissionsColumn(viewModel: missionsVM, coordinatorConvoID: coordinatorConvoID, originTitles: decisionsOriginTitles,
                              onSelect: { pickMission($0) })
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A sidebar row pick, as opposed to `showMission(_:from:)`'s
    /// title-tap open: no originating conversation, so any "back to the
    /// conversation" affordance a PREVIOUS title-tap open left behind must
    /// clear here too — `navChanged` only clears it on leaving the
    /// Missions entry entirely, not on picking a different mission while
    /// already in it (Bugbot).
    private func pickMission(_ missionID: String) {
        missionBackConvoID = Self.missionBackConvoID(for: .sidebarPick)
        selectedMissionID = missionID
    }

    /// How a mission page was opened — a sidebar row carries no
    /// originating conversation; a title tap remembers the one it came
    /// from. Backs `missionBackConvoID(for:)`, a pure helper so
    /// `MacMissionsNavTests` can pin the rule without needing live view
    /// state (`missionBackConvoID` itself is private `@State`).
    enum MissionOpenSource { case sidebarPick; case titleTap(fromConvoID: String?) }

    /// The back-button conversation id to store for a mission opened via
    /// `source`.
    static func missionBackConvoID(for source: MissionOpenSource) -> String? {
        switch source {
        case .sidebarPick: return nil
        case .titleTap(let convoID): return convoID
        }
    }

    @ViewBuilder
    private var missionDetail: some View {
        if let id = selectedMissionID, let session {
            MacMissionPage(missionID: id, session: session, backConvoID: missionBackConvoID,
                           onBack: showConversation,
                           onOpenMilestone: openMilestone,
                           onOpenItem: { id in
                               // Missions has no stack of its own on the
                               // Mac; an item opens where every item opens.
                               showDecisionsItem(id, switchingNav: true)
                           },
                           onOpenConversation: showConversation)
        } else {
            ContentUnavailableView("Select a mission", systemImage: "flag.checkered",
                                   description: Text("Pick a piece of work from the list."))
        }
    }

    /// The mission page for `missionID`, remembering the conversation it was
    /// opened from so the page can offer a way back.
    private func showMission(_ missionID: String, from convoID: String?) {
        missionBackConvoID = Self.missionBackConvoID(for: .titleTap(fromConvoID: convoID))
        selectedMissionID = missionID
        nav = .missions
    }

    /// A milestone tap: show its conversation, then park the jump on that
    /// room's cached view model — `focusOrPark` fires it once the stream is
    /// live, and a seq that no longer exists lands on the nearest earlier row.
    private func openMilestone(convoID: String, seq: Int64) {
        showConversation(convoID)
        guard let deps, let session else { return }
        let (chat, _) = chatCache(for: convoID).viewModels(for: convoID, deps: deps, session: session)
        Task { await chat.jumpToMilestone(seq: seq) }
    }

    /// Every "show me that chat" path — notification tap, cold-start drain,
    /// new-chat sheet, auto-open, Decisions origin link — goes through
    /// here so the Conversations entry comes forward even when the target
    /// is ALREADY selected (Bugbot, PR #195: the `selectedSummaryID`
    /// `onChange` alone never fires for a same-id assignment).
    /// Just the wire: the clamp that walks a selected `.missions` nav
    /// entry back to `.conversations` on the false edge lives here, in
    /// the setter, not in an `onChange` on `nav` — mirrors iOS
    /// `AppShellNavigation.missionsSupported`'s `didSet`, so a selection
    /// that already landed on `.missions` before the 404 answers is
    /// walked back the instant the flag flips false (CodeRabbit #209).
    private func setMissionsSupported(_ supported: Bool) {
        missionsSupported = supported
        guard !supported, nav == .missions else { return }
        nav = .conversations
    }

    private func navChanged(from old: MacNav, to new: MacNav) {
        listLogger.log("nav \(String(describing: old), privacy: .public) → \(String(describing: new), privacy: .public) decision=\(selectedDecisionID ?? "nil", privacy: .public)")
        // The search field unmounts with Conversations; an unconsumed ⌘F
        // request must not outlive it (Bugbot, PR #195).
        if old == .conversations { focusSearch = false }
        // Clear the back affordance on the way out, so a later visit from
        // the nav column does not offer a stale "back to the conversation".
        if old == .missions, new != .missions { missionBackConvoID = nil }
        guard old == .decisions, new != .decisions else { return }
        decisionsPaneState.releaseAllSlots()
        decisionsPaneState.cancelRecording()
    }

    private func showConversation(_ convoID: String) {
        // The Coordinator opens in the panel (spec §3b); the detail stays
        // where it is.
        if Self.conversationTarget(convoID, coordinatorConvoID: coordinatorConvoID) == .panel {
            coordinatorPanelOpen = true
            if searchQueryIsEmpty == false { searchModel?.query = "" }
            return
        }
        nav = .conversations
        // A same-id assignment never runs `handleSelectionChange`, so the
        // search results panel would stay over the chat (Bugbot, PR #195).
        if searchQueryIsEmpty == false { searchModel?.query = "" }
        selectedSummaryID = convoID
    }

    /// Detail column. Looks up the full `ChatSummary` from
    /// `viewModel.groups` by id, then routes it into `MacChatView`,
    /// which constructs its per-room `ChatViewModel` + `ComposerViewModel`
    /// from the cached `TimelineService` + `MediaService`. The
    /// "select a chat" content-unavailable view is the empty state for a
    /// `nil` selection. A non-nil selection always opens the detail column,
    /// even if `currentSummary` is momentarily `nil` — a conversation the
    /// bridge just created (`/start`) selects the instant its first frame
    /// hits the store, but the sidebar snapshot lands a GRDB
    /// `ValueObservation` main-hop later. `chatDetail(for:)` builds from the
    /// id with a title that fills in live once the snapshot arrives.
    @ViewBuilder
    private var detail: some View {
        if let id = selectedSummaryID,
           Self.detailShowsChat(id, coordinatorConvoID: coordinatorConvoID, isStaleRestore: isStaleRestore(id)) {
            chatDetail(for: id)
        } else {
            ContentUnavailableView(
                "Select a chat",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Pick a conversation from the sidebar.")
            )
        }
    }

    /// Builds the `MacChatView` for the selected id. Wrapped in a helper so
    /// the missing-environment branch (no deps / session) stays out of the
    /// main `body` flow. The `id(id)` modifier forces a fresh instance per
    /// row selection — so `@State` view models reset rather than holding
    /// stale data from the previous room. `currentSummary` may be `nil` for
    /// a just-created room whose sidebar snapshot hasn't landed yet; the
    /// title falls back to empty and fills in live once it does.
    @ViewBuilder
    private func chatDetail(for id: ChatSummary.ID) -> some View {
        if let deps, let session {
            MacChatSummaryReader(viewModel: viewModel, id: id) { summary in
            MacChatDetailGate(key: .init(
                id: id, title: summary?.title, boxName: summary?.boxName,
                sessionShort: summary?.sessionShort, boxShort: summary?.boxShort,
                roomBoxNames: summary?.roomBoxNames ?? [], roomBoxShorts: summary?.roomBoxShorts ?? [],
                paneRoute: paneRoute.route(for: id)
            )) {
            let (chatVM, composerVM) = vmCache.viewModels(for: id, deps: deps, session: session)
            MacChatView(
                viewModel: chatVM,
                composerVM: composerVM,
                stripViewModel: vmCache.stripViewModel(forParent: id, deps: deps, session: session),
                // Given a child id, vend its cached (read-only timeline VM,
                // switcher strip VM). Used when the user opens a subagent
                // from the strip — the detail area splits to show the child
                // pane beside this parent timeline. `parentConvoID` from the
                // store keeps the id opaque.
                subChatProvider: { childID in
                    let parent = deps.parentConvoID(of: childID, for: session) ?? id
                    return vmCache.subChatViewModels(
                        for: childID, parentConvoID: parent, deps: deps, session: session)
                },
                // Spec 2026-09-23 §3: hoisted here so the pane's route
                // survives a conversation switch and the history can
                // restore it — see `paneRoute`'s declaration above.
                paneRoute: paneRouteBinding(for: id),
                chatTitle: summary?.title ?? "",
                boxName: summary?.boxName,
                sessionShort: summary?.sessionShort,
                boxShort: summary?.boxShort,
                roomBoxNames: summary?.roomBoxNames ?? [],
                roomBoxShorts: summary?.roomBoxShorts ?? [],
                // "Open" on a started spawn: select the spawned room in the
                // sidebar. `prepareConversation` first, exactly as the New
                // Chat sheet does before navigating to a freshly-started
                // conversation — the room may have no journal frames yet,
                // and the detail column needs a row to render.
                onOpenConversation: { roomID in
                    // `@MainActor in` explicitly: `chatDetail(for:)` is not
                    // an isolated context, so an unannotated Task would
                    // resume off the main thread after the await and write
                    // `selectedSummaryID` from there.
                    Task { @MainActor in
                        await deps.prepareConversation(for: session, id: roomID)
                        showConversation(roomID)
                    }
                },
                // Transcript milestone cards and the toolbar title both
                // open this conversation's mission, remembering where the
                // reader came from so `MacMissionPage` can offer a way
                // back.
                onOpenMission: { showMission($0, from: id) }
            )
            }
            .equatable()
            }
            .id(id)
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

/// Bounded per-room cache of (ChatViewModel, ComposerViewModel) pairs —
/// see the `vmCache` doc comment on `MacChatListView`. LRU so a session
/// that visits many rooms doesn't pin every timeline's items forever;
/// the limit mirrors `AppDependencies.timelineCacheLimit`'s intent but
/// stays smaller because each VM holds a mapped item array.
@MainActor
final class ChatVMCache {
    private var entries: [String: (chat: ChatViewModel, composer: ComposerViewModel)] = [:]
    private var order: [String] = []
    private let limit = 8

    func viewModels(
        for roomID: String, deps: AppDependencies, session: UserSession
    ) -> (ChatViewModel, ComposerViewModel) {
        if let cached = entries[roomID] {
            order.removeAll { $0 == roomID }
            order.append(roomID)
            return cached
        }
        let timelineSvc = deps.timelineService(for: session, roomID: roomID)
        let mediaSvc = deps.mediaService(for: session)
        // The composer reads the chat half's session status for the palette's
        // session-derived suggestions (`/model`, `/effort`). Weakly: this
        // cache owns both, and the closure must not keep the chat VM alive
        // past an eviction.
        let chat = ChatViewModel(roomID: roomID, timeline: timelineSvc, media: mediaSvc,
                                 agentChat: deps.agentChatService(for: session),
                                 agentSpawn: deps.agentSpawnService(for: session),
                                 search: deps.search)
        let pair = (
            chat: chat,
            composer: ComposerViewModel(roomID: roomID, timeline: timelineSvc,
                                        commands: BotCommandCatalog.claudeBridge,
                                        sessionStatus: { [weak chat] in chat?.sessionStatus })
        )
        entries[roomID] = pair
        order.append(roomID)
        if order.count > limit, let evicted = order.first {
            order.removeFirst()
            entries[evicted]?.chat.stop()
            entries.removeValue(forKey: evicted)
        }
        return pair
    }

    /// Running-subagent strip view models, keyed by PARENT convo id and
    /// shared between a parent's strip and every child pane's switcher so
    /// all surfaces read one child-list subscription. See the iOS twin.
    private var stripEntries: [String: SubChatStripViewModel] = [:]

    func stripViewModel(
        forParent parentConvoID: String, deps: AppDependencies, session: UserSession
    ) -> SubChatStripViewModel {
        if let cached = stripEntries[parentConvoID] { return cached }
        let vm = SubChatStripViewModel(chat: deps.chatService(for: session), parentConvoID: parentConvoID)
        stripEntries[parentConvoID] = vm
        return vm
    }

    /// (read-only timeline VM, switcher strip VM) for a subagent child. The
    /// timeline VM reuses the pair cache (its composer is unused — the pane
    /// has no composer); the switcher strip is the SHARED parent VM so it
    /// lists siblings.
    func subChatViewModels(
        for childID: String, parentConvoID: String, deps: AppDependencies, session: UserSession
    ) -> (ChatViewModel, SubChatStripViewModel) {
        let chat = viewModels(for: childID, deps: deps, session: session).0
        let strip = stripViewModel(forParent: parentConvoID, deps: deps, session: session)
        return (chat, strip)
    }
}

/// The sidebar's conversation list, as its own view so that it — and only
/// it — re-evaluates when a chat-list snapshot lands. While agents are live
/// that is up to four times a second; read from `MacChatListView.body` the
/// same snapshot also rebuilt the open chat, the toolbar and every modifier
/// on the split view, which is what made a conversation switch stall while
/// online and not in an offline run.
struct MacChatSidebarList: View {
    let viewModel: ChatListViewModel
    @Binding var selection: ChatSummary.ID?
    let onSummariesChange: ([ChatSummary]) -> Void
    let runChatAction: (@escaping (ChatService) async throws -> Void) -> Void

    @ViewBuilder
    var body: some View {
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
            List(selection: $selection) {
                ForEach(viewModel.groups) { group in
                    Section(group.group.rawValue) {
                        ForEach(group.summaries) { summary in
                            MacChatRow(summary: summary)
                                .tag(summary.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // One menu for the whole list, not one per row. A per-row
            // `.contextMenu` hosts an AppKit platform view under every row,
            // and live samples of a 700-row sidebar showed each chat-list
            // snapshot re-adopting the environment on all of them
            // (`AppKitPlatformViewHost.coreUpdateEnvironment`) — a third of
            // one 78 s hang. The selection-typed form asks the list for the
            // clicked row's tag instead: an unselected row yields just its
            // own id, a right-click inside the selection yields the whole
            // selection, empty space yields nothing.
            .contextMenu(forSelectionType: ChatSummary.ID.self) { ids in
                if !ids.isEmpty {
                    // Per room, independently: one failure must not stop the
                    // rest of a multi-selection. `runChatAction` already
                    // swallows these errors (there is no error surface for
                    // Mute/Leave), so this keeps that behaviour per room.
                    Button("Mute") {
                        runChatAction { (chat: ChatService) in
                            for id in ids { try? await chat.mute(roomID: id) }
                        }
                    }
                    Button("Leave", role: .destructive) {
                        runChatAction { (chat: ChatService) in
                            for id in ids { try? await chat.leave(roomID: id) }
                        }
                    }
                }
            }
            // Keep the long-lived search VM's chat snapshot current: the toolbar
            // VM is built once, so without this new rooms and renamed titles never
            // reach chat-title search or `chatTitle(for:)` until relaunch (bugbot
            // "Mac chat search snapshot stale"). `initial:` because this list
            // unmounts under the other tabs: a room added or renamed while
            // it was away must reach the search VM when it comes back.
            // `allSummaries`: the Coordinator stays searchable though it is
            // left out of `groups`.
            .onChange(of: viewModel.allSummaries, initial: true) { _, all in
                onSummariesChange(all)
            }
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
}

/// Reads the selected chat's summary out of the list snapshot, so the
/// snapshot dependency lives here rather than in `MacChatListView.body`.
struct MacChatSummaryReader<Content: View>: View {
    let viewModel: ChatListViewModel
    let id: ChatSummary.ID
    @ViewBuilder let content: (ChatSummary?) -> Content

    var body: some View {
        content(viewModel.groups.lazy.flatMap(\.summaries).first { $0.id == id })
    }
}

/// Stops a re-evaluation at the chat detail unless something the detail
/// draws has changed. `MacChatView` takes closures, which SwiftUI cannot
/// compare, so without this gate every snapshot that reaches the reader
/// above re-runs the whole chat column's body.
struct MacChatDetailGate<Content: View>: View, Equatable {
    struct Key: Equatable {
        let id: ChatSummary.ID
        let title: String?
        let boxName: String?
        let sessionShort: String?
        let boxShort: String?
        let roomBoxNames: [String]
        let roomBoxShorts: [String]
        /// The pane route reaches `MacChatView` as a `Binding`, which
        /// tracks its source on its own; carried here as well so the gate
        /// never depends on that.
        let paneRoute: MacChatPaneRoute?
    }

    let key: Key
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View { content() }
}

/// Row view with hover-tint state held locally so it doesn't muddy the
/// view-model. Keeps the same column composition as the iOS row but with
/// Mac-appropriate sizing (28pt avatar vs 36pt on iPhone).
struct MacChatRow: View {
    let summary: ChatSummary
    @State private var isHovered = false

    @Environment(\.colorScheme) private var colorScheme

    /// `A:bc Title` as ONE Text — colored box letter + session short at
    /// the START of the eye scan, replacing the trailing BoxChip capsule
    /// (same composition as the iOS ChatRow; halves gated upstream in
    /// JournalChatService).
    private var titleLine: Text {
        // Multi-agent rooms lead with every participating box as a colored
        // letter (`A↔B`, `A,B,C`); the tag already says "room", so the
        // bridge's 🔗 title marker is dropped beside it (same composition
        // as the iOS ChatRow).
        if let tag = SessionTagText.room(
            letters: summary.roomBoxShorts,
            names: summary.roomBoxNames,
            sessionShort: summary.sessionShort,
            colorScheme: colorScheme
        ) {
            return tag + Text(" ") + Text(SessionTag.titleBesideRoomTag(summary.title))
        }
        guard let tag = SessionTagText.run(
            boxLetter: summary.boxShort,
            boxName: summary.boxName,
            sessionShort: summary.sessionShort,
            colorScheme: colorScheme
        ) else { return Text(summary.title) }
        return tag + Text(" ") + Text(summary.title)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                titleLine.font(.system(size: 14)).lineLimit(1)
                HStack(spacing: 4) {
                    // Snippet renders unconditionally with reserved space
                    // so row height stays fixed while messages stream in
                    // (an appearing/disappearing snippet line made the
                    // whole list jiggle as chats updated). An EMPTY
                    // snippet must render a space, not "" — SwiftUI only
                    // reserves the line when there's a character to lay
                    // out, so a snippet-less row collapsed shorter (same
                    // fix as the iOS ChatRow, Dan 2026-07-16).
                    Text(summary.snippet.isEmpty ? " " : summary.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1, reservesSpace: true)
                    if let lastActivity = summary.lastActivity {
                        if !summary.snippet.isEmpty {
                            Text("·").foregroundStyle(.secondary)
                        }
                        RelativeMinuteTimeView(lastActivity)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                NeedsYouBadge(count: summary.needsUserCount)
                UnreadBadge(count: summary.unreadCount)
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
