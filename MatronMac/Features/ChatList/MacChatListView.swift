import SwiftUI
import MatronChat
import MatronModels
import MatronVerification
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
    /// The summary whose "Verify" button on a `MacVerificationBanner`
    /// was clicked. Drives the `.sheet(item:)` presentation of
    /// `MacSasView`. Cleared by the sheet's `onFinished` (`.verified`)
    /// or an explicit dismiss.
    @State private var sasSummary: VerificationRequestSummary?
    /// Cross-platform incoming-verification orchestrator (spec §7.1, §5.9).
    /// Optional so previews / tests that exercise only the chat-list
    /// rendering can construct the view without standing up a full
    /// verification stack. When non-nil, `start()` runs in `.onAppear`
    /// and `stop()` in `.onDisappear` (Swift 6 forbids `@MainActor
    /// deinit` reaching isolated state — same lesson as
    /// `ChatListViewModel.cancel()`).
    var verificationCenter: VerificationCenter? = nil
    /// Sign-out callback owned by `MatronMacApp`. Invoked by the
    /// `.onReceive(.signOut)` listener (this view is the active branch
    /// any time the user is signed in + verified, so anchoring the
    /// listener here is reliable — the prior WindowGroup-root anchor
    /// silently dropped notifications when the `Group { … }`'s active
    /// branch changed type, which is what made File → Sign Out a
    /// no-op on macOS post-Phase-3 — Wave 6 / live-test #1).
    var onSignOut: (() -> Void)? = nil
    /// Help → Verify This Device callback owned by `MatronMacApp`.
    /// Same anchor rationale as `onSignOut` — Wave 6 / live-test #2.
    /// Also driven by the in-chat-list "this device hasn't been verified"
    /// banner (Wave 6 / live-test #3), so signed-in users have an
    /// in-app prompt to re-verify rather than relying on the Help menu.
    var onVerifyDevice: (() -> Void)? = nil
    /// Help → Show Recovery Key callback owned by `MatronMacApp`.
    /// Same anchor rationale as `onSignOut` — Wave 6 / live-test #2.
    var onShowRecoveryKey: (() -> Void)? = nil
    /// `VerificationService` used by the in-list "this device hasn't been
    /// verified" banner (Wave 6 / live-test #3) to decide whether to
    /// render. Optional so previews / tests that don't standing up a
    /// real service can omit it (the banner's tri-state state stays
    /// `nil` and renders nothing). Production wiring routes through
    /// `dependencies.verificationService(for: session)`.
    var verificationService: VerificationService? = nil
    /// Re-evaluation token bumped by `MatronMacApp` when the Help →
    /// Verify This Device sheet (or banner-triggered SAS sheet — same
    /// closure) dismisses. Drives the per-this-device verification
    /// `.task(id:)` so a successful self-verify clears the in-list
    /// `MacUnverifiedDeviceBanner` without requiring a full chat-list
    /// re-mount. Defaults to `0` so previews / tests that don't host
    /// the verify-device sheet still get the initial check.
    var verifyDeviceDismissToken: Int = 0
    /// Tri-state per-this-device verification state. `nil` until the
    /// async query resolves, then `true` (verified) or `false`
    /// (unverified). Banner only renders on `false` so it doesn't
    /// flash for verified devices during the initial query — same
    /// pattern as the per-bot banner (`MacChatView.botVerification`).
    @State private var isThisDeviceVerified: Bool? = nil

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
            detail
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
        // Sign Out / Verify Device / Show Recovery Key — Wave 6 / live-test
        // #1+#2 fix. Previously these listeners lived on `MatronMacApp`'s
        // `WindowGroup`-root `Group { … }` content. macOS SwiftUI did not
        // reliably re-install the subscriptions when the Group's active
        // branch changed type (sign-in → verify-gate → chat-list), so the
        // File → Sign Out and Help menu items silently posted into the
        // void. Anchoring on this view (the active branch any time a
        // signed-in + verified user is reachable) is reliable — same
        // shape as `.toggleSidebar` above, which has always worked. The
        // host owns the actual side-effect (clear session, present sheet)
        // via the `onSignOut` / `onVerifyDevice` / `onShowRecoveryKey`
        // closures so the host's `@State` mutators stay co-located with
        // the host. Sign-in screen + verify-gate are intentionally not
        // covered: a user without a session has nothing to sign out of,
        // and a user mid-verification gate is already on the verify path.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.signOut))) { _ in
            onSignOut?()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.verifyDevice))) { _ in
            onVerifyDevice?()
        }
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showRecoveryKey))) { _ in
            onShowRecoveryKey?()
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
        .sheet(item: $sasSummary) { summary in
            // SAS sheet driven by the banner's "Verify" click. Build the
            // service inline (mirrors `MacPostLoginVerificationView`) so
            // the sheet body owns no long-lived SDK state — when the
            // sheet dismisses the controller is released. Without `deps`
            // / `session` we render a minimal placeholder so the binding
            // is still observable in tests / previews.
            if let deps, let session {
                sasSheetContent(for: summary, deps: deps, session: session)
            } else {
                Text("Verification unavailable")
                    .frame(width: 480, height: 200)
                    .padding()
            }
        }
        .task { viewModel.start() }
        // `verificationCenter.start()` belongs in `.onAppear` (Swift 6
        // forbids `@MainActor deinit` reaching isolated state). Mirrors
        // `ChatListViewModel.cancel()`. Optional cast lets previews /
        // tests omit the center entirely.
        .onAppear { verificationCenter?.start() }
        .onDisappear {
            viewModel.cancel()
            verificationCenter?.stop()
        }
        // Wave 6 / live-test #3: per-this-device verification check.
        // Pre-Phase-3 users skipped the post-login verify gate
        // (`verifyDone` was never set on their session) so they have
        // no in-app prompt to verify. The async result drives
        // `MacUnverifiedDeviceBanner` visibility — see the property
        // declaration for the tri-state (`nil` / `true` / `false`)
        // rationale that mirrors the per-bot banner. Keying on
        // `verifyDeviceDismissToken` re-runs the check when the host's
        // verify-device sheet dismisses (a successful self-verify
        // clears the banner without a chat-list re-mount).
        .task(id: verifyDeviceDismissToken) { await evaluateThisDeviceVerification() }
    }

    /// Resolves `isThisDeviceVerified` from the injected
    /// `verificationService`. Failure resolves to `nil` (banner stays
    /// hidden) so a transient SDK error doesn't prompt a verified user
    /// to re-verify — same posture as the per-bot banner's `.unknown`
    /// arm. The next sync tick triggers a re-evaluate via the parent
    /// task lifecycle (the host's `.task { syncService.start() }` and
    /// the verification service's incoming-request stream both keep
    /// the SDK warm; this `.task` runs on `.onAppear` of the chat
    /// list, which is the right cadence for a one-shot check).
    private func evaluateThisDeviceVerification() async {
        guard let svc = verificationService else {
            isThisDeviceVerified = nil
            return
        }
        do {
            isThisDeviceVerified = try await svc.isThisDeviceVerified()
        } catch {
            isThisDeviceVerified = nil
        }
    }

    /// Sidebar column wrapper: when the verification center has pending
    /// requests OR this device is explicitly unverified, stack the
    /// relevant banner(s) above the existing sidebar content. Banner
    /// order: unverified-device (most actionable) → incoming requests
    /// → list. Empty / no-banner case falls straight through to
    /// `sidebar`. Plan §9b — banner sits above the chat list inside the
    /// leading column of `NavigationSplitView`.
    @ViewBuilder
    private var sidebarColumn: some View {
        let hasIncoming = (verificationCenter?.pending.isEmpty == false)
        let showUnverified = (isThisDeviceVerified == false) && (onVerifyDevice != nil)
        if hasIncoming || showUnverified {
            VStack(spacing: 0) {
                if showUnverified {
                    MacUnverifiedDeviceBanner(
                        onVerify: { onVerifyDevice?() }
                    )
                }
                if let center = verificationCenter, !center.pending.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(center.pending) { summary in
                            MacVerificationBanner(
                                summary: summary,
                                onAccept: { sasSummary = $0 },
                                onDismiss: { dismissed in
                                    Task { await center.dismiss(dismissed) }
                                }
                            )
                        }
                    }
                }
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
                await runChatActionAwaiting { try await $0.refresh() }
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
            let composerVM = ComposerViewModel(timeline: timelineSvc, commands: BotCommandCatalog.claudeBridge)
            MacChatView(
                viewModel: chatVM,
                composerVM: composerVM,
                chatTitle: summary.title,
                onShowBotProfile: { botProfileSummary = summary },
                // Reuse the VerificationCenter's service so the per-bot
                // banner's SAS sheet hits the SAME FlowStore that any
                // incoming verification request was registered against
                // (mirrors the iOS `chatDestination` wiring + the
                // `sasSheetContent` rationale on this view).
                verificationService: verificationCenter?.service
                    ?? deps.verificationService(for: session),
                botMatrixID: summary.bot.matrixID
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

    private func runChatActionAwaiting(_ action: @escaping (ChatService) async throws -> Void) async {
        guard let deps, let session else { return }
        let chat = deps.chatService(for: session)
        try? await action(chat)
    }

    /// Builds the SAS sheet shown when a banner's "Verify" is clicked.
    /// Hands construction to the per-present `MacIncomingRequestSasSheet`
    /// view whose `@State`-stored SasViewModel survives parent re-renders
    /// (Wave 4 expert-QA #8 — mirrors the iOS `IncomingRequestSasSheet`
    /// pattern). The prior inline construction here rebuilt the VM +
    /// reopened a fresh `acceptIncoming` stream on every parent
    /// `@State` mutation, so partner-side SAS state transitions could
    /// reach an orphaned VM whose continuation the visible sheet was no
    /// longer observing.
    @ViewBuilder
    private func sasSheetContent(
        for summary: VerificationRequestSummary,
        deps: AppDependencies,
        session: UserSession
    ) -> some View {
        // Reuse the VerificationCenter's service so acceptIncoming hits the
        // SAME FlowStore that registered the incoming request — see iOS
        // ChatListView for the full rationale.
        let svc: any VerificationService = verificationCenter?.service
            ?? deps.verificationService(for: session)
        MacIncomingRequestSasSheet(
            service: svc,
            requestID: summary.id,
            onFinished: { sasSummary = nil }
        )
    }
}

/// Per-present SAS sheet body for an incoming verification request from
/// the Mac sidebar banner. Mirrors iOS `IncomingRequestSasSheet` — see
/// iOS `ChatView.swift`'s `VerifyBotSheet` for the Wave 5 bugbot #2
/// rationale (the prior `init`-side `acceptIncoming` call fired on every
/// parent body re-render and silently cancelled the active continuation
/// via Wave 2 / M3's "Replaced by new flow" drain).
private struct MacIncomingRequestSasSheet: View {
    let service: VerificationService
    let requestID: String
    let onFinished: () -> Void

    @State private var viewModel: SasViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                MacSasView(
                    viewModel: vm,
                    title: "Verify device",
                    onFinished: onFinished
                )
            } else {
                ProgressView("Starting verification…")
            }
        }
        .task(id: requestID) {
            guard viewModel == nil else { return }
            let stream = service.acceptIncoming(requestID: requestID)
            viewModel = SasViewModel(
                stream: stream,
                requestID: requestID,
                confirm: { try await service.confirmEmojiMatch(requestID: requestID) },
                cancel: { reason in try await service.cancel(requestID: requestID, reason: reason) }
            )
        }
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
