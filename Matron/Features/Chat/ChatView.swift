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
/// navigation toolbar shows the chat title and an info button that
/// presents a `SessionStatusSheet` (context gauge + usage bars).
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
    @State private var wasBackgrounded = false
    /// Backing state for the "View source" sheet. `TimelineItem` is
    /// `Identifiable` (the SDK's stable `TimelineUniqueId.id`), so
    /// `.sheet(item:)` re-presents a fresh sheet whenever the user picks a
    /// different row instead of clinging to the prior one.
    @State private var sourceItem: TimelineItem?
    /// Sticky "following the live tail" mode. `true` from open-at-tail
    /// until the user *deliberately drags away* (gesture phases via
    /// `onUserScrollGesture`); re-engaged when scrolling settles near the
    /// bottom or via the jump button. While `true`, the scroll engine
    /// itself keeps the viewport pinned through every layout change —
    /// see `sizeChangeAnchor`. There is deliberately NO row-id anchor
    /// state here: nine rounds of the 2026-07 blank-chat bug traced back
    /// to the `.scrollPosition(id:)` binding this view used to carry —
    /// the ScrollView clobbers corrective writes with its own post-layout
    /// write-back (device trace: jump button's write reverted within
    /// 1-6ms, five presses in a row) and keeps dead rows' positions
    /// during layout changes (blank viewport when an `echo:`/streaming
    /// row retires). Position is now imperative-only: `defaultScrollAnchor`
    /// roles + `proxy.scrollTo`.
    @State private var isFollowingTail = true
    /// Viewport-derived "the bottom edge of content is on screen" —
    /// updated by `onScrollGeometryChange`, consumed by the gesture
    /// settle handler to re-arm follow-tail. Geometry, not row identity:
    /// comparing an anchor id against the tail id is exactly the
    /// drift-fragile check the old design died on.
    @State private var isNearBottom = true
    /// Reference box for the bottommost visible row id (per-room scroll
    /// memory). Deliberately a class box, not value `@State`: visibility
    /// updates arrive on every row crossing while scrolling, and a
    /// value-typed write per tick would re-evaluate this whole body.
    /// Only `onDisappear` reads it.
    @State private var visibleRows = VisibleRowsBox()
    /// Scroll-memory id waiting for the first row snapshot of a fresh
    /// view model — consumed by the rows-populated observer, which
    /// resolves it via `proxy.scrollTo`.
    @State private var pendingRestoreID: String?
    /// Debounced follow-tail self-heal scheduled when the bottom edge
    /// leaves the screen with no user gesture — see the schedule site
    /// in the geometry action.
    @State private var followHealTask: Task<Void, Never>?

    /// UIKit reach-through for the jump button's fling kill — see
    /// `NativeScrollViewBox`. Nothing on the SwiftUI surface can stop an
    /// in-flight deceleration: `proxy.scrollTo` is overridden by the
    /// deceleration's animator for its whole 1–2s life (08:09 trace) and
    /// `.scrollDisabled` only blocks touches while the animation runs to
    /// completion (08:2x on-device: jump "waited for the scroll to
    /// finish").
    @State private var nativeScroll = NativeScrollViewBox()

    final class VisibleRowsBox {
        var bottomID: String?
        /// Every visible scroll-target id, top-to-bottom — the history
        /// pin (`revealOlderHistory`) reads the topmost through
        /// `ChatViewModel.historyPinTarget`. Same non-invalidating
        /// contract as `bottomID`.
        var orderedIDs: [String] = []
        /// Bumped on every user-gesture begin; a history-reveal pin
        /// captures it and drops its delayed re-asserts when the user
        /// has gestured since (never fight an active reader).
        var gestureCount = 0
        /// Latest raw scroll geometry, refreshed by the
        /// `onScrollGeometryChange` transform — forensic context for
        /// breadcrumbs (a bare "near-bottom → false" says the viewport
        /// moved; the numbers say where it went and how far).
        var geoDescription = ""
    }

    /// Bottom-edge proximity threshold (pt) for `isNearBottom` — a
    /// generous bubble-and-a-half; near enough that the user reads it as
    /// "at the bottom". 60 proved too tight: engine appends repeatedly
    /// stranded the viewport 61–63pt short (2026-07-14 06:54 trace), one
    /// point past the heal's blind side.
    private static let nearBottomThresholdPt: CGFloat = 100
    /// Top-edge proximity threshold (pt) that triggers backward
    /// pagination — a couple of screens before the user actually hits
    /// the head, so history is usually there by the time they arrive.
    private static let nearTopThresholdPt: CGFloat = 600

    /// proxy.scrollTo id of the inline activity indicator — a sibling of
    /// the scroll-target layout, so it never enters the anchor namespace.
    private static let activityFooterID = "activity-footer"

    /// Where "scroll to the bottom" should actually land: the inline
    /// activity indicator when the bot is working (it sits below the last
    /// message row), otherwise the last renderable row.
    private var bottomScrollTargetID: String? {
        viewModel.activityLabel != nil ? Self.activityFooterID : viewModel.lastRenderableItemID
    }

    /// Routes both history-reveal triggers: extends the window, then
    /// pins the viewport to the pre-extend topmost visible row
    /// (non-animated `scrollTo`, anchor `.top`) once the prepend
    /// applies. The declarative `.sizeChanges` bottom anchor only
    /// covers the prepend while `isExtendingWindow` is up (150ms) — at
    /// a few hundred rows the eager stack's layout pass outlives it,
    /// the viewport parked at the NEW head, and the reveal trigger
    /// re-fired in a loop (2026-07-15 Mac trace: 240→1920 rows in 14s,
    /// contentH 180Kpt, escaped only via the jump button). The pin is
    /// re-asserted twice because the prepend's layout can land after
    /// the first `scrollTo`; re-asserts drop if the user gestures or
    /// returns to the tail meanwhile (never fight an active reader).
    private func revealOlderHistory(via proxy: ScrollViewProxy) {
        let pin = ChatViewModel.historyPinTarget(
            visibleIDs: visibleRows.orderedIDs,
            preExtendRows: viewModel.windowedRows
        )
        let sizeBefore = viewModel.visibleWindowSize
        let gesture = visibleRows.gestureCount
        Task { @MainActor in
            await viewModel.extendHistoryWindow()
            guard viewModel.visibleWindowSize > sizeBefore, let pin else { return }
            guard !isFollowingTail else { return }
            chatViewLogger.breadcrumb("history reveal pin → \(pin) (window \(sizeBefore)→\(viewModel.visibleWindowSize))")
            proxy.scrollTo(pin, anchor: .top)
            for delay in [UInt64(250_000_000), UInt64(800_000_000)] {
                try? await Task.sleep(nanoseconds: delay)
                guard !isFollowingTail, visibleRows.gestureCount == gesture else { return }
                proxy.scrollTo(pin, anchor: .top)
            }
        }
    }

    /// Widen-then-scroll for a remembered scroll position. The widen
    /// mounts rows on the NEXT layout pass, and `proxy.scrollTo` only
    /// resolves ids already in the rendered tree — a same-tick scroll
    /// after a widen silently no-ops and the chat opens at the tail
    /// (Bugbot, PR #18). Scroll immediately (covers the common case of
    /// a target inside the default window, no visible hop), then
    /// re-assert once, non-animated, after the widened rows have
    /// mounted. The re-assert yields if follow-tail re-armed meanwhile
    /// (an own send in that window wins).
    private func restoreScroll(to restored: String, via proxy: ScrollViewProxy) {
        viewModel.ensureWindowContains(restored)
        proxy.scrollTo(restored, anchor: .bottom)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !isFollowingTail else { return }
            proxy.scrollTo(restored, anchor: .bottom)
        }
    }

    /// The `.sizeChanges` anchor role — this is the whole follow-tail
    /// mechanism. `.bottom` while following makes the scroll ENGINE keep
    /// the bottom edge pinned through streaming growth, echo→server row
    /// swaps, the inline indicator mounting/unmounting, and keyboard
    /// resizes — the exact set of events the old view fought with
    /// corrective `scrollTo`s (which computed targets from in-motion
    /// layout and overshot). While reading history it returns `nil`
    /// (preserve offset from top — appended content doesn't move the
    /// viewport), EXCEPT during backward pagination: prepended history
    /// grows content above the viewport, and only a bottom-relative
    /// offset keeps the same rows on screen. `isPaginatingBackward`
    /// stays `true` until the paginated snapshot has been applied (see
    /// `ChatViewModel.paginateBackward`), so the flag reliably covers
    /// the prepend's layout pass.
    private var sizeChangeAnchor: UnitPoint? {
        if isFollowingTail { return .bottom }
        return (viewModel.isPaginatingBackward || viewModel.isExtendingWindow) ? .bottom : nil
    }

    /// Edge proximity snapshot derived from scroll geometry. Equatable so
    /// `onScrollGeometryChange` only fires its action on actual edge
    /// transitions, not every scrolled point.
    private struct ScrollEdgeState: Equatable {
        var nearTop: Bool
        var nearBottom: Bool
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
            ScrollViewReader { proxy in
            ScrollView {
                // `.equatable()` + the reference-identity `==` on
                // `TimelineListContent` is the scroll-perf fence: parent
                // `@State` churn (follow-mode / edge-proximity flips)
                // re-evaluates this body, and without the fence that
                // re-evaluation cascaded into every mounted row
                // (observation-tracking teardown/reinstall, row body
                // re-eval, contextMenu rebuild — ~60% of main-thread
                // time in a scroll profile). Actual timeline changes
                // still propagate because `@Observable` tracking
                // installed by the child's body (reading
                // `viewModel.rows`) invalidates the child directly,
                // bypassing the `==` check.
                VStack(spacing: 0) {
                    TimelineListContent(
                        viewModel: viewModel,
                        stripViewModel: stripViewModel,
                        onOpenSubChat: nil,
                        onPreview: { attachmentPreview = $0 },
                        onShowSource: { sourceItem = $0 }
                    )
                    .equatable()
                    // The bot's typing / tool-use indicator, inline
                    // under the last bubble (WhatsApp-style) — but as
                    // a SIBLING of the scroll-target layout, not a row
                    // inside it: it scrolls with the content yet never
                    // enters the scroll-target namespace (it was the
                    // top dead-anchor source when it was a timeline
                    // row, 2026-07-13 traces). The explicit `.id` is
                    // for proxy.scrollTo only. Its mount/unmount is a
                    // content-size change, so the `.sizeChanges` bottom
                    // anchor reveals/heals it natively while pinned.
                    if let activityLabel = viewModel.activityLabel {
                        ActivityIndicatorRow(label: activityLabel)
                            .id(Self.activityFooterID)
                    }
                }
                // Persist cross-device ask-user answers the moment a
                // snapshot shows them, so a resolved inline card stays
                // resolved even if a later transient snapshot drops the
                // answer event (bugbot "Cross-device answers not
                // persisted").
                .onChange(of: viewModel.items) { _, _ in
                    viewModel.persistVisibleAnswers()
                }
                // Grabs the backing UIScrollView (must sit INSIDE the
                // ScrollView content — the capture walks up from here).
                // The overflow lock keeps a too-wide row from letting the
                // whole timeline wiggle horizontally — see
                // `HorizontalOverflowLock` (it also logs the offender).
                .captureNativeScrollView(into: nativeScroll,
                                         lockingHorizontalOverflow: true)
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
            // Every open lands at the bottom — including reopens against
            // a cached view model, whose rows are already populated at
            // first layout. (The retired `.scrollPosition` design
            // positioned those opens NOWHERE: the binding started nil
            // and no items change fired, so the chat sat at the top —
            // 2026-07-14 device trace.)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // A conversation shorter than the viewport hugs the
            // composer, chat-standard.
            .defaultScrollAnchor(.bottom, for: .alignment)
            // THE follow-tail mechanism — see `sizeChangeAnchor`: while
            // following, the scroll engine itself keeps the bottom edge
            // pinned through every layout change.
            .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollEdgeState.self) { geo in
                // Side write into the box (cheap, non-invalidating):
                // keeps the latest raw numbers available to every
                // breadcrumb site without waking the render loop.
                visibleRows.geoDescription = "visY=\(Int(geo.visibleRect.minY))–\(Int(geo.visibleRect.maxY)) contentH=\(Int(geo.contentSize.height)) containerH=\(Int(geo.containerSize.height))"
                return ScrollEdgeState(
                    nearTop: geo.visibleRect.minY < Self.nearTopThresholdPt,
                    nearBottom: geo.visibleRect.maxY
                        >= geo.contentSize.height - Self.nearBottomThresholdPt
                )
            } action: { _, edges in
                if isNearBottom != edges.nearBottom {
                    isNearBottom = edges.nearBottom
                    chatViewLogger.diag("near-bottom → \(edges.nearBottom) (\(visibleRows.geoDescription))")
                    // Follow-tail self-heal. While following, the bottom
                    // edge leaving the screen with NO user gesture is by
                    // definition a layout artifact: LazyVStack's content-
                    // height ESTIMATE swings wildly when the container
                    // resizes (2026-07-14 06:51 trace: keyboard up →
                    // contentH 115K→497K→286K→90K within seconds,
                    // viewport stranded 2,000pt above the tail — read as
                    // "everything disappeared"). No anchor role can hold
                    // a viewport through a collapsing coordinate space,
                    // so re-pin after the churn settles. Geometry-keyed
                    // (unlike the retired round-6 anchor-id re-assert,
                    // estimate churn can't disarm it), non-animated
                    // (nothing to race), debounced 300ms (the trace
                    // shows millisecond flicker pairs during
                    // re-estimation that must not each fire a scroll).
                    // A real user drag exits follow mode first, so
                    // reading history is never yanked.
                    if !edges.nearBottom, isFollowingTail {
                        followHealTask?.cancel()
                        followHealTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled, isFollowingTail, !isNearBottom,
                                  let target = bottomScrollTargetID else { return }
                            chatViewLogger.breadcrumb("follow-tail heal → \(target) (\(visibleRows.geoDescription))")
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    } else {
                        followHealTask?.cancel()
                        followHealTask = nil
                    }
                }
                // History-reveal trigger. Viewport geometry, not row
                // ids: the retired design keyed this off the
                // scroll-position binding's per-tick anchor value.
                // Edge-transition semantics (Equatable state) fire this
                // once per approach; the revealed rows push
                // `visibleRect.minY` back past the threshold, re-arming
                // it. `!isFollowingTail` gates out layout churn: while
                // pinned to the tail the top edge can only "approach"
                // through transient geometry (short chats, mid-collapse
                // estimates) — only a user who has actually dragged away
                // from the tail can be reading toward the top.
                if edges.nearTop, !isFollowingTail {
                    revealOlderHistory(via: proxy)
                }
            }
            // Per-room scroll memory feed: the bottommost visible row
            // id, captured into a non-invalidating box (`VisibleRowsBox`
            // — visibility churns on every row crossing, and value-typed
            // state here would re-evaluate the body per scroll tick).
            .onScrollTargetVisibilityChange(idType: String.self) { visibleIDs in
                visibleRows.bottomID = visibleIDs.last
                visibleRows.orderedIDs = visibleIDs
                // History-reveal trigger #2: the window's FIRST row is
                // actually on screen. Visibility keeps firing while the
                // user sits at the top, which the near-top edge
                // transition can't do — a fast flick parks in the top
                // bounce before the extend applies, the edge state never
                // re-transitions, and extension stalls after one step
                // (07:23 device trace: window stuck at 240 of 628, chat
                // looked like it "ended"). Row visibility is ground
                // truth under eager layout; `extendHistoryWindow`
                // self-dedups.
                if !isFollowingTail,
                   let firstID = viewModel.windowedRows.first?.id,
                   visibleIDs.contains(firstID) {
                    revealOlderHistory(via: proxy)
                }
            }
            // Gesture-driven follow-mode transitions. Only a real drag
            // exits the mode — programmatic scrolls and layout drift
            // never report `.interacting`. Re-armed by settling near the
            // bottom: geometry, not row identity (an anchor-id
            // comparison is disarmed by the very drift it guards
            // against — 2026-07-13 traces).
            .onUserScrollGesture(
                begin: {
                    visibleRows.gestureCount += 1
                    if isFollowingTail {
                        isFollowingTail = false
                        chatViewLogger.breadcrumb("follow-tail OFF (user gesture)")
                    }
                },
                settle: {
                    if !isFollowingTail, isNearBottom {
                        isFollowingTail = true
                        chatViewLogger.breadcrumb("follow-tail ON (settled at tail)")
                    }
                }
            )
            // Keyboard re-pin backstop. The `.sizeChanges` bottom anchor
            // is expected to ride the keyboard resize on its own, so
            // this fires ONLY when geometry says the engine actually
            // lost the bottom (`!isNearBottom`) — unconditional firing
            // made every keyboard-open a scroll even when nothing was
            // wrong. Non-animated: opening the keyboard mid-bot-turn
            // means the streaming reply is growing the layout under the
            // correction, and an animated scrollTo aimed at moving
            // layout is the round-7 overshoot mechanism (re-observed
            // 2026-07-14 06:41 trace: viewport left the bottom with no
            // user gesture while a tool-heavy turn streamed). An
            // instant scroll computes and lands atomically.
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification)) { _ in
                guard isFollowingTail, !isNearBottom else { return }
                guard let target = bottomScrollTargetID else { return }
                chatViewLogger.breadcrumb("keyboard re-pin → \(target) (\(visibleRows.geoDescription))")
                proxy.scrollTo(target, anchor: .bottom)
            }
            // Restore the per-room scroll position. Cached view model:
            // rows are live, resolve immediately (imperative scroll —
            // can't be clobbered). Fresh view model: park the id in
            // `pendingRestoreID` for the rows-populated observer below.
            // Either way a remembered id the room no longer contains is
            // dropped — restoring it would pin the viewport to nothing
            // (the old blank-on-open).
            .task {
                if let restored = ChatScrollPositionMemory.retrieve(roomID: viewModel.roomID) {
                    if viewModel.rowAnchorIDs.isEmpty {
                        isFollowingTail = false
                        pendingRestoreID = restored
                    } else if viewModel.rowAnchorIDs.contains(restored) {
                        isFollowingTail = false
                        restoreScroll(to: restored, via: proxy)
                    } else {
                        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                    }
                    return
                }
                // Open-at-bottom verification. `initialOffset: .bottom`
                // computes against estimated lazy row heights and can
                // land a bubble or two short once real heights settle —
                // warm reopens showed near-bottom → false 16ms after
                // appear, persisting until a manual flick (2026-07-14
                // 06:38:46 / 06:40:09 traces). One non-animated
                // correction after first layout settles; skipped if the
                // user has already taken over.
                try? await Task.sleep(nanoseconds: 350_000_000)
                if isFollowingTail, !isNearBottom, let target = bottomScrollTargetID {
                    chatViewLogger.breadcrumb("open re-pin → \(target) (\(visibleRows.geoDescription))")
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.rows.isEmpty) { _, isEmpty in
                guard !isEmpty, let restored = pendingRestoreID else { return }
                pendingRestoreID = nil
                if viewModel.rowAnchorIDs.contains(restored) {
                    restoreScroll(to: restored, via: proxy)
                } else {
                    // The remembered row didn't survive to this open —
                    // fall back to the open-at-tail default.
                    ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                    isFollowingTail = true
                }
            }
            // Discrete tail changes (a send's echo, a finalized reply, a
            // tool-output row — NOT streaming growth, which keeps the
            // row id). Two jobs: (1) your own outgoing message always
            // returns you to the bottom, even if follow-tail was
            // disarmed at the moment you sent (2026-07-14 06:54 trace:
            // a spurious gesture-OFF at send left the sent bubble 63pt
            // behind the composer); (2) while following, an instant
            // re-pin per new row covers the engine's habit of landing
            // appends a bubble short. Non-animated — animated scrolls
            // against estimated lazy layout are the ones that fail.
            .onChange(of: viewModel.lastRenderableItemID) { _, newID in
                guard newID != nil else { return }
                if viewModel.lastRenderableItemIsOwn, !isFollowingTail {
                    isFollowingTail = true
                    chatViewLogger.breadcrumb("follow-tail ON (own send)")
                }
                guard isFollowingTail, let target = bottomScrollTargetID else { return }
                proxy.scrollTo(target, anchor: .bottom)
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
            // Floating jump-to-latest — visible whenever the user has
            // left follow-tail mode. Imperative scroll: the retired
            // binding write here was reverted by the ScrollView's
            // post-layout write-back within 1-6ms, five presses in a
            // row (2026-07-14 device trace) — the button looked dead.
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingTail {
                    JumpToBottomButton {
                        isFollowingTail = true
                        chatViewLogger.breadcrumb("follow-tail ON (jump button, \(visibleRows.geoDescription))")
                        // Deliberately NOT animated: an animated scrollTo
                        // against estimated lazy layout silently no-oped
                        // twice on device (06:40:13 / 06:54:32 traces —
                        // "I tap it and nothing happens") while the
                        // non-animated keyboard re-pin moved the same
                        // distance instantly.
                        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                        // Kill any in-flight fling, snap to the bottom
                        // offset in the same frame (UIKit reach-through
                        // — nothing on the SwiftUI surface can stop a
                        // live deceleration; see `NativeScrollViewBox`),
                        // then let scrollTo settle row-exact position on
                        // the now-still view. Verify loop below catches
                        // anything that still slips. (Window reset
                        // deliberately does NOT happen here — swapping
                        // `windowedRows` mid-scroll rebuilt the layout
                        // under the jump's feet; `onDisappear` owns the
                        // trim.)
                        nativeScroll.killMomentumAndSnapToBottom()
                        if let target = bottomScrollTargetID {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                        followHealTask?.cancel()
                        followHealTask = Task { @MainActor in
                            for _ in 0..<10 {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled, isFollowingTail, !isNearBottom,
                                      let target = bottomScrollTargetID else { return }
                                chatViewLogger.breadcrumb("jump re-assert → \(target) (\(visibleRows.geoDescription))")
                                proxy.scrollTo(target, anchor: .bottom)
                            }
                        }
                    }
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
            // Sub-chat switcher — shown whenever this chat has ANY children
            // (running or finished). The running strip hides itself the
            // moment the last subagent finishes, so without this the only
            // way back into a finished sub-chat is its timeline card; this
            // is the permanent entry point (Dan, 2026-07-15).
            if !stripViewModel.children.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(stripViewModel.children) { child in
                            NavigationLink(value: child.id) {
                                Label(
                                    child.title,
                                    systemImage: child.isRunning
                                        ? "circle.dashed" : "checkmark.circle"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .accessibilityLabel("Subagents")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSessionStatus = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Session status")
            }
        }
        .sheet(isPresented: $showSessionStatus) {
            SessionStatusSheet(viewModel: viewModel)
        }
        .task {
            // (Scroll-memory restore lives on the ScrollView inside the
            // ScrollViewReader above — it needs the proxy.)
            //
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
            stripViewModel.start()
            stripStartedGeneration = stripViewModel.observationGeneration
            await viewModel.start()
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
            chatViewLogger.breadcrumb("chat view disappear room=\(viewModel.roomID) lastVisible=\(visibleRows.bottomID ?? "nil") following=\(isFollowingTail)")
            followHealTask?.cancel()
            followHealTask = nil
            // Capture the user's scroll position so the next open of
            // this room lands where they left off. A user in follow-tail
            // mode gets no entry — the default behaviour already opens
            // at the bottom, and storing a live-tail row id would reopen
            // the room pinned to a stale position.
            if !isFollowingTail, let id = visibleRows.bottomID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                // Off-screen and back at the tail: shrink the cached VM's
                // history window so the next open renders the small
                // default, not everything revealed last visit. (A reader
                // mid-history keeps theirs — the restore path needs those
                // rows via `ensureWindowContains`.)
                viewModel.resetHistoryWindow()
            }
            // Generation-guarded: the VM is cached per room (ChatVMCache in
            // ChatListView), and on a same-room remount SwiftUI can run the
            // NEW view's `.task`/start() before the OLD view's onDisappear —
            // an unconditional stop() would kill the successor's stream.
            viewModel.stop(ifGeneration: startedGeneration)
            stripViewModel.stop(ifGeneration: stripStartedGeneration)
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
        // Forensic breadcrumbs for the blank-chat hunt: the two branch
        // swaps that replace the message area with something else
        // (placeholder / warm-up spinner) and the view's own lifecycle.
        // The 2026-07-13 traces had silent gaps exactly where these
        // events would have been — a "blank chat" report that shows a
        // placeholder flip here and no anchor activity is a state bug,
        // not a scroll bug, and vice versa.
        .onAppear {
            chatViewLogger.breadcrumb("chat view appear room=\(viewModel.roomID) rows=\(viewModel.rows.count)")
        }
        .onChange(of: viewModel.settledEmpty) { _, isEmpty in
            chatViewLogger.breadcrumb("settledEmpty → \(isEmpty) (rows=\(viewModel.rows.count), items=\(viewModel.items.count))")
        }
        .onChange(of: viewModel.rows.isEmpty) { _, isEmpty in
            chatViewLogger.breadcrumb("rows \(isEmpty ? "EMPTY — warm-up spinner over blank area" : "populated") (items=\(viewModel.items.count))")
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
    let onPreview: (ChatView.AttachmentPreview) -> Void
    let onShowSource: (TimelineItem) -> Void

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
                switch row {
                case .separator(let date):
                    DateSeparator(date: date)
                        .id(row.id)
                case .message(let item):
                    if let child = subtaskChild(for: item) {
                        // Bridge subtask indicator → tappable card opening
                        // the child sub-chat (`chatDestination` routes the
                        // child id to `SubChatView`). Keeps the row's
                        // `.id(item.id)` so scroll anchors are unaffected.
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
                        .id(item.id)
                    } else {
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
                        // No `.onAppear` history trigger here: row
                        // materialization is not evidence the user
                        // scrolled anywhere (an eager stack mounts every
                        // row immediately), so window extension is driven
                        // solely by the scroll-geometry near-top check in
                        // `ChatView`.
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
        }
        .scrollTargetLayout()
        .padding(.vertical)
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
    @State private var sourceItem: TimelineItem?
    @State private var attachmentPreview: ChatView.AttachmentPreview?
    /// Captured only to install `HorizontalOverflowLock` — the sub-chat
    /// timeline must be as wiggle-proof as the parent's (ChatView).
    @State private var nativeScroll = NativeScrollViewBox()
    @State private var startedGeneration = 0
    /// Generation guard for the SHARED per-parent strip VM — switching to a
    /// sibling replaces this view, and the successor's `.task` can restart
    /// the strip before this instance's `onDisappear` fires (see ChatView).
    @State private var stripStartedGeneration = 0

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
                        onPreview: { attachmentPreview = $0 },
                        onShowSource: { sourceItem = $0 }
                    )
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
            viewModel.stop(ifGeneration: startedGeneration)
            stripViewModel.stop(ifGeneration: stripStartedGeneration)
        }
        .sheet(item: $sourceItem) { item in
            EventSourceSheet(item: item)
        }
        .sheet(item: $attachmentPreview) { preview in
            switch preview {
            case .image(_, let img):
                AttachmentFullscreenViewer(image: img, onDismiss: { attachmentPreview = nil })
            case .file(_, let url, let filename):
                VStack(spacing: 16) {
                    Image(systemName: "doc").font(.system(size: 56)).foregroundStyle(.tint).padding(.top, 32)
                    Text(filename).font(.headline).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal)
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.accentColor).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                    Button("Done") { attachmentPreview = nil }.padding(.top, 4)
                    Spacer()
                }
                .padding()
                .presentationDetents([.medium])
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

