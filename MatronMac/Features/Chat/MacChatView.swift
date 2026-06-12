import SwiftUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronVerification
import MatronViewModels
import MatronDesignSystem
import os

/// Diagnostic logger for the chat paginate trigger plumbing. Calls
/// to `paginateLogger.diag(...)` are gated by `MatronDebug.enabled`
/// so they stay in the source as living documentation of the data
/// flow without paying for them at runtime in shipped builds.
private let paginateLogger = Logger(subsystem: "chat.matron", category: "mac-chat-paginate")

/// Mac chat detail column. Hosts a `ScrollView` + `LazyVStack` of
/// `MacTimelineItemView` rows above the `MacComposerView`. Right-click
/// context menu replaces iOS's long-press; `⌘K` (hidden button) toggles
/// the slash palette without the user typing `/`. `⌘R` refresh is wired
/// via `NotificationCenter.matronCommand(.refresh)` (Task 14e attaches
/// the menu item; the listener stays attached even when the menu is
/// absent, so trackpad-only Macs without a hardware ⌘R can still drive
/// refresh once a binding lands).
///
/// Drag-and-drop attachments via `.onDrop(of: [.image, .fileURL], delegate:)`,
/// which routes through `ComposerDropDelegate → ComposerViewModel.attachFiles(_:)`
/// — same pipeline as the iOS PhotosPicker / fileImporter sites. The
/// security-scoped-resource bracketing the iOS `fileImporter` site
/// requires isn't needed here because the Mac sandbox grants drop URLs
/// transparent read access via the
/// `com.apple.security.files.user-selected.read-only` entitlement.
struct MacChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel
    /// Backing state for the right-click "View source" sheet (Task 16).
    /// `TimelineItem` is `Identifiable` (the SDK's stable
    /// `TimelineUniqueId.id`), so `.sheet(item:)` re-presents a fresh sheet
    /// when the user picks a different row.
    @State private var sourceItem: TimelineItem?
    /// Per-bot verification state (Task 10, spec §7.3, §7.5). `nil` until
    /// `evaluateBotVerification()` resolves; otherwise the tri-state result
    /// from `VerificationService.isUserVerified(matrixID:)` (M2). Banner
    /// renders ONLY on `.unverified` — `.verified` and `.unknown`
    /// (cold-start: identity not yet in the local crypto store) both hide,
    /// so the banner doesn't flash before sliding-sync warms up
    /// `/keys/query`. §7.5 trust posture is preserved because the
    /// `.unknown` arm re-evaluates on the next sync tick.
    @State private var botVerification: UserVerificationResult? = nil
    /// Drives the per-bot SAS sheet via `.sheet(item:)`. B2/M5 fix —
    /// see iOS `ChatView` for full rationale. The wrapper exists so
    /// `.sheet(item:)` gets a stable `Identifiable` to key on; identity
    /// is the bot's matrixID itself.
    @State private var verifyBotContext: VerifyBotSheetContext?
    /// Bottom-anchored visible item id, bound to `.scrollPosition` on
    /// the timeline ScrollView. Drives both the per-room scroll memory
    /// (so reopening a chat lands where the user left off) and the
    /// floating jump-to-latest button.
    @State private var scrolledItemID: String?
    /// Backing state for the fullscreen image preview. Files take a
    /// different path on Mac — `NSWorkspace.shared.open(_:)` hands
    /// the temp file to QuickLook / the user's preferred app, which
    /// means no SwiftUI sheet is needed. Only image taps land here.
    @State private var imagePreview: ImagePreview?
    /// The ask-user prompt currently presented as a fixed-size sheet
    /// (Phase 5 Task 11). Same contract as iOS `ChatView`: refreshed
    /// from `viewModel.pendingAsk()` per snapshot, nil hides, an
    /// answer from another device auto-dismisses.
    @State private var pendingAskPrompt: AskUserPromptContext?

    /// Identifiable wrapper around a SwiftUI `Image` so
    /// `.sheet(item:)` has something to key on. Per-present UUID so
    /// two consecutive taps re-mount the sheet.
    fileprivate struct ImagePreview: Identifiable {
        let id = UUID()
        let image: Image
    }

    /// Identifiable wrapper for `.sheet(item:)`. See iOS `ChatView`.
    fileprivate struct VerifyBotSheetContext: Identifiable, Hashable {
        let id: String
    }

    let chatTitle: String
    let onShowBotProfile: () -> Void
    /// See iOS `ChatView` for rationale — both optional so existing
    /// tests / previews keep compiling.
    var verificationService: VerificationService? = nil
    var botMatrixID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Per-bot verification banner (spec §7.3, §7.5). Mirrors the
            // iOS `ChatView` placement — above the error banner so a
            // user who's both unverified and hit a sliding-sync timeout
            // sees both signals. Only `.unverified` draws — `.unknown`
            // and `.verified` hide (M2 cold-start posture).
            if botVerification == .unverified {
                botVerificationBanner
            }
            // QA finding #10: mirror the iOS error banner. Sliding-sync
            // timeouts now surface here instead of leaving the user
            // staring at an empty scroll view.
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
            if viewModel.items.isEmpty
                && viewModel.hasReceivedFirstSnapshot
                && viewModel.error == nil {
                // Settled-empty branch — see iOS `ChatView` for the
                // full rationale. `hasReceivedFirstSnapshot` is the
                // disambiguator between "still loading" and "settled
                // empty"; without it the placeholder would flash on
                // every cold-start chat open before sliding-sync warms.
                EmptyChatPlaceholder(botName: chatTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Render `rows` (messages interleaved with date
                    // separators) instead of `items` directly. Mirrors
                    // the iOS surface — the bucketing logic lives in
                    // `ChatViewModel.rows` so the two platforms can't
                    // drift.
                    ForEach(viewModel.rows) { row in
                        switch row {
                        case .separator(let date):
                            DateSeparator(date: date)
                                .id(row.id)
                        case .message(let item):
                            MacTimelineItemView(
                                item: item,
                                resolveImage: { viewModel.image(for: $0) },
                                onRetry: { id in viewModel.retrySend(itemID: id) },
                                onTapImage: { img in
                                    imagePreview = ImagePreview(image: img)
                                },
                                onTapFile: { mxc, filename in
                                    Task {
                                        if let url = await viewModel.writeTempFile(
                                            mxcURL: mxc, filename: filename
                                        ) {
                                            // Hand off to the system —
                                            // QuickLook / the user's
                                            // chosen app handles the
                                            // open. Stays inside the
                                            // SwiftUI surface (no
                                            // need for a sheet on
                                            // Mac since the OS shell
                                            // owns the open path).
                                            await MainActor.run {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                    }
                                }
                            )
                                .id(item.id)
                                .onAppear {
                                    let match = (item.id == viewModel.firstRenderableItemID)
                                    paginateLogger.diag("onAppear: id=\(item.id) first=\(viewModel.firstRenderableItemID ?? "nil") match=\(match)")
                                    if match {
                                        Task { await viewModel.paginateBackward() }
                                    }
                                }
                                .contextMenu {
                                    if case .text(let body, _) = item.kind {
                                        Button {
                                            Pasteboard.copy(body)
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        ShareLink(item: body) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    // "View source" applies to every kind —
                                    // text, image, file, stateChange, unknown
                                    // — so it lives outside the `.text` guard.
                                    Button {
                                        sourceItem = item
                                    } label: {
                                        Label("View source", systemImage: "curlybraces")
                                    }
                                }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical)
            }
            // Mirror iOS — `.scrollPosition(id:)` binds the bottom-anchored
            // visible row id, which we use both for the per-room scroll
            // memory and for the jump-to-latest overlay.
            .scrollPosition(id: $scrolledItemID, anchor: .bottom)
            .onChange(of: viewModel.lastRenderableItemID) { oldID, newID in
                // Auto-follow the live tail only if the user was already
                // there. Scrolled-up users keep their position; the
                // floating button is the path back.
                guard let newID else { return }
                let wasAtTail = (scrolledItemID == oldID) || (scrolledItemID == nil)
                if wasAtTail {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        scrolledItemID = newID
                    }
                }
            }
            // Paginate when the visible bottom row enters the first
            // ~10 row ids (separators + messages combined). See iOS
            // ChatView for the full rationale: the scroll-position
            // binding uses mixed-namespace ids (messages → `item.id`,
            // separators → `"sep:<epoch>"`) so the prefix check has
            // to handle both.
            .onChange(of: scrolledItemID) { _, newID in
                guard let newID else { return }
                let topRowIDs: Set<String> = Set(
                    viewModel.rows.prefix(10).map { row in
                        switch row {
                        case .message(let item): return item.id
                        case .separator: return row.id
                        }
                    }
                )
                let inTop = topRowIDs.contains(newID)
                paginateLogger.diag("scrollChange: bottom=\(newID) inTop10=\(inTop) rows=\(viewModel.rows.count)")
                if inTop {
                    Task { await viewModel.paginateBackward() }
                }
            }
            // "Loading earlier messages…" pill — see iOS `ChatView`
            // for the overlay rationale + `MinDisplayDuration`'s
            // role keeping fast-paginate flashes perceptible.
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
                if let last = viewModel.lastRenderableItemID, scrolledItemID != last {
                    JumpToBottomButton {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrolledItemID = last
                        }
                        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                    }
                }
            }
            }

            Divider()

            // Drag-and-drop attachments via ComposerDropDelegate.
            MacComposerView(viewModel: composerVM)
                .onDrop(
                    of: [.image, .fileURL],
                    delegate: ComposerDropDelegate(composer: composerVM)
                )
        }
        .toolbar {
            MacChatToolbar(
                title: chatTitle,
                viewModel: viewModel,
                onShowBotProfile: onShowBotProfile
            )
        }
        .task {
            // Restore the per-room scroll position BEFORE start() —
            // see iOS `ChatView` for the auto-follow guard rationale.
            scrolledItemID = ChatScrollPositionMemory.retrieve(roomID: viewModel.roomID)
            // `start()` (round-3 bugbot fix #3) returns once the first
            // timeline snapshot has been applied, so the chained
            // `markAsRead()` marks the actual head of the timeline as
            // read instead of racing the empty initial state.
            await viewModel.start()
            await viewModel.markAsRead()
            // Explicit paginate-on-open. Sliding sync seeds the
            // timeline with just the latest event; without this the
            // user sees a single message until they scroll up. The
            // topmost-row `.onAppear` trigger covers subsequent loads
            // as the user scrolls — this just seeds the first page.
            await viewModel.paginateBackward()
        }
        // Per-bot verification check on appear AND each time the
        // timeline gains its first items — that's the cheapest signal
        // for "sliding-sync delivered enough state that the local
        // crypto store probably has the user identity now". Keying on
        // `items.isEmpty` re-fires exactly once when the empty initial
        // snapshot transitions to a populated one, so M2's `.unknown`
        // cold-start result resolves to `.verified` / `.unverified`
        // without requiring the user to re-open the chat. Separate
        // `.task` so the (cheap) identity lookup doesn't share a
        // cancellation lifecycle with the long-lived timeline
        // observation.
        .task(id: viewModel.items.isEmpty) { await evaluateBotVerification() }
        .onDisappear {
            // Persist the user's scroll position so the next open of
            // this room lands where they left off; drop the entry on
            // tail so the default jump-to-tail behaviour applies.
            if let id = scrolledItemID, id != viewModel.lastRenderableItemID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            }
            viewModel.stop()
        }
        // ⌘K opens the slash palette without typing `/`. The hidden
        // button is the SwiftUI-recommended pattern for a global keyboard
        // shortcut that doesn't have a visible UI counterpart. Marked
        // accessibilityHidden because the unlabeled button would
        // otherwise be announced as a nameless "button" by VoiceOver
        // (QA finding #21).
        .background(
            Button("") { composerVM.palettePinnedOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        // ⌘R refresh — driven by the menu-bar command bus (Task 14e).
        // When focus is on a chat detail column, ⌘R reloads THIS
        // chat's timeline (paginate-backward via
        // `ChatViewModel.refresh()`). The chat-list `⌘R` /
        // pull-to-refresh in `MacChatListView.refreshable` handles
        // the list-level snapshot via `ChatService.forceSnapshot()` —
        // those are different surfaces and stay separately wired.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.refresh))) { _ in
            Task { await viewModel.refresh() }
        }
        // ⌘K menu route — `Commands.swift` posts `.slashCommand` from
        // the Edit menu's "Slash Command" item. Without this listener
        // the menu route was dead (the keyboard shortcut still worked
        // via the hidden Button above, but the menu picked the same
        // notification and dropped it). QA finding #2.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.slashCommand))) { _ in
            composerVM.palettePinnedOpen.toggle()
        }
        .sheet(item: $sourceItem) { item in
            MacEventSourceSheet(item: item, onDismiss: { sourceItem = nil })
        }
        .sheet(item: $verifyBotContext) { context in
            verifyBotSheetBody(for: context.id)
        }
        // Mac fullscreen image preview — Mac's `NSWorkspace.shared.open`
        // already owns the file path, so the only sheet wired here is
        // for the in-app pinch-zoom-style image viewer.
        .sheet(item: $imagePreview) { preview in
            AttachmentFullscreenViewer(
                image: preview.image,
                onDismiss: { imagePreview = nil }
            )
        }
        // Phase 5 Task 11: ask-user prompt sheet. Same drive logic as
        // iOS `ChatView`; the presentation differs — fixed 520×400
        // frame because Mac sheets have no detents (spec §5.9).
        .onChange(of: viewModel.items) { _, _ in
            pendingAskPrompt = viewModel.pendingAsk()
        }
        .sheet(item: askUserSheetBinding) { ctx in
            MacAskUserSheet(
                viewModel: viewModel.makeAskUserSheetViewModel(
                    eventID: ctx.id,
                    event: ctx.event,
                    onClose: { closeAskUserSheet(ctx) }
                ),
                onClose: { closeAskUserSheet(ctx) }
            )
            .frame(width: 520, height: 400)
        }
    }

    /// See iOS `ChatView.askUserSheetBinding` — intercepts interactive
    /// dismissal (Esc / Close) so the prompt doesn't re-pop on the
    /// next snapshot.
    private var askUserSheetBinding: Binding<AskUserPromptContext?> {
        Binding(
            get: { pendingAskPrompt },
            set: { newValue in
                if newValue == nil, let ctx = pendingAskPrompt {
                    viewModel.markPromptAnswered(ctx.id)
                }
                pendingAskPrompt = newValue
            }
        )
    }

    private func closeAskUserSheet(_ ctx: AskUserPromptContext) {
        viewModel.markPromptAnswered(ctx.id)
        pendingAskPrompt = nil
    }

    /// Per-bot verification evaluation. See iOS `ChatView` for details —
    /// `nil` keeps the banner hidden during the async query; a thrown
    /// error resolves to `.unknown` so the next sync tick can re-check
    /// (was previously `false` under the Bool shape; M2 widens to
    /// tri-state to avoid the cold-start banner flash).
    private func evaluateBotVerification() async {
        guard let svc = verificationService, let botMatrixID else {
            botVerification = nil
            return
        }
        do {
            botVerification = try await svc.isUserVerified(matrixID: botMatrixID)
        } catch {
            botVerification = .unknown
        }
    }

    /// Inline banner above the timeline. Mirrors the iOS shape; uses
    /// `Color(NSColor.controlBackgroundColor)` for the AppKit-native
    /// neutral background (same precedent as `MacRecoveryKeyView` /
    /// `MacSasView` — the `.ultraThinMaterial` we use on iOS doesn't
    /// composite as cleanly inside the AppKit window).
    @ViewBuilder
    private var botVerificationBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                // PR #3 review #13 — copy reflects bot identity, not
                // device. The banner renders when `botVerification ==
                // .unverified`; tapping triggers user-verification SAS
                // against the bot's matrixID.
                Text("This bot's identity hasn't been verified")
                    .font(.callout)
                    .bold()
                Text("Messages may show a warning until you verify.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Verify") {
                if let botMatrixID {
                    verifyBotContext = VerifyBotSheetContext(id: botMatrixID)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This bot's identity hasn't been verified. Verify.")
    }

    /// Builds the SAS sheet for verifying the bot user. Hands construction
    /// to the per-present `MacSasSheetWrapper` whose `@State`-stored
    /// SasViewModel survives parent re-renders (B2/M5 fix; see iOS
    /// `ChatView` for full rationale).
    @ViewBuilder
    private func verifyBotSheetBody(for botMatrixID: String) -> some View {
        if let svc = verificationService {
            MacSasSheetWrapper(
                service: svc,
                requestID: botMatrixID,
                title: "Verify \(botMatrixID)",
                streamFactory: { $0.startSAS(withUser: botMatrixID, deviceID: nil) },
                onFinished: {
                    verifyBotContext = nil
                    Task { await evaluateBotVerification() }
                },
                onCancelled: {
                    // SAS .cancelled state's "Close" button hits this.
                    // Same dismissal as onFinished; the re-evaluate is a
                    // no-op on cancel but keeps both call sites symmetric.
                    verifyBotContext = nil
                    Task { await evaluateBotVerification() }
                }
            )
        } else {
            Text("Verification unavailable")
                .frame(width: 360, height: 120)
                .padding()
        }
    }
}

