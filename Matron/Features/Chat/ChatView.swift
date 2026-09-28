import SwiftUI
import UIKit
import os
import MatronChat
import MatronModels
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// Un-gated (notice-level) breadcrumbs for rare view-layer anomalies —
/// same forensic role as the sync layer's lifecycle warnings.
private let chatViewLogger = Logger(subsystem: "chat.matron", category: "ios-chat-view")

/// iOS chat screen. Hosts a scrollable timeline (LazyVStack rendering each
/// `TimelineItem` via `TimelineItemView`) above a `ComposerView`. The
/// navigation toolbar shows the chat title and an info button that
/// presents a `SessionStatusSheet` (context gauge, usage bars, the media
/// browser link and this chat's subagents).
///
/// `viewModel.start()` runs in `.task`; `viewModel.stop()` runs in
/// `.onDisappear` to release the AsyncStream's continuation. This mirrors
/// the `ChatListView` pattern from Phase 1.
///
/// Task 11 (journal rewire) drops the per-bot verification banner and its
/// SAS sheet — the journal stack has no per-bot identity-verification
/// concept.
struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel
    /// Running-subagent strip source. Keyed by this chat's own convo id, so
    /// it lists the subagents this conversation spawned. Started/stopped
    /// with the view; hidden entirely when no child is running.
    @State var stripViewModel: SubChatStripViewModel
    /// App lifecycle — drives `viewModel.handleForeground()` so a
    /// background→foreground timeline re-sync doesn't flash the empty
    /// placeholder. `wasBackgrounded` filters out `.inactive`↔`.active`
    /// blips (notification centre, etc.) so only a real resume triggers it.
    @Environment(\.scenePhase) private var scenePhase
    /// Deep-link target for the "Open" affordance on a started spawn — the
    /// same stack the sub-chat links push onto.
    @Environment(\.chatNavigationPath) private var navigationPath
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    /// The Coordinator tab's root chat: Find + Your requests in the
    /// header (tracker #2864).
    @Environment(\.showsCoordinatorChatTools) private var showsCoordinatorChatTools
    @State private var wasBackgrounded = false
    /// Local text for the in-conversation search bar's field — seeded from
    /// `viewModel.chatSearch?.query`, submitted back via `beginChatSearch`.
    @State private var chatSearchQuery = ""
    /// The UIKit timeline's follow state + commands for the SwiftUI chrome.
    @State private var timelineBridge = ChatTimelineBridge()

    /// "Open" on a started spawn — push the room the child talks in.
    private func openSpawnedRoom(_ roomID: String) {
        Task { @MainActor in
            await pushSpawnedRoom(roomID, path: navigationPath, deps: deps, session: session)
        }
    }

    /// Pushes a tracker item onto the OUTER chat stack as an `ItemRoute`
    /// (spec §4) — never a local `NavigationStack`, which pops the outer
    /// one on iOS 26 (PR #188). Static so `ChatPagerTests` can pin it
    /// against a bare binding. Idempotent for the item already on top.
    static func pushItem(_ itemID: String, onto path: Binding<[String]>?) {
        guard let path else { return }
        let value = ItemRoute(id: itemID).pathValue
        guard path.wrappedValue.last != value else { return }
        path.wrappedValue.append(value)
    }

    /// A Coordinator header tool (tracker #2864).
    enum CoordinatorChatTool: Equatable {
        case yourRequests
        case findInChat
    }

    /// Which header tools a chat shows: only the Coordinator tab's root
    /// chat, only on the chat page, and Find only where the journal
    /// supports chat search. Static so a test pins the rule.
    static func coordinatorChatTools(isCoordinatorRoot: Bool, page: ChatPage,
                                     supportsChatSearch: Bool) -> [CoordinatorChatTool] {
        guard isCoordinatorRoot, page == .chat else { return [] }
        return supportsChatSearch ? [.yourRequests, .findInChat] : [.yourRequests]
    }

    private var shownCoordinatorChatTools: [CoordinatorChatTool] {
        Self.coordinatorChatTools(isCoordinatorRoot: showsCoordinatorChatTools, page: pager.page,
                                  supportsChatSearch: viewModel.supportsChatSearch)
    }

    /// The Coordinator tab's header tools (tracker #2864): Find in Chat
    /// and "Your requests" — see `coordinatorChatTools(isCoordinatorRoot:page:supportsChatSearch:)`.
    @ToolbarContentBuilder
    private var coordinatorChatTools: some ToolbarContent {
        if shownCoordinatorChatTools.contains(.yourRequests) {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showOwnRequests = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Your requests")
                .accessibilityIdentifier("coordinator.yourRequests")
            }
        }
        if shownCoordinatorChatTools.contains(.findInChat) {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.openChatSearch() } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Find in chat")
                .accessibilityIdentifier("coordinator.findInChat")
            }
        }
    }

    /// Opens the search bar from the ⓘ sheet. The bar lives on the chat
    /// page, so the pager goes there FIRST — opened from Tasks, the field
    /// would take focus off-screen and raise the keyboard over the tasks
    /// list (Bugbot, PR #236).
    static func findInChat(pager: ChatPagerModel, open: () -> Void) {
        withAnimation { pager.go(to: .chat) }
        open()
    }

    /// "Your requests" `onDismiss`: jump to the picked message now the
    /// transcript is uncovered.
    private func jumpToPickedRequest() {
        guard let seq = pendingRequestJump else { return }
        pendingRequestJump = nil
        Task { await viewModel.jumpToMessage(seq: seq) }
    }

    /// Static twin of `pushItem` — a mission rides the same `[String]`
    /// stack the chat itself is mounted on. Idempotent for the mission
    /// already on top, mirroring `pushItem` (a double title tap or a
    /// second milestone-card tap for the same mission must not stack two
    /// identical pages).
    static func pushMission(_ missionID: String, onto path: Binding<[String]>?) {
        guard let path else { return }
        let value = MissionRoute(id: missionID).pathValue
        guard path.wrappedValue.last != value else { return }
        path.wrappedValue.append(value)
    }

    /// Pops the top entry of the OUTER chat stack — the full-width swipe
    /// back (Dan, 2026-09-09). Only the top entry: a subagent viewer pops
    /// to its parent, a top-level chat to the list. Static for the tests.
    static func popChat(from path: Binding<[String]>?) {
        guard let path, !path.wrappedValue.isEmpty else { return }
        path.wrappedValue.removeLast()
    }

    /// Whether the navigation bar's own back button is suppressed. The
    /// tasks page is a page OF this conversation, not a sibling of it, so
    /// its top-left must lead back to the conversation — the system
    /// button pops the whole destination and lands on the conversation
    /// list instead (Dan, 2026-09-10). A leading button that pages back
    /// takes its place below. Hiding it also hands the leading-edge
    /// swipe to the pager, which pages back for the same reason.
    static func hidesSystemBackButton(page: ChatPage) -> Bool {
        page == .tasks
    }

    /// Tapping an inline `.itemMarker` card pushes that item onto the
    /// outer stack straight away — no need to page to the tracker first.
    private func openItem(_ itemID: String) {
        Self.pushItem(itemID, onto: navigationPath)
    }

    /// A tapped milestone card opens its mission on whichever stack this
    /// chat is mounted in — the same rule `openItem` follows.
    private func openMission(_ missionID: String) {
        Self.pushMission(missionID, onto: navigationPath)
    }

    /// A tapped `matron://item/<n>` link in a message body, resolved by the
    /// shared `TrackerItemLinkResolver` (one local lookup, one
    /// `refresh(scope: .all)` retry). A known item opens exactly where an
    /// inline item card opens it. A number this device still doesn't have
    /// leaves the reader EXACTLY where they were — paging to the tracker
    /// would cost them their place in the conversation to show them a list
    /// that by definition doesn't contain the item — and says so in the
    /// tracker alert instead (item #115, fix round 2).
    ///
    /// Answers what the tap should do; `trackerItemLinks` decides whether
    /// it still MAY (fix round 5 — a slow resolve must not navigate over
    /// the tap that overtook it).
    @MainActor private func openTrackerItem(num: Int) async -> TrackerItemLinkOutcome {
        guard let deps, let session else { return .ignore }
        let outcome = await deps.trackerItemLinkOutcome(num: num, session: session)
        if case .explain = outcome {
            chatViewLogger.notice("item link #\(num, privacy: .public) did not resolve — staying put")
        }
        return outcome
    }

    /// Generation token from the observation THIS view instance started;
    /// `onDisappear` only stops the VM if it still matches (see there).
    @State private var startedGeneration = 0
    /// Same guard for the shared per-parent strip VM: pushing a sub-chat
    /// runs the child's `.task` (which restarts the shared strip) before
    /// this view's `onDisappear`, so an unconditional `stop()` here would
    /// kill the child's freshly-started stream.
    @State private var stripStartedGeneration = 0
    /// Backing state for the fullscreen attachment preview. `nil`
    /// hides the sheet; setting either case presents it via
    /// `.sheet(item:)`. `.image` draws the pinch-zoom viewer; `.file`
    /// drives a small share sheet around `ShareLink(item:)` so the
    /// user can save / forward the attachment without leaving the
    /// chat.
    @State private var attachmentPreview: AttachmentPreview?
    /// ⓘ toolbar button → session-status sheet (context gauge + usage bars).
    @State private var showSessionStatus = false
    /// Media/files/links toolbar button → the per-chat browser sheet.
    @State private var showMediaBrowser = false
    /// Set by the info sheet's media link; consumed in its `onDismiss` to
    /// present the browser once the sheet slot is free.
    @State private var pendingMediaOpen = false
    /// Child convo id chosen from the info sheet's subagents list; consumed
    /// in the same `onDismiss` to push it onto the parent stack. Pushing
    /// while the sheet is still up races the dismissal animation, and the
    /// sheet has no access to this view's `navigationPath` regardless.
    @State private var pendingChildOpen: String?
    /// Set by the info sheet's "Find in chat" row; consumed in its
    /// `onDismiss` so the bar's field can take focus (tracker #2864 A).
    @State private var pendingFindOpen = false
    /// The Coordinator's "Your requests" sheet (tracker #2864 B).
    @State private var showOwnRequests = false
    /// The request picked there; jumped to from the sheet's `onDismiss`,
    /// once the transcript is uncovered.
    @State private var pendingRequestJump: Int64?
    /// Which mission this conversation belongs to (spec: Transcript and
    /// title). Derived locally from the mission cache — the snapshot
    /// never carries it — so it is nil until the first missions refresh,
    /// which is exactly when the affordance should appear.
    @State private var missionID: String?
    /// Tasks page (spec §4). The items VM is created and started in `.task`
    /// regardless of which page shows — the toolbar's `NeedsYouBadge` needs
    /// a live `needsYouCount` on the chat page — and stopped in the same
    /// `onDisappear` that stops `viewModel`/`stripViewModel`.
    @State private var itemsVM: ItemsPanelViewModel?
    @State private var pager = ChatPagerModel()
    /// `[#65](matron://item/65)` taps from any message body (item #115).
    /// The relay's `action` is installed into the environment with a stable
    /// closure identity (see `TrackerItemLinkRelay`) and the navigation
    /// itself happens in `onChange` below, with current values.
    @State private var itemLinkRelay = TrackerItemLinkRelay()
    @State private var showCreateItem = false
    /// id→label for the tracker's "All" rows; one cheap store scan per
    /// scope switch (`conversationOriginLabels()`).
    @State private var originTitles: [String: String] = [:]
    /// Sheet payload for fullscreen attachment previews. Identifiable
    /// via a per-present UUID so two consecutive taps re-mount the
    /// sheet (and so `.sheet(item:)` doesn't conflate two separate
    /// images).
    fileprivate enum AttachmentPreview: Identifiable {
        case image(id: UUID = UUID(), ImageGallery)
        case file(id: UUID = UUID(), URL, filename: String)

        var id: UUID {
            switch self {
            case .image(let id, _): return id
            case .file(let id, _, _): return id
            }
        }
    }

    let chatTitle: String
    /// Which agent box runs this session, or nil when the user has fewer
    /// than two boxes. Threaded from the list's ChatSummary (same source as
    /// the row chip) so header and row can never disagree.
    var boxName: String? = nil
    /// The `A:bc` tag halves, threaded from the list summary like `boxName`
    /// (see ChatSummary.sessionShort / .boxShort). Composed ahead of the
    /// title in the principal item so the in-chat header matches the row.
    var sessionShort: String? = nil
    var boxShort: String? = nil
    /// Multi-agent room participants (ChatSummary.roomBoxNames /
    /// .roomBoxShorts, parallel arrays), threaded like the halves above so
    /// a room's header shows the same colored `A↔B` tag as its row.
    var roomBoxNames: [String] = []
    var roomBoxShorts: [String] = []

    @Environment(\.colorScheme) private var colorScheme

    /// `A:bc Title` (or `A↔B:bc Title` for a multi-agent room) as one Text
    /// — same composition and fallbacks as ChatRow's titleLine.
    private var titleText: Text {
        if let tag = SessionTagText.room(
            letters: roomBoxShorts,
            names: roomBoxNames,
            sessionShort: sessionShort,
            colorScheme: colorScheme
        ) {
            return tag + Text(" ") + Text(SessionTag.titleBesideRoomTag(chatTitle))
        }
        guard let tag = SessionTagText.run(
            boxLetter: boxShort,
            boxName: boxName,
            sessionShort: sessionShort,
            colorScheme: colorScheme
        ) else { return Text(chatTitle) }
        return tag + Text(" ") + Text(chatTitle)
    }

    /// What VoiceOver reads for the principal title: the visible tag's
    /// meaning spelled out (box names, session short), not just the clean
    /// title — sighted users see the `A:bc` tag, so the label must carry
    /// it too. Static for unit-testability (ChatViewBindingTests).
    static func accessibilityTitle(
        chatTitle: String,
        boxName: String?,
        sessionShort: String?,
        roomBoxNames: [String]
    ) -> String {
        SessionTag.accessibilityTitle(
            chatTitle: chatTitle, boxName: boxName,
            sessionShort: sessionShort, roomBoxNames: roomBoxNames)
    }

    /// "box · ~/workdir" for the small line under the nav title. Either part
    /// can be missing (single-box users get no box name; the workdir only
    /// arrives with the first session-status frame) — show what's known,
    /// nil hides the line entirely. Static so the composition is unit-testable
    /// without rendering (see ChatViewBindingTests).
    static func contextLine(boxName: String?, workdir: String?) -> String? {
        let path = workdir.map(UsageMetersFormat.homeAbbreviated)
        let parts = [boxName, path].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var chatContextLine: String? {
        Self.contextLine(boxName: boxName, workdir: viewModel.sessionStatus?.workdir)
    }

    /// The principal toolbar item's content — the title plus the small
    /// "box · ~/workdir" subtitle. Shared by the mission-button branch and
    /// the plain (no-mission) branch so the two cannot drift.
    private var titleStack: some View {
        VStack(spacing: 1) {
            titleText
                .font(.headline)
                .lineLimit(1)
            if let context = chatContextLine {
                Text(context)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Middle-truncate like the Mac toolbar's subtitle: the
                    // tail of a path is the part worth keeping.
                    .truncationMode(.middle)
            }
        }
    }

    private var chatPage: some View {
        VStack(spacing: 0) {
            // QA finding #10: surface upstream stream failures (e.g.
            // `SyncReadyError.timeout`) in a banner above the timeline
            // so the user understands why nothing is loading instead
            // of staring at an empty scroll view.
            if let errorMessage = viewModel.error {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.9))
                    .accessibilityLabel("Chat error: \(errorMessage)")
            }
            // In-conversation search (armed by a grouped search-result
            // tap, or opened empty by "Find in chat"). Field text is local, seeded from the VM's query;
            // submit re-runs the room-scoped search. Same slot as the Mac.
            if let searchState = viewModel.chatSearch {
                ChatSearchBar(
                    query: $chatSearchQuery,
                    matchCount: searchState.matchSeqs.count,
                    matchIndex: searchState.index,
                    isAwaitingQuery: searchState.isAwaitingQuery,
                    wantsFieldFocus: viewModel.chatSearchWantsFieldFocus,
                    onFieldFocused: { viewModel.chatSearchFieldFocusHandled() },
                    onSubmit: { Task { await viewModel.beginChatSearch(query: chatSearchQuery) } },
                    onOlder: { Task { await viewModel.stepChatSearch(older: true) } },
                    onNewer: { Task { await viewModel.stepChatSearch(older: false) } },
                    onClose: { viewModel.endChatSearch() }
                )
                .onAppear { chatSearchQuery = searchState.query }
                .onChange(of: searchState.query) { _, newQuery in
                    chatSearchQuery = newQuery
                }
            }
            // Tap-to-compact nudge once the session's context passes the
            // absolute threshold (see CompactContextBanner.shouldShow).
            // Sits between the error banner and the subagent strip, same
            // slot as the Android client.
            if let context = viewModel.sessionStatus?.context,
               CompactContextBanner.shouldShow(context) {
                CompactContextBanner(tokens: context.tokens) {
                    Task { await viewModel.sendCommand("/compact") }
                }
            }
            // Sticky strip of running subagents pinned above the timeline.
            // Hidden when none are running (see RunningSubagentStrip). Tap a
            // pill to open that subagent's read-only sub-chat.
            RunningSubagentStrip(viewModel: stripViewModel)
            if viewModel.settledEmpty && viewModel.error == nil {
                // Settled-empty branch: gated on the debounced
                // `settledEmpty` (not raw `items.isEmpty`) so the
                // placeholder doesn't flash during sliding-sync warm-up
                // OR a transient timeline reset — both produce a
                // momentary empty `items` that repopulates within a tick.
                // See `ChatViewModel.settledEmpty`.
                EmptyChatPlaceholder(botName: chatTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                uikitTimeline
            }
            ComposerView(viewModel: composerVM)
        }
    }

    /// The timeline (spec 2026-09-26). `ChatTimelineController` owns
    /// scrolling; the overlays are SwiftUI controls driven by
    /// `timelineBridge`.
    private var uikitTimeline: some View {
        ChatTimelineView(
            viewModel: viewModel,
            stripViewModel: stripViewModel,
            bridge: timelineBridge,
            actions: ChatTimelineActions(
                openSubChat: { id in navigationPath?.wrappedValue.append(id) },
                openSpawnRoom: openSpawnedRoom,
                openItem: openItem,
                openMission: openMission,
                previewFile: { url, filename in attachmentPreview = .file(url, filename: filename) },
                tapImage: { url, image in
                    attachmentPreview = .image(ImageGalleries.conversation(
                        tapped: url, image: image, chatViewModel: viewModel, deps: deps, session: session))
                }
            )
        )
        // Persist cross-device ask-user answers the moment a snapshot
        // shows them, so a resolved inline card stays resolved even if a
        // later transient snapshot drops the answer event (bugbot
        // "Cross-device answers not persisted").
        .onChange(of: viewModel.items) { _, _ in
            viewModel.persistVisibleAnswers()
        }
        .overlay {
            if viewModel.rows.isEmpty || timelineBridge.isLoadingFirstRows { TimelineLoadingIndicator() }
        }
        .overlay(alignment: .top) {
            MinDisplayDuration(while: viewModel.isPaginatingBackward) { visible in
                if visible {
                    PaginatingHeader()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: viewModel.isPaginatingBackward)
        }
        .overlay(alignment: .bottomTrailing) {
            if !timelineBridge.isFollowingTail {
                JumpToBottomButton { timelineBridge.jumpToBottom() }
            }
        }
        .overlay(alignment: .topTrailing) {
            MinDisplayDuration(while: viewModel.isTurnRunning || viewModel.activityLabel != nil) { stopVisible in
                ChatTopTrailingControls(
                    showsStop: stopVisible,
                    showsJump: ChatTopTrailingControls.showsJump(
                        isFollowingTail: timelineBridge.isFollowingTail,
                        isTasksPage: pager.page == .tasks
                    ),
                    onStop: { Task { await viewModel.sendCommand("!esc") } },
                    onJump: { Task { await viewModel.jumpToLastOwnMessage() } }
                )
            }
        }
    }

    /// Page 1: this conversation's tracker (the existing `itemsVM`, scope
    /// defaulting to this chat, picker available). No `NavigationStack` of
    /// its own — item detail is pushed onto the OUTER stack as an
    /// `ItemRoute` (spec §4; PR #188).
    @ViewBuilder
    private var tasksPage: some View {
        if let itemsVM {
            ItemsListView(
                model: .init(
                    needsYou: itemsVM.sections.needsYou,
                    tasks: itemsVM.sections.tasks,
                    decisions: itemsVM.sections.decisions,
                    done: itemsVM.sections.done,
                    originTitles: originTitles,
                    isSupported: itemsVM.isSupported,
                    isRefreshing: itemsVM.isRefreshing,
                    // Fix wave part 2 (item C): surfaces a queued/offline
                    // "create" outbox row that hasn't landed on the server
                    // yet — without it a create sheet dismisses into
                    // apparent nothing until the next successful drain.
                    pending: itemsVM.pendingCreates.map {
                        ItemsListView.PendingRow(id: $0.id, kind: $0.kind, title: $0.title,
                                                 isFailed: $0.lastError != nil, error: $0.lastError)
                    }
                ),
                scope: Binding(get: { itemsVM.scope }, set: { itemsVM.scope = $0 }),
                convoID: itemsVM.convoID,
                thumbnail: { _ in nil },
                onSelect: { Self.pushItem($0.id, onto: navigationPath) },
                onMove: { id, index in Task { await itemsVM.move(itemID: id, toIndex: index) } },
                onCreate: { showCreateItem = true },
                onOpenConversation: { id in
                    // An origin link back to THIS room would push a second
                    // entry onto the chat already showing — skip it.
                    guard id != viewModel.roomID else { return }
                    navigationPath?.wrappedValue.append(id)
                }
            )
            // `conversationOriginLabels()` — a full id→label scan, drawn
            // only by the "All" scope, so the conversation scope skips it
            // (see the matching comment in `MacItemsPane`).
            .task(id: itemsVM.scope) {
                guard let deps, let session, itemsVM.scope == .all else { return }
                let labels = (try? await deps.journalStore(for: session).conversationOriginLabels()) ?? [:]
                guard !Task.isCancelled else { return }
                originTitles = labels
            }
            .sheet(isPresented: $showCreateItem) {
                NewItemSheet { kind, title, itemBody in
                    Task { await itemsVM.create(kind: kind, title: title, body: itemBody) }
                }
            }
            // Both pages stay mounted, so gate on the tasks page being the
            // one showing — a background refresh failure must not interrupt
            // the chat page (CodeRabbit, PR #194).
            .alert("Tracker", isPresented: Binding(
                get: { pager.page == .tasks && itemsVM.error != nil },
                set: { if !$0 { itemsVM.error = nil } })) {
                Button("OK") { itemsVM.error = nil }
            } message: {
                Text(itemsVM.error ?? "")
            }
        } else {
            Color.clear
        }
    }

    /// Whether the tracker page exists: the VM must exist and the journal
    /// must not have said "unsupported" (a 404 on GET /items). With one
    /// page the swipe does nothing (spec §7).
    private var showsTasksPage: Bool {
        guard let itemsVM else { return false }
        return itemsVM.isSupported != false
    }

    var body: some View {
        ChatPager(model: pager, showsTasks: showsTasksPage,
                  onSwipeBack: { Self.popChat(from: navigationPath) }) {
            chatPage
        } tasks: {
            tasksPage
        }
        // The composer rides UIKit's keyboard layout guide, not SwiftUI's
        // keyboard safe area, which goes stale when this chat comes back on
        // screen (tracker #3141).
        .chatKeyboardAvoidance()
        // Item links (`[#65](matron://item/65)`) in any message body on
        // either page — installed ONCE here, on the pager root, so the chat
        // page and the tasks page share one host (and one alert).
        .trackerItemLinks(itemLinkRelay, resolve: { await openTrackerItem(num: $0) },
                          open: { openItem($0) })
        // VoiceOver hears the page change; the announcement names the
        // page that just arrived.
        .onChange(of: pager.page) { _, page in
            UIAccessibility.post(notification: .screenChanged,
                                 argument: page == .tasks ? "Tasks and decisions" : chatTitle)
        }
        // matron-web's cream timeline gradient sits behind the whole chat
        // column — bubbles (white / cyan) and the composer material all
        // render over the same warm ground.
        .background(MatronTimelineBackground())
        // Keep `.navigationTitle` for the back-button label on the pushed
        // destination even though the visible title is now the tappable
        // principal item below — dropping it blanks the "< Back" text.
        .navigationTitle(chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(Self.hidesSystemBackButton(page: pager.page))
        // Which mission this conversation belongs to (spec: Transcript and
        // title). Derived locally from the mission cache — the snapshot
        // never carries it — so it is nil until the first missions refresh,
        // which is exactly when the affordance should appear.
        .task(id: viewModel.roomID) {
            // Clear the previous room's value before the new
            // `ValueObservation` delivers its first (asynchronous) fetch —
            // otherwise a title tap in that window opens the wrong
            // mission (MINOR-4).
            missionID = nil
            guard let deps, let session else { return }
            for await id in deps.journalStore(for: session).missionIDStream(convoID: viewModel.roomID) {
                // Cancellation ends a pending `next()` call but does not
                // undo a value already returned — without this guard the
                // old task's write can land after the new task's `nil`
                // above, leaving a stale mission id (CodeRabbit #209).
                guard !Task.isCancelled else { return }
                missionID = id
            }
        }
        .toolbar {
            // The tasks page's own way back: to the conversation it
            // belongs to, in the corner every iOS back button lives in.
            if Self.hidesSystemBackButton(page: pager.page) {
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { pager.go(to: .chat) } } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Back to the chat")
                }
            }
            // Tappable title → this conversation's mission (spec: Transcript
            // and title). Under it, "box · ~/workdir" in small text — which
            // machine and folder this session lives on, readable without
            // opening the info sheet (Dan, 2026-08-16). Box comes from the
            // list summary (same gate as the row chip); the path arrives
            // with the first session-status frame, home-abbreviated like
            // the info sheet. With no mission the title is not a button
            // (spec) — same content, just inert.
            ToolbarItem(placement: .principal) {
                if pager.page == .tasks {
                    Text("Tasks & decisions").font(.headline)
                } else if let missionID {
                    Button { openMission(missionID) } label: { titleStack }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.accessibilityTitle(
                            chatTitle: chatTitle,
                            boxName: boxName,
                            sessionShort: sessionShort,
                            roomBoxNames: roomBoxNames
                        ))
                        .accessibilityValue(chatContextLine ?? "")
                        .accessibilityHint("Opens this conversation's mission")
                } else {
                    titleStack
                        .accessibilityLabel(Self.accessibilityTitle(
                            chatTitle: chatTitle,
                            boxName: boxName,
                            sessionShort: sessionShort,
                            roomBoxNames: roomBoxNames
                        ))
                        .accessibilityValue(chatContextLine ?? "")
                }
            }
            // Tasks page (spec §4). Hidden once the panel VM has confirmed
            // the journal doesn't support the tracker; on the tasks page the
            // same slot returns to the chat.
            if showsTasksPage, let itemsVM, pager.page != .tasks {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation { pager.go(to: .tasks) } } label: {
                        Image(systemName: "checklist")
                            .overlay(alignment: .topTrailing) {
                                NeedsYouBadge(count: itemsVM.needsYouCount)
                                    .scaleEffect(0.75)
                                    .offset(x: 10, y: -8)
                            }
                    }
                    .accessibilityLabel("Tasks and decisions")
                }
            }
            // Back to a single ⓘ (Dan, 2026-08-16 — the ellipsis read as
            // "menu of stuff", the info sheet IS the chat's utility
            // surface): it opens `SessionStatusSheet`, which carries the
            // media-browser link AND — since Dan, 2026-09-09 — the list of
            // this chat's subagents, which used to be its own toolbar
            // `Menu`. The sheet can't push onto this stack itself, so it
            // hands the child's id back through `onOpenSubagent` and the
            // `onDismiss` below appends it — exactly the media-browser
            // handoff, one surface later.
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSessionStatus = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Session info")
            }
            coordinatorChatTools
        }
        .sheet(isPresented: $showSessionStatus, onDismiss: {
            // Present the media browser only after the info sheet is fully
            // gone — flipping it while the sheet is still up is a silent
            // no-op (one sheet per presenter).
            if pendingMediaOpen {
                pendingMediaOpen = false
                showMediaBrowser = true
            }
            // Same deal for a subagent tap: push once the sheet slot is
            // free. Only ever one of the two is set — each row dismisses
            // the sheet as it arms its flag.
            if let id = pendingChildOpen {
                pendingChildOpen = nil
                navigationPath?.wrappedValue.append(id)
            }
            // "Find in chat": the bar's field takes focus once the sheet
            // has let go of it.
            if pendingFindOpen {
                pendingFindOpen = false
                Self.findInChat(pager: pager) { viewModel.openChatSearch() }
            }
        }) {
            SessionStatusSheet(
                viewModel: viewModel, boxName: boxName,
                onOpenMedia: { pendingMediaOpen = true },
                strip: stripViewModel,
                onOpenSubagent: { id in pendingChildOpen = id },
                onFindInChat: viewModel.supportsChatSearch ? { pendingFindOpen = true } : nil
            )
        }
        .sheet(isPresented: $showMediaBrowser) {
            MediaBrowserSheet(chatViewModel: viewModel)
        }
        .sheet(isPresented: $showOwnRequests, onDismiss: jumpToPickedRequest) {
            OwnRequestsSheet(chatViewModel: viewModel) { pendingRequestJump = $0 }
        }
        .task {
            // Chain `markAsRead()` *after* the timeline observation has
            // applied its first snapshot. `start()` is now `async` and
            // returns once the first snapshot has landed (or the stream
            // ends without one), so the subsequent `markAsRead()` always
            // marks the actual head of the timeline as read instead of
            // racing the empty initial state. See `ChatViewModel.start()`
            // for the underlying signal mechanism (round-3 bugbot fix #3).
            // Record the generation BEFORE awaiting: start() bumps it
            // synchronously at entry, but it doesn't RETURN until the
            // first snapshot lands — if this view disappears mid-await, a
            // post-await assignment never runs and onDisappear's guarded
            // stop no-ops against generation 0, leaking the observation
            // (bugbot "Observation leak on fast exit"). This .task is the
            // only starter between here and the call, so current+1 is
            // exactly the generation start() will use.
            startedGeneration = viewModel.observationGeneration + 1
            // Task 11: created and started here — not lazily on first
            // drawer open — so the toolbar badge's `needsYouCount` is live
            // the moment the chat appears, matching the Mac pane's
            // lifecycle. `stop()` is paired in `onDisappear` below,
            // unconditionally (this VM has no cross-view cache to race,
            // unlike `viewModel`/`stripViewModel`).
            if let deps, let session {
                let vm = deps.makeItemsPanelViewModel(for: session, convoID: viewModel.roomID)
                vm.start()
                itemsVM = vm
            }
            stripViewModel.start()
            stripStartedGeneration = stripViewModel.observationGeneration
            // Small first-paint window, then settle — splits the open
            // transaction's eager-layout cost in two exactly like
            // MacChatView (2026-08-05 trace: the 0.5-1.2s switch stall
            // was one 120-row layout transaction). Mac adopted this on
            // 2026-08-05; iOS opens pay the same cost, so same cure.
            // The timeline's pending restore owns the window (Bugbot,
            // PR #243): an entry shrink now could drop its target.
            if !timelineBridge.hasPendingRestore {
                viewModel.beginEntryWindow()
            }
            await viewModel.start()
            // Grow the entry window to steady state behind the first
            // frame (no-op if a restore already widened it). BEFORE the
            // open paginate — that's an HTTP fetch that can hang for
            // seconds on a half-dead connection, and sequencing the
            // settle after it left the room at the 40-row entry window
            // (with reveal-older gated out by `isPaginatingBackward`)
            // for the fetch's whole duration (review 2026-08-21). Same
            // order as MacChatView, where this split was proven.
            try? await Task.sleep(nanoseconds: 300_000_000)
            await viewModel.settleEntryWindow()
            // Explicit paginate-on-open BEFORE markAsRead. The store seeds
            // the timeline with whatever's mirrored locally (possibly
            // nothing, e.g. right after a snapshot_required wipe), so this
            // fetches the first page over HTTP; the near-top geometry
            // trigger handles SUBSEQUENT history reveals as they scroll.
            // Ordered ahead of `markAsRead()` because that rides the live
            // socket — a half-dead socket can hang the send for its whole
            // timeout, and history loading must not wait on it.
            await viewModel.paginateBackward()
            await viewModel.markAsRead()
        }
        .onDisappear {
            chatViewLogger.breadcrumb("chat view disappear room=\(viewModel.roomID) following=\(timelineBridge.isFollowingTail)")
            // Capture the user's scroll position so the next open of
            // this room lands where they left off. A user in follow-tail
            // mode gets no entry — the default behaviour already opens
            // at the bottom, and storing a live-tail row id would reopen
            // the room pinned to a stale position.
            // The timeline decides from its own follow state and stores
            // its (top row, in-row offset); its dismantle stores too, in
            // case it is already gone here. It then parks until `onAppear`
            // (a tab switch or push keeps it alive): the window shrink
            // below must not move a viewport nobody can see.
            timelineBridge.chatDidDisappear()
            // Shrink the cached VM's window for the next open — keeping a
            // grown window here is what made switching BACK to a deep-read
            // room re-mount 600+ rows in one transaction (2026-08-21 Mac
            // trace; same cached-VM shape here). The remembered position
            // above survives independently; re-entry restores it via
            // ensureWindowContains (capped). Generation-guarded like the
            // stop below: on a same-room remount the successor may already
            // have restored a widened window, and an unguarded reset
            // landing after it would collapse the window under a reader
            // who is up in history.
            viewModel.resetHistoryWindow(ifGeneration: startedGeneration)
            // Generation-guarded: the VM is cached per room (ChatVMCache in
            // ChatListView), and on a same-room remount SwiftUI can run the
            // NEW view's `.task`/start() before the OLD view's onDisappear —
            // an unconditional stop() would kill the successor's stream.
            viewModel.stop(ifGeneration: startedGeneration)
            stripViewModel.stop(ifGeneration: stripStartedGeneration)
            // Task 11: unlike `viewModel`/`stripViewModel`, `itemsVM` is
            // never cached across remounts (`.task` above always mints a
            // fresh instance) — this view's own object, so stopping it
            // unconditionally can't race a successor's stream.
            itemsVM?.stop()
            // Close live-output viewer sockets behind the departing chat
            // (accumulated output is kept; cards reconnect on re-appear).
            // Scoped to THIS chat's sessions — a global suspend froze
            // still-visible tiles in overlapping chats (Mac pane; bugbot).
            // Safe against the same-room remount race above: the new view's
            // cards call startIfNeeded from their own .task on appear.
            LiveOutputSessionStore.shared.suspendSessions(in: viewModel.roomID)
        }
        // Fullscreen attachment preview. Presented from a tap on
        // either an `AttachmentImage` or `AttachmentFile` row;
        // payload selects between the pinch-zoom image viewer and
        // the file preview (QuickLook for playable/previewable types,
        // share-only fallback otherwise). Dismissed by setting
        // `attachmentPreview = nil` (swipe-down on iOS, "Done"
        // button, or successful share).
        .sheet(item: $attachmentPreview) { preview in
            switch preview {
            case .image(_, let gallery):
                AttachmentFullscreenViewer(gallery: gallery, onDismiss: { attachmentPreview = nil })
            case .file(_, let url, let filename):
                FilePreviewSheet(url: url, filename: filename,
                                 onDone: { attachmentPreview = nil })
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasBackgrounded = true
            } else if newPhase == .active, wasBackgrounded {
                wasBackgrounded = false
                viewModel.handleForeground()
            }
        }
        // Forensic breadcrumbs for the blank-chat hunt: the two branch
        // swaps that replace the message area with something else
        // (placeholder / warm-up spinner) and the view's own lifecycle.
        // The 2026-07-13 traces had silent gaps exactly where these
        // events would have been — a "blank chat" report that shows a
        // placeholder flip here and no anchor activity is a state bug,
        // not a scroll bug, and vice versa.
        .onAppear {
            chatViewLogger.breadcrumb("chat view appear room=\(viewModel.roomID) rows=\(viewModel.rows.count)")
            // The timeline re-arms its remembered position on every appear
            // (no-op on a first appear — the controller reads it at mount).
            timelineBridge.chatWillAppear()
        }
        .onChange(of: viewModel.settledEmpty) { _, isEmpty in
            chatViewLogger.breadcrumb("settledEmpty → \(isEmpty) (rows=\(viewModel.rows.count), items=\(viewModel.items.count))")
        }
        .onChange(of: viewModel.rows.isEmpty) { _, isEmpty in
            chatViewLogger.breadcrumb("rows \(isEmpty ? "EMPTY — warm-up spinner over blank area" : "populated") (items=\(viewModel.items.count))")
        }
    }

}

