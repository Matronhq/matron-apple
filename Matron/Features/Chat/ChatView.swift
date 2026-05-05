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
        .onDisappear { viewModel.stop() }
        .sheet(item: $sourceItem) { item in
            EventSourceSheet(item: item)
        }
        .sheet(item: $verifyBotContext) { context in
            verifyBotSheetBody(for: context.id)
        }
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
    /// + stream are owned by the inner `VerifyBotSheet` view's `@State`
    /// so they're constructed exactly once per present (B2/M5 expert-QA
    /// fix). Mirrors the FlowStore cache-key choice in
    /// `VerificationServiceLive.startSAS` for per-user verification
    /// flows: `requestID` is the bot's matrixID. Re-evaluates the
    /// verification state on `onFinished` so a successful match
    /// auto-hides the banner without waiting for a remount.
    @ViewBuilder
    private func verifyBotSheetBody(for botMatrixID: String) -> some View {
        if let svc = verificationService {
            VerifyBotSheet(
                service: svc,
                botMatrixID: botMatrixID,
                onFinished: {
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

/// Per-present SAS sheet body for the per-bot verification flow.
///
/// **Wave 5 bugbot #2.** Earlier waves built the `SasViewModel` + opened
/// the `service.startSAS(...)` stream in `init` and seeded it via
/// `_viewModel = State(initialValue: …)`. SwiftUI does keep the
/// `@State`-stored VM stable across re-inits at the same view-identity,
/// BUT the right-hand side of `_viewModel = State(initialValue: …)` still
/// EVALUATES on every `init` — so `service.startSAS(...)` fired on every
/// parent body re-render. Each call hits `FlowStore.setContinuation`
/// (Wave 2 / M3), which drains the prior continuation with
/// `.cancelled("Replaced by new flow")`. The `@State`-preserved VM is
/// observing a now-terminated stream and the user sees an unexpected
/// cancellation any time the parent re-renders. That effectively unwound
/// Wave 2's hoisting fix when combined with M3.
///
/// New shape: VM is `@State private var viewModel: SasViewModel?` (nil
/// until the side-effect runs), and `service.startSAS(...)` is invoked
/// from `.task(id: botMatrixID)` — which SwiftUI guarantees to fire
/// exactly once per identity value, NOT on every body re-eval. The
/// `guard viewModel == nil` is belt-and-suspenders against SwiftUI
/// invoking the id-keyed task once on cold-init AND once on first
/// body settle (rare in practice; cheap to defend against).
private struct VerifyBotSheet: View {
    let service: VerificationService
    let botMatrixID: String
    let onFinished: () -> Void

    @State private var viewModel: SasViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                SasView(
                    viewModel: vm,
                    title: "Verify \(botMatrixID)",
                    onFinished: onFinished
                )
            } else {
                ProgressView("Starting verification…")
            }
        }
        .task(id: botMatrixID) {
            guard viewModel == nil else { return }
            let stream = service.startSAS(withUser: botMatrixID, deviceID: nil)
            viewModel = SasViewModel(
                stream: stream,
                requestID: botMatrixID,
                confirm: { try await service.confirmEmojiMatch(requestID: botMatrixID) },
                cancel: { reason in try await service.cancel(requestID: botMatrixID, reason: reason) }
            )
        }
    }
}
