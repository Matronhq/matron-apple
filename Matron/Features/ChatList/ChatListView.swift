import SwiftUI
import MatronChat
import MatronModels
import MatronStorage
import MatronVerification
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
    /// The chat whose ⓘ button was tapped. Setting this drives the
    /// `.sheet(item:)` presentation of `BotProfileView`. Cleared back to
    /// `nil` either by the sheet's onDismiss or when the user picks a chat
    /// from inside the sheet.
    @State private var botProfileSummary: ChatSummary?
    /// The summary whose "Verify" button on a `VerificationBanner` was
    /// tapped. Drives the `.sheet(item:)` presentation of `SasView`.
    /// Cleared back to `nil` by the sheet's `onFinished` (the SAS reaches
    /// `.verified`) or by an explicit dismiss inside the sheet.
    @State private var sasSummary: VerificationRequestSummary?
    /// Settings → Device sheet visibility (Task 11). Phase 7 will land
    /// the full Settings UI; this Phase-3 surface ships the
    /// device-verification + recovery-key reveal flow inside an
    /// otherwise-empty sheet so users can read their key without
    /// digging through the menu bar.
    @State private var showingDeviceSettings = false
    /// Sign-out callback owned by `MatronApp` (drops the in-memory session
    /// + clears persistent state). Optional so previews / tests that
    /// don't wire the full app can still construct the view. Phase-7
    /// spec lands a Settings → Account → Sign Out flow; this Phase-2
    /// hook keeps the user from being stranded once Sign Out is exposed
    /// from the menu (QA finding #7).
    var onSignOut: (() -> Void)? = nil
    /// Cross-platform incoming-verification orchestrator (spec §7.1, §5.9).
    /// Optional so previews / tests that exercise only the chat-list
    /// rendering can construct the view without standing up a full
    /// verification stack. When non-nil, `start()` runs in `.onAppear` and
    /// `stop()` in `.onDisappear` — Swift 6 strict concurrency forbids a
    /// `@MainActor deinit` reaching into isolated state, so the lifecycle
    /// hooks are explicit (mirrors the `ChatListViewModel.cancel()` pattern).
    var verificationCenter: VerificationCenter? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Verification banners surface above whatever list state is
            // showing — loading, error, empty, or populated. One banner
            // per pending request (spec §7.1, §5.9). The host wires
            // `verificationCenter` from `MatronApp`; tests / previews
            // omit it and the `if let` short-circuits.
            if let center = verificationCenter, !center.pending.isEmpty {
                VStack(spacing: 8) {
                    ForEach(center.pending) { summary in
                        VerificationBanner(
                            summary: summary,
                            onAccept: { sasSummary = $0 },
                            onDismiss: { dismissed in
                                Task { await center.dismiss(dismissed) }
                            }
                        )
                    }
                }
                .padding(.top, 8)
            }
            chatListContent
        }
        .navigationTitle("Matron")
        .toolbar {
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
        .sheet(item: $sasSummary) { summary in
            // SAS sheet driven by the banner's "Verify" tap. Build the
            // service inline (mirrors `PostLoginVerificationView`) so the
            // sheet body owns no long-lived SDK state — when the sheet
            // dismisses the controller is released. Without `deps` /
            // `session` we render a minimal placeholder so the binding is
            // still observable in tests / previews.
            if let deps, let session {
                sasSheetContent(for: summary, deps: deps, session: session)
            } else {
                Text("Verification unavailable")
                    .padding()
            }
        }
        .sheet(isPresented: $showingDeviceSettings) {
            // Settings → Device. Wraps `DeviceSettingsView` in a
            // `NavigationStack` so the navigationTitle renders + the
            // sheet has a Done button. Construction reuses the
            // `verificationCenter.service` (so the FlowStore stays
            // shared with the incoming-request banner) and forwards
            // a closure that reads `RecoveryKeyManager.currentKey()`
            // — the closure indirection keeps the view itself free
            // of the manager so it stays trivially testable.
            if let deps, let session {
                NavigationStack {
                    deviceSettingsSheetBody(for: deps, session: session)
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
        .navigationDestination(for: ChatSummary.ID.self) { id in
            chatDestination(for: id)
        }
        .task { viewModel.start() }
        // `verificationCenter.start()` belongs in `.onAppear`, not
        // `.task`: Swift 6 strict concurrency forbids a `@MainActor deinit`
        // touching isolated state, so the explicit `start` / `stop` pair
        // is the lifecycle. Mirrors `ChatListViewModel.cancel()`. Optional
        // cast lets previews / tests omit the center entirely.
        .onAppear { verificationCenter?.start() }
        .onDisappear {
            viewModel.cancel()
            verificationCenter?.stop()
        }
    }

    /// Extracted to keep `body` readable now that the verification banner
    /// sits above this list. Same render branches as before — loading /
    /// error / empty / populated — just lifted out.
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
                await runChatActionAwaiting { try await $0.refresh() }
            }
        }
    }

    /// Builds the SAS sheet shown when a banner's "Verify" is tapped.
    /// Hands construction to the per-present `IncomingRequestSasSheet`
    /// view whose `@State`-stored SasViewModel survives parent re-renders
    /// (Wave 4 expert-QA #8 — mirrors the Wave 2 fix to `ChatView`'s
    /// per-bot SAS sheet). The prior inline construction here rebuilt
    /// the VM + reopened a fresh `acceptIncoming` stream on every parent
    /// `@State` mutation (`viewModel.groups` updates, `botProfileSummary`
    /// flips, etc.), so partner-side SAS state transitions could reach
    /// an orphaned VM whose continuation the visible sheet was no
    /// longer observing.
    @ViewBuilder
    private func sasSheetContent(
        for summary: VerificationRequestSummary,
        deps: AppDependencies,
        session: UserSession
    ) -> some View {
        // Reuse the VerificationCenter's service so acceptIncoming hits the
        // SAME FlowStore that registered the incoming request. A fresh
        // VerificationServiceLive would have an empty FlowStore and yield
        // .cancelled("Unknown request: …") immediately. Falls back to the
        // cached `verificationService(for:)` only if no center is wired
        // (test/preview path); the cached instance is itself shared with
        // every other consumer in the app.
        let svc: any VerificationService = verificationCenter?.service
            ?? deps.verificationService(for: session)
        IncomingRequestSasSheet(
            service: svc,
            requestID: summary.id,
            onFinished: { sasSummary = nil }
        )
    }

    /// Builds the `DeviceSettingsView` body for the Settings sheet
    /// (Task 11). Reuses the `VerificationCenter.service` so any
    /// per-account verification check shares the same cache as the
    /// incoming-request banner; falls back to a fresh
    /// `VerificationServiceLive` when no center is wired (test /
    /// preview path). The recovery-key closure forwards
    /// `RecoveryKeyManager.currentKey()` — closure indirection keeps
    /// the view free of `RecoveryKeyManager` so it stays trivially
    /// testable without a real Keychain.
    @ViewBuilder
    private func deviceSettingsSheetBody(
        for deps: AppDependencies,
        session: UserSession
    ) -> some View {
        let svc: VerificationService = verificationCenter?.service
            ?? deps.verificationService(for: session)
        let mgr = RecoveryKeyManager(
            provider: deps.clientProvider,
            session: session,
            keychain: KeychainStore.recoveryStore()
        )
        DeviceSettingsView(
            session: session,
            verificationService: svc,
            currentRecoveryKey: { try mgr.currentKey() }
        )
    }

    /// Builds the `ChatView` destination for a tapped row. Wrapped in a
    /// helper so `body` stays readable and the `nil`-environment branch
    /// doesn't leak SwiftUI conditional-content quirks into the main flow.
    ///
    /// Resolves the destination's `ChatSummary` from `viewModel.groups`
    /// by id rather than capturing it at navigation time — see the file
    /// header for the stale-capture rationale. If the lookup returns
    /// `nil` (the room left the snapshot while the user was tapping),
    /// the `Session unavailable`-style placeholder shows the same way
    /// it does for a missing environment.
    @ViewBuilder
    func chatDestination(for id: ChatSummary.ID) -> some View {
        if let deps, let session, let summary = currentSummary(for: id) {
            let timelineSvc = deps.timelineService(for: session, roomID: summary.id)
            let mediaSvc = deps.mediaService(for: session)
            let chatVM = ChatViewModel(roomID: summary.id, timeline: timelineSvc, media: mediaSvc)
            let composerVM = ComposerViewModel(timeline: timelineSvc, commands: BotCommandCatalog.claudeBridge)
            ChatView(
                viewModel: chatVM,
                composerVM: composerVM,
                chatTitle: summary.title,
                onShowBotProfile: { botProfileSummary = summary },
                // Reuse the VerificationCenter's service so the per-bot
                // banner's SAS sheet hits the SAME FlowStore that any
                // incoming verification request was registered against
                // — building a fresh `VerificationServiceLive` would
                // hit an empty FlowStore (mirrors the comment on
                // `sasSheetContent`). Falls back to a fresh instance
                // when no center is wired (test/preview path).
                verificationService: verificationCenter?.service
                    ?? deps.verificationService(for: session),
                botMatrixID: summary.bot.matrixID
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

/// Per-present SAS sheet body for an incoming verification request from
/// the chat-list banner. Owns the `SasViewModel` + stream as `@State` so
/// they're constructed exactly once per present — `.sheet(item:)` on the
/// parent guarantees this view itself is built exactly once per present,
/// and storing the VM in `@State` here keeps it stable across the
/// parent's body re-evaluations (Wave 4 expert-QA #8). Mirrors the
/// pattern the Wave 2 fix introduced for `ChatView`'s per-bot SAS sheet
/// — see `Matron/Features/Chat/ChatView.swift`'s `VerifyBotSheet` for
/// the full rationale.
///
/// Cache key here is the SDK-assigned `requestID` (the banner summary's
/// id), not the user matrix ID — that's the FlowStore key
/// `VerificationServiceLive.routeIncomingRequest` registered the
/// incoming-request controller under.
private struct IncomingRequestSasSheet: View {
    @State private var viewModel: SasViewModel
    private let onFinished: () -> Void

    init(service: VerificationService, requestID: String, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        // SwiftUI initialises `_viewModel` exactly once per view-identity.
        // `.sheet(item:)` gives this view a fresh identity per present,
        // so the VM is created once per "tap → dismiss" cycle. Subsequent
        // parent re-renders re-init the View struct but SwiftUI ignores
        // the state's initial value once it's been seeded.
        let stream = service.acceptIncoming(requestID: requestID)
        _viewModel = State(initialValue: SasViewModel(
            stream: stream,
            requestID: requestID,
            confirm: { try await service.confirmEmojiMatch(requestID: requestID) },
            cancel: { reason in try await service.cancel(requestID: requestID, reason: reason) }
        ))
    }

    var body: some View {
        SasView(
            viewModel: viewModel,
            title: "Verify device",
            onFinished: onFinished
        )
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