/// The timeline's eager `VStack` + `ForEach`, fenced off behind
/// `Equatable` so the parent's scroll-state churn (follow-mode /
/// edge-proximity flips) can't re-evaluate every mounted row (see the
/// call site in `ChatView.body`).
/// `==` compares only the view-model reference: the row data itself is
/// delivered through `@Observable` tracking, which invalidates this view
/// directly when `viewModel.rows` (or anything else its body reads)
/// changes — the equatable check only gates parent-driven invalidation.
private struct TimelineListContent: View, Equatable {
    let viewModel: ChatViewModel
    /// The chat's sub-chat list, used to turn the bridge's plain
    /// "🔀 Subtask: …" indicator messages into tappable entries that open
    /// the child sub-chat (spec: "Task tool cards … become tappable
    /// entries"). Reading `children` in `body` installs `@Observable`
    /// tracking, so indicator rows re-render as children appear/finish.
    let stripViewModel: SubChatStripViewModel
    /// How a tapped subtask card opens its child. `nil` (the parent chat)
    /// pushes via `NavigationLink`; `SubChatView` passes its `switchTo`
    /// instead so a sibling's card REPLACES the open child on the stack —
    /// a plain push there would make back walk through prior siblings
    /// rather than return to the parent.
    let onOpenSubChat: ((String) -> Void)?
    /// Pushes a spawned room onto this screen's navigation stack — the
    /// "Open" affordance on a started spawn. Fixed per screen, like
    /// `onOpenSubChat`, so `==` ignoring it is safe.
    let onOpenSpawnRoom: ((String) -> Void)?
    /// Opens the tracker item pane to the tapped `.itemMarker`'s item.
    /// Fixed per screen like `onOpenSpawnRoom`, so `==` ignoring it is
    /// safe; `nil` where the screen has no items pane (sub-chat panes).
    let onOpenItem: ((String) -> Void)?
    /// Opens the mission page to a tapped `.milestoneMarker` /
    /// `.missionMarker`. Fixed per screen like `onOpenItem`, so `==`
    /// ignoring it is safe; `nil` where the screen has no mission page
    /// (sub-chat panes).
    let onOpenMission: ((String) -> Void)?
    let onPreview: (ChatView.AttachmentPreview) -> Void
    /// Image tap → the screen builds the conversation gallery ONCE here,
    /// at tap time, and stores it in the preview payload. Building it in
    /// the sheet's content closure would re-query the journal on every
    /// parent refresh and could shift entries under the viewer's kept
    /// index (Bugbot, PR #175).
    let onTapImage: (URL, Image) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.stripViewModel === rhs.stripViewModel
    }

    /// The child sub-chat a bridge subtask-indicator message refers to,
    /// or nil when `item` isn't an indicator / no child matches (then the
    /// row renders as the plain text message it always was).
    private func subtaskChild(for item: TimelineItem) -> SubChatSummary? {
        guard case .text(let body, _) = item.kind, !item.isOwn,
              let description = SubChatStripViewModel.subtaskDescription(fromMessageBody: body)
        else { return nil }
        return SubChatStripViewModel.resolveSubtaskTarget(
            description: description, among: stripViewModel.children)
    }

    var body: some View {
        // Eager `VStack`, NOT `LazyVStack`: with the timeline windowed to
        // ~120 rows, laziness buys nothing and costs exactness — a lazy
        // stack only measures materialized rows and *guesses* the rest
        // from their average, and with rows spanning 40pt one-liners to
        // multi-thousand-point bot replies that guess swung the content
        // height 41K↔494K pt on every keyboard resize even inside the
        // window (device trace 2026-07-14 07:08), teleporting the
        // viewport. Eager layout makes content height exact, so every
        // scroll-anchor role holds precisely.
        VStack(spacing: 8) {
            // Render `rows` (messages interleaved with date
            // separators) instead of `items` directly. The
            // separator stream is computed on the view-model
            // so iOS and Mac don't have to duplicate the
            // calendar-day bucketing.
            // `windowedRows`, NOT `rows`: the window bounds how many rows
            // this eager stack lays out (see `ChatViewModel.windowedRows`).
            ForEach(viewModel.windowedRows) { row in
                // Subtask-indicator resolution stays in THIS body (it reads
                // `stripViewModel.children`, which must keep its observation
                // tracking here); the resolved child participates in the row
                // wrapper's `==` so the card re-renders when the child's
                // running state flips.
                let child: SubChatSummary? = {
                    if case .message(let item) = row { return subtaskChild(for: item) }
                    return nil
                }()
                // Same anchor ids as before the wrapper: ITEM id for message
                // rows (scroll anchors, TOC jumps and restores all target the
                // item id, not `TimelineRow.id`'s `msg:` form), row id for
                // separators.
                let anchorID: String = {
                    if case .message(let item) = row { return item.id }
                    return row.id
                }()
                TimelineRowView(
                    row: row,
                    subtaskChild: child,
                    viewModel: viewModel,
                    onOpenSubChat: onOpenSubChat,
                    onOpenSpawnRoom: onOpenSpawnRoom,
                    onOpenItem: onOpenItem,
                    onOpenMission: onOpenMission,
                    onPreview: onPreview,
                    onTapImage: onTapImage
                )
                .equatable()
                .id(anchorID)
            }
        }
        .scrollTargetLayout()
        .padding(.vertical)
    }
}

