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
    /// `nil` until `evaluateBotVerification()` resolves. `false` shows the
    /// banner; `true` hides it. Three-state (unknown / verified /
    /// unverified) so the banner doesn't briefly flash for verified bots
    /// during the async query — matches the §7.5 trust posture (don't
    /// pretend something is unverified before we've actually checked).
    @State private var isBotVerified: Bool? = nil
    /// Drives the per-bot SAS sheet. `Bool`-keyed because there's only
    /// ever one bot per chat — the bot's matrixID is captured from the
    /// `botMatrixID` view input at sheet-build time.
    @State private var showVerifyBotSheet = false

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
            // `isBotVerified == false` is the only branch that draws —
            // `nil` (still evaluating) and `true` (verified) both hide.
            if isBotVerified == false {
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.items) { item in
                            TimelineItemView(item: item, resolveImage: { viewModel.image(for: $0) })
                                .id(item.id)
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
                    .padding(.vertical)
                }
                .onChange(of: viewModel.items.last?.id) { _, _ in
                    // Round-3 bugbot finding #5: previously we keyed on
                    // `items.count`, which misses two real cases —
                    // (a) a `.set` diff swapping a local-echo item id for
                    // its remote-event id keeps `count` constant but
                    // should still scroll to the new tail, and
                    // (b) a remove + add in the same diff batch leaves
                    // `count` unchanged but the last-item id moves.
                    // Keying on `last?.id` catches both.
                    if let last = viewModel.items.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
            // Chain `markAsRead()` *after* the timeline observation has
            // applied its first snapshot. `start()` is now `async` and
            // returns once the first snapshot has landed (or the stream
            // ends without one), so the subsequent `markAsRead()` always
            // marks the actual head of the timeline as read instead of
            // racing the empty initial state. See `ChatViewModel.start()`
            // for the underlying signal mechanism (round-3 bugbot fix #3).
            await viewModel.start()
            await viewModel.markAsRead()
        }
        // Evaluate per-bot verification once on appear. Separate `.task`
        // so the (cheap, synchronous-once-cached) identity lookup
        // doesn't share a cancellation lifecycle with the long-lived
        // timeline observation. Throws → `false` so the banner errs on
        // the side of prompting verification (§7.5 trust posture).
        .task { await evaluateBotVerification() }
        .onDisappear { viewModel.stop() }
        .sheet(item: $sourceItem) { item in
            EventSourceSheet(item: item)
        }
        .sheet(isPresented: $showVerifyBotSheet) {
            verifyBotSheetBody
        }
    }

    /// Per-bot verification evaluation. `nil` keeps the banner hidden
    /// during the async query; resolves to `true` (hide) or `false`
    /// (show banner). Catching the error returns `false` so a flaky
    /// network doesn't accidentally promote the bot to "verified" in
    /// the UI — matches §7.5's "nothing auto-trusted" posture.
    private func evaluateBotVerification() async {
        guard let svc = verificationService, let botMatrixID else {
            isBotVerified = nil
            return
        }
        do {
            isBotVerified = try await svc.isUserVerified(matrixID: botMatrixID)
        } catch {
            isBotVerified = false
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
                Text("This device hasn't been verified")
                    .font(.callout)
                    .bold()
                Text("Messages may show a warning until you verify.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Verify") { showVerifyBotSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This device hasn't been verified. Verify.")
    }

    /// Builds the SAS sheet for verifying the bot user. Mirrors
    /// `PostLoginVerificationView`'s `.sasWithOtherDevice` construction —
    /// `requestID` is the bot's matrixID (matches the FlowStore cache
    /// key `VerificationServiceLive.startSAS` registers under for
    /// per-user verification flows). Re-evaluates the verification
    /// state on `onFinished` so a successful match auto-hides the
    /// banner without waiting for a remount.
    @ViewBuilder
    private var verifyBotSheetBody: some View {
        if let svc = verificationService, let botMatrixID {
            let stream = svc.startSAS(withUser: botMatrixID, deviceID: nil)
            SasView(
                viewModel: SasViewModel(
                    stream: stream,
                    requestID: botMatrixID,
                    confirm: { try await svc.confirmEmojiMatch(requestID: botMatrixID) },
                    cancel: { reason in try await svc.cancel(requestID: botMatrixID, reason: reason) }
                ),
                title: "Verify \(botMatrixID)",
                onFinished: {
                    showVerifyBotSheet = false
                    Task { await evaluateBotVerification() }
                }
            )
        } else {
            // Defensive: if either input is nil at sheet-present time
            // (impossible under normal flow since the banner only
            // renders when both are wired), surface a no-op message
            // rather than crashing.
            Text("Verification unavailable")
                .padding()
        }
    }
}
