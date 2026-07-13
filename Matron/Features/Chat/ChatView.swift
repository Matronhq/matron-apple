import SwiftUI
import UIKit
import os
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Un-gated (notice-level) breadcrumbs for rare view-layer anomalies —
/// same forensic role as the sync layer's lifecycle warnings.
private let chatViewLogger = Logger(subsystem: "chat.matron", category: "ios-chat-view")

/// iOS chat screen. Hosts a scrollable timeline (LazyVStack rendering each
/// `TimelineItem` via `TimelineItemView`) above a `ComposerView`. The
/// navigation toolbar shows the chat title and an info button that calls
/// `onShowBotProfile`.
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
    /// App lifecycle — drives `viewModel.handleForeground()` so a
    /// background→foreground timeline re-sync doesn't flash the empty
    /// placeholder. `wasBackgrounded` filters out `.inactive`↔`.active`
    /// blips (notification centre, etc.) so only a real resume triggers it.
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    /// Backing state for the "View source" sheet. `TimelineItem` is
    /// `Identifiable` (the SDK's stable `TimelineUniqueId.id`), so
    /// `.sheet(item:)` re-presents a fresh sheet whenever the user picks a
    /// different row instead of clinging to the prior one.
    @State private var sourceItem: TimelineItem?
    /// The bottom-anchored visible item id, bound to `.scrollPosition`
    /// on the timeline ScrollView. Drives both the per-room scroll
    /// memory (so reopening a chat lands where the user left off) and
    /// the floating "jump to latest" button (visible iff this isn't
    /// `items.last?.id`).
    @State private var scrolledItemID: String?
    /// Generation token from the observation THIS view instance started;
    /// `onDisappear` only stops the VM if it still matches (see there).
    @State private var startedGeneration = 0
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

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
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
            ScrollView {
                // `.equatable()` + the reference-identity `==` on
                // `TimelineListContent` is the scroll-perf fix: the
                // `.scrollPosition(id:)` binding below writes
                // `scrolledItemID` every time a row crosses the bottom
                // anchor, and each write re-evaluates this whole body.
                // Without the equatable fence, that re-evaluation
                // cascaded into every mounted row (observation-tracking
                // teardown/reinstall, row body re-eval, contextMenu
                // rebuild — ~60% of main-thread time in a scroll
                // profile). With it, scroll churn stops at the fence;
                // actual timeline changes still propagate because
                // `@Observable` tracking installed by the child's body
                // (reading `viewModel.rows`) invalidates the child
                // directly, bypassing the `==` check.
                ScrollViewReader { proxy in
                    TimelineListContent(
                        viewModel: viewModel,
                        onPreview: { attachmentPreview = $0 },
                        onShowSource: { sourceItem = $0 }
                    )
                    .equatable()
                    // Keyboard re-pin. Default keyboard avoidance shrinks
                    // the viewport but never re-resolves the
                    // `.scrollPosition(id:)` binding below (assigning the
                    // same id is a no-op), so the tail row ends up half
                    // behind the keyboard. If the user was at the tail
                    // when the keyboard summons (same predicate as the
                    // auto-follow), scroll it back into view; scrolled-up
                    // readers keep their position. The 50ms defer lets the
                    // safe-area resize land before the anchor resolves —
                    // same empirically-derived lag as the auto-follow's.
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillShowNotification)) { _ in
                        guard let last = viewModel.lastRenderableItemID,
                              scrolledItemID == last || scrolledItemID == nil else { return }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                    // Persist cross-device ask-user answers the moment a
                    // snapshot shows them, so a resolved inline card stays
                    // resolved even if a later transient snapshot drops the
                    // answer event (bugbot "Cross-device answers not
                    // persisted").
                    .onChange(of: viewModel.items) { _, _ in
                        viewModel.persistVisibleAnswers()
                        // Dead-anchor guard: if the row the scroll position
                        // is pinned to vanished from this snapshot, the
                        // viewport lands on blank space. Routine, not rare:
                        // every send pins the anchor to the `echo:` row
                        // (retired on delivery), and every bot turn pins it
                        // to the trailing `activity` indicator row (removed
                        // on completion). Membership checks against
                        // `rowAnchorIDs` — the actual scroll-position
                        // namespace, not `TimelineRow.id`'s `msg:` form
                        // (bugbot "Scroll anchor ID mismatch").
                        //
                        // The binding write alone is NOT enough: it lands
                        // inside the same transaction that removed the row,
                        // and the ScrollView's own post-layout write-back
                        // clobbers it — the guard fired in the 2026-07-13
                        // device trace yet the viewport still blanked. The
                        // proxy scroll on the next main-actor tick is the
                        // part that actually restores the viewport; the
                        // binding write just keeps state consistent for
                        // anything that reads it this frame.
                        if let anchor = scrolledItemID, !viewModel.rowAnchorIDs.contains(anchor) {
                            chatViewLogger.notice("scroll anchor \(anchor, privacy: .public) left the row set — re-anchoring to tail")
                            guard let tail = viewModel.lastRenderableItemID else {
                                scrolledItemID = nil
                                return
                            }
                            scrolledItemID = tail
                            Task { @MainActor in
                                proxy.scrollTo(tail, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            // Warm-up state: no rows yet, but not settled-empty either
            // (that's the branch above). This window used to render as a
            // fully blank message area while the first snapshot / history
            // fetch was in flight; the indicator's own appearance delay
            // keeps cache-warm opens spinner-free.
            .overlay {
                if viewModel.rows.isEmpty {
                    TimelineLoadingIndicator()
                }
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
            .onChange(of: viewModel.lastRenderableItemID) { oldID, newID in
                guard let newID else { return }
                let wasAtTail = (scrolledItemID == oldID) || (scrolledItemID == nil)
                if wasAtTail {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        // Re-resolve at fire time: `newID` may have been
                        // retired during the sleep (send echo replaced by
                        // the delivered row) — assigning it raw plants a
                        // dead anchor the dead-anchor guard below can't
                        // see. See `ChatViewModel.autoFollowTarget`.
                        scrolledItemID = viewModel.autoFollowTarget(for: newID)
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
            .onChange(of: scrolledItemID) { oldID, newID in
                // Diag-gated anchor-transition trail: with DEBUG diag on,
                // the persisted log shows every anchor move — including a
                // corrective write being clobbered back to nil/another row
                // by the ScrollView's post-layout write-back, which is
                // otherwise invisible in a trace.
                chatViewLogger.diag("scroll anchor moved: \(oldID ?? "nil") → \(newID ?? "nil")")
                guard let newID else { return }
                // `topRowIDs` is memoised on the view-model (recomputed
                // once per snapshot) because this fires on every scroll
                // tick — rebuilding the Set per tick was measurable
                // scroll overhead. Mixed namespace (message ids +
                // "sep:<epoch>" separators) is handled there.
                if viewModel.topRowIDs.contains(newID) {
                    Task { await viewModel.paginateBackward() }
                }
            }
            // "Loading earlier messages…" pill while a backward
            // paginate is in flight. Floats over the topmost content
            // (overlay rather than LazyVStack header) so its
            // appearance doesn't push the user's apparent reading
            // position around.
            //
            // `MinDisplayDuration` holds the visible flag `true` for
            // at least 500ms once shown — without it, a paginate
            // that completes from local cache (~50-200ms) finishes
            // before the 180ms fade-in animation, so the indicator
            // would either flash imperceptibly or get swallowed by
            // the fade-out entirely. Long paginates still show
            // throughout because the derived flag tracks `isActive`
            // immediately on the rising edge.
            .overlay(alignment: .top) {
                MinDisplayDuration(while: viewModel.isPaginatingBackward) { visible in
                    if visible {
                        PaginatingHeader()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: viewModel.isPaginatingBackward)
            }
            // Floating jump-to-latest. Visible only when the user has
            // scrolled away from the tail.
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
            ComposerView(viewModel: composerVM)
        }
        // matron-web's cream timeline gradient sits behind the whole chat
        // column — bubbles (white / cyan) and the composer material all
        // render over the same warm ground.
        .background(MatronTimelineBackground())
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
            // Record the generation BEFORE awaiting: start() bumps it
            // synchronously at entry, but it doesn't RETURN until the
            // first snapshot lands — if this view disappears mid-await, a
            // post-await assignment never runs and onDisappear's guarded
            // stop no-ops against generation 0, leaking the observation
            // (bugbot "Observation leak on fast exit"). This .task is the
            // only starter between here and the call, so current+1 is
            // exactly the generation start() will use.
            startedGeneration = viewModel.observationGeneration + 1
            await viewModel.start()
            // Explicit paginate-on-open BEFORE markAsRead. The store seeds
            // the timeline with whatever's mirrored locally (possibly
            // nothing, e.g. right after a snapshot_required wipe), so this
            // fetches the first page over HTTP; the topmost-row `.onAppear`
            // trigger handles SUBSEQUENT history loads as they scroll.
            // Ordered ahead of `markAsRead()` because that rides the live
            // socket — a half-dead socket can hang the send for its whole
            // timeout, and history loading must not wait on it.
            await viewModel.paginateBackward()
            await viewModel.markAsRead()
        }
        .onDisappear {
            // Capture the user's scroll position so the next open of
            // this room lands where they left off. Drop the entry on
            // tail (no point storing "user was at the live tail" — the
            // default behaviour already opens there).
            if let id = scrolledItemID, id != viewModel.lastRenderableItemID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            }
            // Generation-guarded: the VM is cached per room (ChatVMCache in
            // ChatListView), and on a same-room remount SwiftUI can run the
            // NEW view's `.task`/start() before the OLD view's onDisappear —
            // an unconditional stop() would kill the successor's stream.
            viewModel.stop(ifGeneration: startedGeneration)
        }
        .sheet(item: $sourceItem) { item in
            EventSourceSheet(item: item)
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasBackgrounded = true
            } else if newPhase == .active, wasBackgrounded {
                wasBackgrounded = false
                viewModel.handleForeground()
            }
        }
        // (The items observer — ask-user answer persistence + the
        // dead-anchor guard — lives inside the ScrollViewReader above:
        // the guard's corrective scroll needs the proxy.)
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

}

/// The timeline's `LazyVStack` + `ForEach`, fenced off behind
/// `Equatable` so the parent's scroll-position `@State` churn can't
/// re-evaluate every mounted row (see the call site in `ChatView.body`).
/// `==` compares only the view-model reference: the row data itself is
/// delivered through `@Observable` tracking, which invalidates this view
/// directly when `viewModel.rows` (or anything else its body reads)
/// changes — the equatable check only gates parent-driven invalidation.
private struct TimelineListContent: View, Equatable {
    let viewModel: ChatViewModel
    let onPreview: (ChatView.AttachmentPreview) -> Void
    let onShowSource: (TimelineItem) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
    }

    var body: some View {
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
                            onPreview(.image(img))
                        },
                        onTapFile: { mxc, filename in
                            Task {
                                if let url = await viewModel.writeTempFile(
                                    mxcURL: mxc, filename: filename
                                ) {
                                    onPreview(.file(url, filename: filename))
                                }
                            }
                        },
                        askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                        isPromptAnswered: { viewModel.isPromptAnswered($0) },
                        answerSummary: { viewModel.answerSummary(forPrompt: $0) }
                    )
                        .id(item.id)
                        // Infinite-scroll backward pagination
                        // trigger. Compares against
                        // `firstRenderableItemID` (the first
                        // non-`.stateChange` item) rather than
                        // `items.first?.id` — Matrix room
                        // timelines virtually always start
                        // with `.stateChange` rows (room
                        // create / encryption setup) that the
                        // view filters out, so the raw
                        // `items.first` comparison never
                        // matched any rendered row and
                        // scroll-up paginate silently never
                        // fired. See
                        // `ChatViewModel.firstRenderableItemID`
                        // for the full rationale.
                        .onAppear {
                            if item.id == viewModel.firstRenderableItemID {
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
                                onShowSource(item)
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
}