/// One timeline row, fenced behind `Equatable` so a stream commit that
/// reassigns `windowedRows` re-evaluates ONLY the rows whose value
/// actually changed (normally just the streaming tail row). Without this
/// gate every commit re-ran body + layout for the whole 120–185-row
/// eager window — the closure properties below made the ForEach content
/// never memcmp-equal, so SwiftUI rebuilt the full view list up to 4×/s
/// during a live turn, pegging the main thread (Mac 2026-08-10 spike
/// samples; the iOS twin has the identical structure). See
/// `MacTimelineRowView` in `MacChatView.swift` for the full invalidation
/// contract: `subtaskChild` is resolved in the parent and compared in
/// `==`; ask-user / agent-chat / image state is `@Observable`-tracked
/// inside this row's own body, so Observation bypasses the gate.
///
/// `onOpenSubChat` presence (nil vs wired) picks Button vs
/// NavigationLink for subtask cards — it's fixed for a given screen
/// (parent chat vs sub-chat pane), so `==` ignoring it is safe.
private struct TimelineRowView: View, Equatable {
    let row: TimelineRow
    let subtaskChild: SubChatSummary?
    let viewModel: ChatViewModel
    let onOpenSubChat: ((String) -> Void)?
    /// Opens a spawned room from a consent card / outcome row. Fixed for a
    /// given screen like `onOpenSubChat` (so `==` ignoring it is safe), and
    /// `nil` where there is nowhere to navigate — the affordance is then
    /// omitted rather than drawn dead.
    let onOpenSpawnRoom: ((String) -> Void)?
    /// Opens the tracker item pane to a tapped `.itemMarker`'s item. Fixed
    /// per screen like `onOpenSpawnRoom`, so `==` ignoring it is safe.
    let onOpenItem: ((String) -> Void)?
    /// Opens the mission page to a tapped `.milestoneMarker` /
    /// `.missionMarker`. Fixed per screen like `onOpenSpawnRoom`, so `==`
    /// ignoring it is safe.
    let onOpenMission: ((String) -> Void)?
    let onPreview: (ChatView.AttachmentPreview) -> Void
    /// Image tap → the screen builds the conversation gallery ONCE here,
    /// at tap time, and stores it in the preview payload. Building it in
    /// the sheet's content closure would re-query the journal on every
    /// parent refresh and could shift entries under the viewer's kept
    /// index (Bugbot, PR #175).
    let onTapImage: (URL, Image) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.subtaskChild == rhs.subtaskChild
            && lhs.viewModel === rhs.viewModel
    }

    var body: some View {
        switch row {
        case .separator(let date):
            DateSeparator(date: date)
        case .message(let item):
            if let child = subtaskChild {
                // Bridge subtask indicator → tappable card opening
                // the child sub-chat (`chatDestination` routes the
                // child id to `SubChatView`).
                Group {
                    if let onOpenSubChat {
                        Button {
                            onOpenSubChat(child.id)
                        } label: {
                            SubtaskLinkCard(title: child.title, isRunning: child.isRunning)
                        }
                    } else {
                        NavigationLink(value: child.id) {
                            SubtaskLinkCard(title: child.title, isRunning: child.isRunning)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            } else {
                TimelineItemView(
                    item: item,
                    resolveImage: { viewModel.image(for: $0) },
                    onRetry: { id in viewModel.retrySend(itemID: id) },
                    onTapImage: onTapImage,
                    onTapFile: { mxc, filename in
                        Task {
                            if let url = await viewModel.writeTempFile(
                                mxcURL: mxc, filename: filename
                            ) {
                                onPreview(.file(url, filename: filename))
                            }
                        }
                    },
                    isDownloadingFile: { viewModel.isDownloadingFile($0) },
                    isMediaUnavailable: { viewModel.isMediaUnavailable($0) },
                    askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                    isPromptAnswered: { viewModel.isPromptAnswered($0) },
                    answerSummary: { viewModel.answerSummary(forPrompt: $0) },
                    agentChatState: { viewModel.agentChatState($0) },
                    onAnswerAgentChat: { eventID, request, approve in
                        Task {
                            await viewModel.answerAgentChat(
                                eventID: eventID, request: request,
                                decision: approve ? .approve : .deny)
                        }
                    },
                    agentSpawnState: { viewModel.agentSpawnState($0, request: $1) },
                    onAnswerAgentSpawn: { eventID, request, approve in
                        Task {
                            // `try?`: the only error that escapes is
                            // cancellation, which the view model has already
                            // handled by dropping the in-flight state.
                            try? await viewModel.answerAgentSpawn(
                                eventID: eventID, request: request,
                                decision: approve ? .approve : .deny)
                        }
                    },
                    onOpenSpawnRoom: onOpenSpawnRoom,
                    onOpenItem: onOpenItem,
                    onOpenMission: onOpenMission,
                    convoID: viewModel.roomID,
                    hasMultipleSenders: viewModel.hasMultipleSenders
                )
                // No `.onAppear` history trigger here: row
                // materialization is not evidence the user
                // scrolled anywhere (an eager stack mounts every
                // row immediately), so window extension is driven
                // solely by the scroll-geometry near-top check in
                // `ChatView`.
                // Copy only (Dan, 2026-08-03: no Share / View
                // source on the phone). An empty builder result
                // (non-text rows) presents no menu at all.
                .contextMenu {
                    if case .text(let body, _) = item.kind {
                        Button {
                            // Use the cross-platform helper from
                            // MatronDesignSystem so iOS and Mac stay
                            // on a single Pasteboard surface
                            // (QA finding #3).
                            Pasteboard.copy(body)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Subagent sub-chats

/// Sticky horizontal strip of a parent chat's RUNNING subagents. Each pill
/// shows the child's title + a live spinner; tapping pushes the child's
/// read-only sub-chat onto the same navigation stack (a plain
/// `NavigationLink` — the child id is a valid stack value, and
/// `ChatListView.chatDestination` routes it to `SubChatView`). Renders
/// nothing when no subagent is running, so the parent timeline reclaims the
/// space (spec §3: hidden when no running children).
struct RunningSubagentStrip: View {
    let viewModel: SubChatStripViewModel

    var body: some View {
        if !viewModel.runningChildren.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.runningChildren) { child in
                        NavigationLink(value: child.id) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(child.title)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open subagent \(child.title)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

/// Read-only viewer for a subagent child conversation. Reuses the full chat
/// timeline (`TimelineListContent`) with NO composer, under a mini-header
/// carrying the child's title, model, its own context gauge, running/
/// finished state, and a switcher between the parent's active children
/// (spec §4). Nesting is supported at the data/routing layer (`children(of:)`
/// recurses and `chatDestination` routes a grandchild id here too), but the
/// viewer renders no strip of its own: the bridge flattens nested agents into
/// direct children of the top-level session, so grandchildren never occur.
struct SubChatView: View {
    @State var viewModel: ChatViewModel
    /// Shared strip VM for this child's PARENT — its `children` are this
    /// child's siblings (the switcher's source, and where this child's
    /// title / running-state come from).
    @State var stripViewModel: SubChatStripViewModel
    let childID: String
    let fallbackTitle: String

    @Environment(\.chatNavigationPath) private var navigationPath
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @State private var attachmentPreview: ChatView.AttachmentPreview?
    /// Captured only to install `HorizontalOverflowLock` — the sub-chat
    /// timeline must be as wiggle-proof as the parent's (ChatView).
    @State private var nativeScroll = NativeScrollViewBox()
    @State private var startedGeneration = 0
    /// Generation guard for the SHARED per-parent strip VM — switching to a
    /// sibling replaces this view, and the successor's `.task` can restart
    /// the strip before this instance's `onDisappear` fires (see ChatView).
    @State private var stripStartedGeneration = 0
    /// Sticky follow flag, gesture-driven like the parent timeline's:
    /// only a real user drag releases it. Geometry alone must not — the
    /// viewport can leave the bottom with no gesture while a tool-heavy
    /// turn streams (2026-07-14 06:41 trace), and a sub-chat is a pure
    /// streaming viewer, so a geometry-gated anchor would silently stop
    /// following mid-stream.
    @State private var isFollowingTail = true
    /// Bottom-edge proximity, same 100pt threshold as the parent timeline
    /// (`TimelineScrollModel.Metrics.nearBottomThreshold`). Re-arms `isFollowingTail` when
    /// a drag settles at the tail, and gates the follow heal.
    @State private var isNearBottom = true
    /// Debounced re-pin while following — same rationale as the parent
    /// timeline's heal task: the `.sizeChanges` anchor alone doesn't
    /// recover once churn has moved the viewport off the bottom.
    @State private var followHealTask: Task<Void, Never>?

    /// proxy.scrollTo target for the jump button — a zero-size sentinel
    /// after the last row (the eager VStack keeps it mounted, so the
    /// parent timeline's dead-anchor hazard doesn't apply here).
    private static let bottomSentinelID = "subchat-bottom"

    private var currentChild: SubChatSummary? {
        stripViewModel.children.first { $0.id == childID }
    }

    var body: some View {
        VStack(spacing: 0) {
            SubChatMiniHeader(
                title: currentChild?.title ?? fallbackTitle,
                model: viewModel.sessionStatus?.model,
                context: viewModel.sessionStatus?.context,
                // A child not yet in the (freshly-subscribed) list is
                // assumed running — the strip only ever links running ones.
                isRunning: currentChild?.isRunning ?? true,
                siblings: stripViewModel.children,
                currentID: childID,
                onSwitch: switchTo
            )
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // `stripViewModel` here is the PARENT's strip, whose
                        // children are this child's siblings — and the bridge
                        // flattens nested agents into siblings, so a nested
                        // "🔀 Subtask:" indicator in this timeline resolves to
                        // the flattened sibling and links correctly too.
                        TimelineListContent(
                            viewModel: viewModel,
                            stripViewModel: stripViewModel,
                            onOpenSubChat: switchTo,
                            onOpenSpawnRoom: openSpawnedRoom,
                            // No items drawer inside a sub-chat pane — an
                            // `.itemMarker` card here renders inert (nil
                            // still gives the card its tappable chrome, the
                            // tap just does nothing). Same scope decision
                            // as the Mac twin's `MacSubChatPane`.
                            onOpenItem: nil,
                            onOpenMission: nil,
                            onPreview: { attachmentPreview = $0 },
                            onTapImage: { url, img in
                                attachmentPreview = .image(ImageGalleries.conversation(
                                    tapped: url, image: img, chatViewModel: viewModel,
                                    deps: deps, session: session
                                ))
                            }
                        )
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomSentinelID)
                    }
                    // Same wiggle lock as the parent timeline (ChatView) —
                    // a too-wide row must clamp + log, never pan sideways.
                    .captureNativeScrollView(into: nativeScroll,
                                             lockingHorizontalOverflow: true)
                }
                .overlay {
                    if viewModel.rows.isEmpty { TimelineLoadingIndicator() }
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .scrollDismissesKeyboard(.interactively)
                // Follow the live tail until the user drags away;
                // a drag that settles back at the bottom re-arms it.
                .defaultScrollAnchor(isFollowingTail ? .bottom : nil, for: .sizeChanges)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.visibleRect.maxY >= geo.contentSize.height - 100
                } action: { _, nearBottom in
                    if isNearBottom != nearBottom { isNearBottom = nearBottom }
                    // Follow heal: churn can move the viewport off the
                    // bottom with no user gesture; the anchor alone won't
                    // pull it back. Debounced like the parent timeline's.
                    if !nearBottom, isFollowingTail {
                        followHealTask?.cancel()
                        followHealTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled, isFollowingTail, !isNearBottom else { return }
                            proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
                        }
                    } else {
                        followHealTask?.cancel()
                        followHealTask = nil
                    }
                }
                // Only a real drag exits follow mode — programmatic
                // scrolls and layout drift never report `.interacting`.
                .onUserScrollGesture(
                    begin: { if isFollowingTail { isFollowingTail = false } },
                    settle: { if !isFollowingTail, isNearBottom { isFollowingTail = true } }
                )
                // Same affordance as the parent timeline: visible whenever
                // the user has left the live tail (Dan, 2026-07-16).
                .overlay(alignment: .bottomTrailing) {
                    if !isFollowingTail {
                        JumpToBottomButton {
                            isFollowingTail = true
                            // Kill any in-flight fling first — scrollTo
                            // issued during deceleration is overridden by
                            // the deceleration animator (see
                            // `NativeScrollViewBox`).
                            nativeScroll.killMomentumAndSnapToBottom()
                            proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(MatronTimelineBackground())
        .navigationTitle(currentChild?.title ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            startedGeneration = viewModel.observationGeneration + 1
            stripViewModel.start()
            stripStartedGeneration = stripViewModel.observationGeneration
            await viewModel.start()
            // Seed history over HTTP (the child's rows may not be mirrored
            // locally yet), same as the full chat screen. No markAsRead:
            // children carry no unread state (they're silent).
            await viewModel.paginateBackward()
        }
        .onDisappear {
            followHealTask?.cancel()
            viewModel.stop(ifGeneration: startedGeneration)
            stripViewModel.stop(ifGeneration: stripStartedGeneration)
            // Same viewer-socket hygiene as the parent chat's onDisappear,
            // scoped to this child so the parent's tiles stay live.
            LiveOutputSessionStore.shared.suspendSessions(in: viewModel.roomID)
        }
        .sheet(item: $attachmentPreview) { preview in
            switch preview {
            case .image(_, let gallery):
                AttachmentFullscreenViewer(gallery: gallery, onDismiss: { attachmentPreview = nil })
            case .file(_, let url, let filename):
                FilePreviewSheet(url: url, filename: filename,
                                 onDone: { attachmentPreview = nil })
            }
        }
    }

    /// Switch the viewer to a sibling subagent: replace the current child
    /// on the nav stack (pop-then-push, `pathReplacingCurrentChild`) so
    /// switching between subagents — via the mini-header menu or a subtask
    /// card in this timeline — doesn't grow the back stack.
    private func switchTo(_ siblingID: String) {
        guard let navigationPath,
              let newPath = SubChatStripViewModel.pathReplacingCurrentChild(
                  in: navigationPath.wrappedValue, current: childID, with: siblingID)
        else { return }
        navigationPath.wrappedValue = newPath
    }

    /// "Open" on a started spawn, from a sub-chat's timeline — the spawned
    /// room is a top-level conversation, so this PUSHES rather than
    /// replacing the way sibling switching does.
    private func openSpawnedRoom(_ roomID: String) {
        Task { @MainActor in
            await pushSpawnedRoom(roomID, path: navigationPath, deps: deps, session: session)
        }
    }
}

/// Pushes a spawned room onto the chat navigation stack.
///
/// `prepareConversation` first, for the same reason the New Chat sheet does
/// it before navigating to a freshly-started conversation: the room may have
/// no journal frames yet, and `chatDestination` needs a conversation row to
/// resolve — without the placeholder the push lands on nothing.
///
/// A repeat tap on a card already at the top of the stack is a no-op rather
/// than a second push of the same room.
@MainActor
private func pushSpawnedRoom(_ roomID: String, path: Binding<[String]>?,
                             deps: AppDependencies?, session: UserSession?) async {
    if let deps, let session {
        await deps.prepareConversation(for: session, id: roomID)
    }
    guard let path, path.wrappedValue.last != roomID else { return }
    path.wrappedValue.append(roomID)
}

/// The sub-chat viewer's mini-header: title + running spinner, model +
/// state line, own context gauge, and (when the parent has more than one
/// child) a switcher menu among the siblings.
private struct SubChatMiniHeader: View {
    let title: String
    let model: String?
    let context: SessionStatus.Context?
    let isRunning: Bool
    let siblings: [SubChatSummary]
    let currentID: String
    let onSwitch: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isRunning { ProgressView().controlSize(.mini) }
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let model, !model.isEmpty {
                        Text(model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(isRunning ? "Running" : "Finished")
                        .font(.caption2)
                        .foregroundStyle(isRunning ? Color.accentColor : .secondary)
                }
            }
            Spacer(minLength: 8)
            if let context {
                ContextGaugeLabel(context: context)
            }
            if siblings.count > 1 {
                Menu {
                    ForEach(siblings) { sibling in
                        Button {
                            onSwitch(sibling.id)
                        } label: {
                            Label(
                                sibling.title,
                                systemImage: sibling.id == currentID ? "checkmark"
                                    : (sibling.isRunning ? "circle.fill" : "circle")
                            )
                        }
                        .disabled(sibling.id == currentID)
                    }
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .accessibilityLabel("Switch subagent")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

