import SwiftUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronVerification
import MatronViewModels
import MatronDesignSystem

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
            ScrollViewReader { proxy in
                // `.defaultScrollAnchor(.bottom)` makes the ScrollView
                // open already at the bottom on first layout AND keep
                // the bottom anchored as new messages append — no
                // animated scroll-to-bottom on chat open. The
                // `.onChange` handler below only fires when `last?.id`
                // actually changes, so existing live-update behaviour
                // is unchanged.
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.items) { item in
                            MacTimelineItemView(item: item, resolveImage: { viewModel.image(for: $0) })
                                .id(item.id)
                                // Infinite-scroll backward pagination
                                // trigger: when the topmost row mounts,
                                // request older messages. The view-model
                                // guards against re-entry + reached-start.
                                .onAppear {
                                    if item.id == viewModel.items.first?.id {
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
                    .padding(.vertical)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: viewModel.items.last?.id) { _, _ in
                    // Round-3 bugbot finding #5: keying on `items.count`
                    // missed `.set` diffs that swap a local-echo id for
                    // a remote-event id (count constant, last id moves)
                    // and remove+add diff batches (count constant, last
                    // id moves). Keying on `last?.id` catches both.
                    if let last = viewModel.items.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
            // `start()` (round-3 bugbot fix #3) returns once the first
            // timeline snapshot has been applied, so the chained
            // `markAsRead()` marks the actual head of the timeline as
            // read instead of racing the empty initial state.
            await viewModel.start()
            await viewModel.markAsRead()
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
        .onDisappear { viewModel.stop() }
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

