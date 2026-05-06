import SwiftUI
import MatronChat
import MatronModels
import MatronVerification
import MatronViewModels
import MatronDesignSystem

/// iOS chat screen. Hosts a scrollable timeline (LazyVStack rendering each
/// `TimelineItem` via `TimelineItemView`) above a `ComposerView`. The
/// navigation toolbar shows the chat title and an info button that calls
/// `onShowBotProfile` (Phase 5+ wires this to a profile sheet).
///
/// `viewModel.start()` runs in `.task`; `viewModel.stop()` runs in
/// `.onDisappear` to release the AsyncStream's continuation. This mirrors
/// the `ChatListView` pattern from Phase 1.
///
/// Task 10 (Phase 3) adds the per-bot verification banner (spec §7.3,
/// §7.5). When `verificationService` + `botMatrixID` are wired, the view
/// queries `isUserVerified(matrixID:)` once on appear; if the bot's
/// identity is unverified, an inline banner sits above the timeline
/// offering a "Verify" tap that presents `SasView` against the bot's
/// user. Both parameters are optional so existing callers / tests keep
/// compiling — same opt-in pattern `ChatListView.verificationCenter` uses.
struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel
    /// Backing state for the "View source" sheet. `TimelineItem` is
    /// `Identifiable` (the SDK's stable `TimelineUniqueId.id`), so
    /// `.sheet(item:)` re-presents a fresh sheet whenever the user picks a
    /// different row instead of clinging to the prior one.
    @State private var sourceItem: TimelineItem?
    /// `nil` until `evaluateBotVerification()` resolves; otherwise the
    /// tri-state result from `VerificationService.isUserVerified(matrixID:)`
    /// (M2). Banner renders ONLY on `.unverified` — `.verified` hides it,
    /// `.unknown` (cold-start: identity not yet in the local crypto store)
    /// also hides it so the banner doesn't flash on every fresh chat open
    /// before sliding-sync warms up `/keys/query`. §7.5 trust posture is
    /// preserved because nothing is auto-trusted: the unknown branch will
    /// re-evaluate on the next sync tick.
    @State private var botVerification: UserVerificationResult? = nil
    /// Drives the per-bot SAS sheet via `.sheet(item:)`. B2/M5 expert-QA
    /// fix: previously this was a `Bool`-keyed `.sheet(isPresented:)`
    /// whose body rebuilt the `SasViewModel` + stream on every body
    /// re-evaluation (any unrelated `@State` change ran the closure
    /// fresh). With `.sheet(item:)` the sheet body executes exactly
    /// once per present — the new VM keeps its registered continuation
    /// across the parent's re-renders so partner-side SAS state
    /// transitions actually reach the visible sheet. The sheet still
    /// has only one possible `botMatrixID` per chat (so the wrapper's
    /// `id` is the matrixID itself); the wrapper exists to satisfy
    /// `Identifiable` and to give `.sheet(item:)` a stable identity.
    @State private var verifyBotContext: VerifyBotSheetContext?
    /// The bottom-anchored visible item id, bound to `.scrollPosition`
    /// on the timeline ScrollView. Drives both the per-room scroll
    /// memory (so reopening a chat lands where the user left off) and
    /// the floating "jump to latest" button (visible iff this isn't
    /// `items.last?.id`).
    @State private var scrolledItemID: String?
    /// Backing state for the fullscreen attachment preview. `nil`
    /// hides the sheet; setting either case presents it via
    /// `.sheet(item:)`. `.image` draws the pinch-zoom viewer; `.file`
    /// drives a small share sheet around `ShareLink(item:)` so the
    /// user can save / forward the attachment without leaving the
    /// chat.
    @State private var attachmentPreview: AttachmentPreview?

    /// Sheet payload for fullscreen attachment previews. Identifiable
    /// via a per-present UUID so two consecutive taps re-mount the
    /// sheet (and so `.sheet(item:)` doesn't conflate two separate
    /// images).
    fileprivate enum AttachmentPreview: Identifiable {
        case image(id: UUID = UUID(), Image)
        case file(id: UUID = UUID(), URL, filename: String)

        var id: UUID {
            switch self {
            case .image(let id, _): return id
            case .file(let id, _, _): return id
            }
        }
    }

    /// Identifiable wrapper for `.sheet(item:)`. Identity is the bot's
    /// matrixID — one bot per chat, so two sequential taps re-use the
    /// same identity (which is exactly what we want: the second present
    /// does NOT cancel and re-build the sheet body, but a dismiss-then-
    /// re-tap DOES because we set the optional to `nil` between).
    fileprivate struct VerifyBotSheetContext: Identifiable, Hashable {
        let id: String
    }

    let chatTitle: String
    let onShowBotProfile: () -> Void
    /// Per-bot verification service (spec §7.3). Optional so existing
    /// tests / previews that construct `ChatView` without a verification
    /// stack keep compiling. When wired, the view evaluates
    /// `isUserVerified(matrixID:)` on appear and renders the inline
    /// banner above the timeline if the bot is unverified.
    var verificationService: VerificationService? = nil
    /// The bot user's matrix ID. Required alongside `verificationService`
    /// for the per-bot banner to render — without it the view has no
    /// user to query the verification state for. Optional for the same
    /// existing-callers reason.
    var botMatrixID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Per-bot verification banner (spec §7.3, §7.5). Renders
            // above the error banner so a user who's both unverified
            // *and* hit a sliding-sync timeout sees both signals.
            // Only `.unverified` draws — `.unknown` (cold-start; identity
            // not yet loaded in the local crypto store) and `.verified`
            // both hide. §7.5 still holds because the `.unknown` arm
            // re-evaluates on the next sync tick (M2).
            if botVerification == .unverified {
                botVerificationBanner
            }
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
            if viewModel.items.isEmpty
                && viewModel.hasReceivedFirstSnapshot
                && viewModel.error == nil {
                // Settled-empty branch: the timeline has definitively
                // yielded an empty snapshot (not just "still loading"),
                // so the user sees a placeholder instead of a blank
                // scroll. Gating on `hasReceivedFirstSnapshot` avoids
                // flashing the placeholder during sliding-sync warm-up
                // — `items.isEmpty` alone collapses both "loading" and
                // "settled empty" into the same UI state.
                EmptyChatPlaceholder(botName: chatTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Render `rows` (messages interleaved with date
                    // separators) instead of `items` directly. The
                    // separator stream is computed on the view-model
                    // so iOS and Mac don't have to duplicate the
                    // calendar-day bucketing.
                    ForEach(viewModel.rows) { row in
                        switch row {
                        case .separator(let date):
                            DateSeparator(date: date)
                                .id(row.id)
                        case .message(let item):
                            TimelineItemView(
                                item: item,
                                resolveImage: { viewModel.image(for: $0) },
                                onRetry: { id in viewModel.retrySend(itemID: id) },
                                onTapImage: { img in
                                    attachmentPreview = .image(img)
                                },
                                onTapFile: { mxc, filename in
                                    Task {
                                        if let url = await viewModel.writeTempFile(
                                            mxcURL: mxc, filename: filename
                                        ) {
                                            attachmentPreview = .file(url, filename: filename)
                                        }
                                    }
                                }
                            )
                                .id(item.id)
                                // Infinite-scroll backward pagination
                                // trigger: when the topmost message
                                // mounts, request older events. We
                                // key on `viewModel.items.first?.id`
                                // (raw message list) rather than
                                // `rows.first` because the head row
                                // is now usually a separator — and
                                // the separator's onAppear shouldn't
                                // drive pagination.
                                .onAppear {
                                    if item.id == viewModel.items.first?.id {
                                        Task { await viewModel.paginateBackward() }
                                    }
                                }
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
            // `.scrollPosition(id:anchor: .bottom)` binds `scrolledItemID`
            // to the row at the bottom of the viewport. Setting it to
            // `items.last?.id` jumps to the live tail; reading it tells
            // us which row the user is currently looking at, which is
            // both what we save for the per-room memory and what we
            // compare against the tail to decide whether to show the
            // jump-to-bottom button. `.scrollTargetLayout()` on the
            // `LazyVStack` is required for the binding to resolve row
            // ids.
            .scrollPosition(id: $scrolledItemID, anchor: .bottom)
            // Auto-follow the live tail only if the user was already at
            // the previous tail. If they've scrolled up to read history,
            // a new bot message shouldn't yank them back to the bottom —
            // that's what the floating jump button is for.
            .onChange(of: viewModel.items.last?.id) { oldID, newID in
                guard let newID else { return }
                let wasAtTail = (scrolledItemID == oldID) || (scrolledItemID == nil)
                if wasAtTail {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        scrolledItemID = newID
                    }
                }
            }
            // Backward-pagination trigger driven by the scroll position
            // binding. The earlier `.onAppear` on the topmost row only
            // fires once per row mount and proved unreliable under
            // `.scrollPosition(id:)` — LazyVStack pre-mounts a buffer
            // of off-screen rows, so the first row's appear had often
            // already fired by the time the user actually scrolled to
            // it. `scrolledItemID` updates every time the visible row
            // at the bottom of the viewport changes, so this fires
            // continuously as the user scrolls. Paginate when the
            // visible bottom falls within the first 5 message ids —
            // i.e. user is within ~5 rows of the head, which is the
            // right time to fetch the next page.
            .onChange(of: scrolledItemID) { _, newID in
                guard let newID,
                      viewModel.items.prefix(5).contains(where: { $0.id == newID })
                else { return }
                Task { await viewModel.paginateBackward() }
            }
            // Floating jump-to-latest. Visible only when the user has
            // scrolled away from the tail.
            .overlay(alignment: .bottomTrailing) {
                if let last = viewModel.items.last?.id, scrolledItemID != last {
                    JumpToBottomButton {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrolledItemID = last
                        }
                        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                    }
                }
            }
            }
            ComposerView(viewModel: composerVM)
        }
        .navigationTitle(chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onShowBotProfile() } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .task {
            // Restore the per-room scroll position BEFORE start() so
            // the first snapshot's `.onChange` doesn't auto-pin to the
            // tail (its guard checks `scrolledItemID == oldID`, which
            // is true for the unrestored nil case but false once we've
            // set a saved id here). If no memory exists, `scrolledItemID`
            // stays nil and the chat opens at the tail as usual.
            scrolledItemID = ChatScrollPositionMemory.retrieve(roomID: viewModel.roomID)
            // Chain `markAsRead()` *after* the timeline observation has
            // applied its first snapshot. `start()` is now `async` and
            // returns once the first snapshot has landed (or the stream
            // ends without one), so the subsequent `markAsRead()` always
            // marks the actual head of the timeline as read instead of
            // racing the empty initial state. See `ChatViewModel.start()`
            // for the underlying signal mechanism (round-3 bugbot fix #3).
            await viewModel.start()
            await viewModel.markAsRead()
            // Explicit paginate-on-open. Sliding sync seeds the timeline
            // with just the latest event, so without this the user sees
            // a single message until they scroll up. The topmost-row
            // `.onAppear` trigger handles SUBSEQUENT history loads as
            // they scroll; this seeds the first page so there's
            // something to scroll into.
            await viewModel.paginateBackward()
        }
        // Evaluate per-bot verification on appear AND each time the
        // timeline gains its first items — that's the cheapest signal
        // we have for "sliding-sync delivered enough state that the
        // local crypto store probably has the user identity now". Keying
        // on `items.isEmpty` (rather than `.count`) re-fires exactly
        // once when the empty initial snapshot transitions to a
        // populated one, so M2's `.unknown` cold-start result gets a
        // chance to resolve to `.verified` / `.unverified` without
        // requiring the user to leave and re-open the chat. Separate
        // `.task` so the (cheap) identity lookup doesn't share a
        // cancellation lifecycle with the long-lived timeline
        // observation. Throws → `.unknown` (was `false` under the prior
        // Bool shape) so the banner errs hidden on transient errors
        // and re-checks on the next tick (§7.5 trust posture).
        .task(id: viewModel.items.isEmpty) { await evaluateBotVerification() }
        .onDisappear {
            // Capture the user's scroll position so the next open of
            // this room lands where they left off. Drop the entry on
            // tail (no point storing "user was at the live tail" — the
            // default behaviour already opens there).
            if let id = scrolledItemID, id != viewModel.items.last?.id {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            }
            viewModel.stop()
        }
        .sheet(item: $sourceItem) { item in
            EventSourceSheet(item: item)
        }
        .sheet(item: $verifyBotContext) { context in
            verifyBotSheetBody(for: context.id)
        }
        // Fullscreen attachment preview. Presented from a tap on
        // either an `AttachmentImage` or `AttachmentFile` row;
        // payload selects between the pinch-zoom image viewer and
        // the share-sheet wrapper for files. Dismissed by setting
        // `attachmentPreview = nil` (swipe-down on iOS, "Done"
        // button, or successful share).
        .sheet(item: $attachmentPreview) { preview in
            switch preview {
            case .image(_, let img):
                AttachmentFullscreenViewer(
                    image: img,
                    onDismiss: { attachmentPreview = nil }
                )
            case .file(_, let url, let filename):
                fileShareSheet(url: url, filename: filename)
            }
        }
    }

    /// iOS file-share sheet body. Presents the filename + a system
    /// `ShareLink` so the user can save / forward the attachment
    /// without leaving the chat. Lifted into its own builder so the
    /// `.sheet(item:)` switch above stays tight.
    @ViewBuilder
    private func fileShareSheet(url: URL, filename: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 32)
            Text(filename)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            Button("Done") { attachmentPreview = nil }
                .padding(.top, 4)
            Spacer()
        }
        .padding()
        .presentationDetents([.medium])
    }

    /// Per-bot verification evaluation. `nil` keeps the banner hidden
    /// during the async query; resolves to one of:
    ///   * `.verified`   — banner hides.
    ///   * `.unverified` — banner renders.
    ///   * `.unknown`    — banner hides (cold-start path); next sync
    ///                     tick re-runs this evaluation.
    /// Catching a thrown error resolves to `.unknown` rather than
    /// `.unverified` so a flaky network doesn't promote the bot to a
    /// concrete trust state — the next evaluation tick can re-check.
    /// (M2: was previously `Bool?` collapsing `.unknown` into `.unverified`,
    /// causing the banner to flash on every cold-start chat open.)
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

    /// Inline banner above the timeline. Mirrors the shape /
    /// affordances of `VerificationBanner` (the chat-list incoming-
    /// request banner) so the UX is consistent across surfaces. No
    /// dismiss "X" — the banner reflects an actual trust state, not a
    /// transient request, so dismissing without verifying would just
    /// re-appear on the next mount.
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
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This bot's identity hasn't been verified. Verify.")
    }

    /// Builds the SAS sheet for verifying the bot user. The SasViewModel
    /// + stream are owned by the inner `SasSheetWrapper` view's `@State`
    /// so they're constructed exactly once per present (B2/M5 expert-QA
    /// fix). Mirrors the FlowStore cache-key choice in
    /// `VerificationServiceLive.startSAS` for per-user verification
    /// flows: `requestID` is the bot's matrixID. Re-evaluates the
    /// verification state on `onFinished` so a successful match
    /// auto-hides the banner without waiting for a remount.
    @ViewBuilder
    private func verifyBotSheetBody(for botMatrixID: String) -> some View {
        if let svc = verificationService {
            SasSheetWrapper(
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
                    // Same dismissal as onFinished — clear the context;
                    // re-evaluating bot verification is harmless on cancel
                    // (state hasn't changed) and keeps the call sites
                    // symmetric.
                    verifyBotContext = nil
                    Task { await evaluateBotVerification() }
                }
            )
        } else {
            // Defensive: if `verificationService` is nil at sheet-
            // present time (impossible under normal flow since the
            // banner only renders when both inputs are wired), surface
            // a no-op message rather than crashing.
            Text("Verification unavailable")
                .padding()
        }
    }
}

