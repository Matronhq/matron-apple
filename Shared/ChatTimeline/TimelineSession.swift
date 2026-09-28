import Foundation
import CoreGraphics
import os
import MatronChat
import MatronModels
import MatronViewModels

/// Un-gated breadcrumbs for the UIKit timeline — same subsystem as the
/// SwiftUI path's `ios-chat-view`, so field traces read as one story.
/// Shared with the Mac timeline (same category, so existing log-filter
/// recipes keep matching); `breadcrumb`/`diag` come from `MatronModels`.
let timelineLogger = Logger(subsystem: "chat.matron", category: "ios-chat-timeline")

/// The platform-neutral rules of the chat timeline (spec 2026-09-26, moved
/// out of `ChatTimelineController` for the Mac timeline): follow-tail and
/// own-send pinning, scroll-position restore, jumps, paging at the edges,
/// suspend/resume and the blank-chat invariant. It owns the
/// `TimelineScrollModel` and is the ONLY writer of the surface's offset —
/// always the value the model decided, through `performLayoutUpdate`.
@MainActor
final class TimelineSession {
    let viewModel: ChatViewModel
    /// The surface owns the session; unowned breaks the cycle.
    private unowned let surface: TimelineSurface

    private(set) var scrollModel: TimelineScrollModel
    private(set) var contents: [String: TimelineRowContent] = [:]
    private var isApplyingLayout = false
    private(set) var isTornDown = false
    private var lastTailID: String?
    private var extendInFlight = false
    /// The window head an extend last came back with unchanged AND the
    /// view model confirmed exhausted: near-top stops asking until the
    /// head moves. `private(set)` only for `TimelinePaginationTests` — a
    /// test seam, never written from outside the controller.
    private(set) var exhaustedHeadID: String?
    private(set) var extendRequestCount = 0
    /// Set when a jump lands: `afterApply` must not fire pagination edge
    /// triggers off the back of that same apply (spec §2 Jumps — a jump
    /// landing near the top or bottom must not read as the user paging).
    /// Cleared the moment the user actually starts dragging.
    private var suppressEdgeTriggersUntilScroll = false
    /// A jump just landed and the user hasn't scrolled since: viewport
    /// resizes keep the landed row at the top (controller ruling, Task 28
    /// fix rounds 1–2; restores keep spec §2's bottom-row rule). Cleared by
    /// the user's next scroll.
    private var landedAnchorHoldsTop = false
    /// The remembered position this mount still has to land (spec §2 Scroll
    /// restoration). Read in `viewDidLoad`; cleared when it lands, when the
    /// target proves gone, or when the user / a jump takes over.
    private var pendingRestore: ChatScrollPosition?
    /// The one `ensureWindowContains` a restore may ask for. A target still
    /// missing on the apply after that gives up (no timers).
    private var restoreWidened = false
    var hasPendingRestore: Bool { pendingRestore != nil }
    /// Set by an explicit `storeScrollPosition()` (ChatView's `onDisappear`,
    /// which runs BEFORE it shrinks the window): `tearDown` must not then
    /// overwrite that entry with a post-shrink position. Cleared by anything
    /// that moves the viewport on the user's behalf afterwards — a drag, the
    /// jump button, a jump or restore landing, follow-tail re-arming (own
    /// send, settling at the tail), a status-bar scroll-to-top, the invariant
    /// snap — and by `resume()` (final review MUST 4).
    private var storedSinceLastMove = false
    /// Off screen but not dismantled (tab switch, a push): no applies, so the
    /// window shrink `onDisappear` makes can't move — or rescue — an unseen
    /// viewport. `resume()` re-arms the remembered position and resyncs.
    private(set) var isSuspended = false
    /// The blank-chat tripwire's fire count (spec §2 invariant). A test seam
    /// and a field-diagnostics counter; should stay 0 forever.
    private(set) var invariantSnapCount = 0

    init(viewModel: ChatViewModel, surface: TimelineSurface, metrics: TimelineScrollModel.Metrics = .init()) {
        self.viewModel = viewModel
        self.surface = surface
        self.scrollModel = TimelineScrollModel(metrics: metrics)
    }

    // MARK: Lifecycle

    /// The surface finished loading (iOS `viewDidLoad`): read the remembered
    /// position and ask for the first sync.
    func mount() {
        // Read at mount, not in `init`: a controller can exist before its
        // room's position is stored (`TimelineHarness(attach: false)`).
        pendingRestore = ChatScrollPositionMemory.retrievePosition(roomID: viewModel.roomID)
        if pendingRestore != nil {
            // Same as the SwiftUI path: a remembered position opens released.
            scrollModel.stopFollowing()
            surface.followingChanged(false)
        }
        surface.requestSync()
    }

    /// Called by the surface when its timeline is removed. The surface
    /// stops its own coalescer and precompute.
    func tearDown() {
        guard !isTornDown else { return }
        // Review F6: store here too — SwiftUI may dismantle before
        // `onDisappear`, whose store goes through the bridge's WEAK controller.
        if !storedSinceLastMove { storeScrollPosition() }
        isTornDown = true
    }

    // MARK: Off screen (final review MUST 1)

    /// Leaving the screen without a dismantle: remember the position (unless
    /// `onDisappear` just did) and stop applying until `resume()`. Idempotent
    /// — `ChatView.onDisappear` and `viewDidDisappear` both call it.
    func suspend() {
        guard !isTornDown, !isSuspended else { return }
        if !storedSinceLastMove { storeScrollPosition() }
        isSuspended = true
        timelineLogger.breadcrumb("timeline suspended room=\(viewModel.roomID) following=\(scrollModel.isFollowingTail)")
    }

    /// Back on screen: re-arm the remembered position exactly like a fresh
    /// mount's `viewDidLoad` (the SwiftUI path re-restores in `.task` on
    /// every appear), then resync. Idempotent; a no-op on first appear.
    ///
    /// Bugbot "Restore loses place on reappear": no widening here. ChatView's
    /// `.task` runs `beginEntryWindow()` AFTER this, and a widen made now
    /// could be shrunk straight back to the entry slice while the one widen
    /// a restore gets was already spent — the apply then gave up and jumped
    /// to the tail. `handlePendingRestore` widens after the first apply,
    /// exactly as on a fresh mount (and ChatView skips `beginEntryWindow`
    /// while a restore is pending).
    func resume() {
        guard !isTornDown, isSuspended else { return }
        isSuspended = false
        storedSinceLastMove = false
        restoreWidened = false
        pendingRestore = ChatScrollPositionMemory.retrievePosition(roomID: viewModel.roomID)
        if pendingRestore != nil {
            scrollModel.stopFollowing()
            surface.followingChanged(false)
        }
        timelineLogger.breadcrumb("timeline resumed room=\(viewModel.roomID) restore=\(pendingRestore?.itemID ?? "none")")
        surface.requestSync()
    }

    // MARK: Geometry

    /// The viewport height changed. `widthChanging` (final review MUST 2):
    /// rotation changes width AND height in one pass, and the width resync
    /// that follows keeps the TOP anchor, so the height change must keep
    /// the top too.
    func setViewportHeight(_ height: CGFloat, widthChanging: Bool) {
        performLayoutUpdate { model in
            model.setViewportHeight(height, keepingTop: landedAnchorHoldsTop || widthChanging)
        }
        // Rows may have applied while the viewport was still 0 tall.
        if pendingRestore != nil { handlePendingRestore() }
    }

    // MARK: Content

    /// Applies one pass of measured rows. `heights` must hold every row's
    /// exact height (no estimates); `forceReconfigure` re-renders every
    /// surviving row (a width or Dynamic Type resync).
    func apply(_ newContents: [TimelineRowContent], heights: [String: CGFloat], footerHeight: CGFloat,
               forceReconfigure: Bool) {
        var rows: [TimelineScrollModel.Row] = []
        rows.reserveCapacity(newContents.count)
        var reconfigure: [String] = []
        var reload: [String] = []
        var nextContents: [String: TimelineRowContent] = [:]
        for content in newContents {
            let id = content.anchorID
            if let old = contents[id], old != content || forceReconfigure {
                // A reconfigure must dequeue the same cell class it already
                // shows; a row switching text ↔ hosted is reloaded instead.
                if old.isText == content.isText { reconfigure.append(id) } else { reload.append(id) }
            }
            let height: CGFloat
            if let measured = heights[id] {
                height = measured
            } else {
                assertionFailure("timeline row \(id) applied without a height")
                height = 0
            }
            nextContents[id] = content
            rows.append(.init(id: id, height: height))
        }
        contents = nextContents

        // `contents` (before this pass) is exactly the applied snapshot:
        // both only ever change here, together.
        let ids = rows.map(\.id)
        performLayoutUpdate({ model in
            model.windowContainsTail = viewModel.windowContainsTail
            model.replaceRows(rows, footerHeight: footerHeight, holdingBottom: pendingRestore != nil)
        }, present: {
            surface.applyRows(ids, reconfigure: reconfigure, reload: reload)
        })
        if let rescue = scrollModel.lastRescue {
            timelineLogger.breadcrumb("timeline anchor \(rescue.lostRowID) vanished → \(rescue.survivorID ?? "bottom")")
        }
        // Brief's `changed` = rows this pass actually reconfigured or reloaded
        // (the current code tracks those as two separate arrays, not one).
        timelineLogger.diag("timeline apply rows=\(rows.count) changed=\(reconfigure.count + reload.count) following=\(scrollModel.isFollowingTail) offset=\(Int(scrollModel.contentOffsetY)) contentH=\(Int(scrollModel.contentHeight))")
        verifyVisibleRows()
    }

    func afterApply() {
        // Restore first: it yields to a pending focus jump, which then lands
        // in the same pass (a focus handled first would be overwritten).
        handlePendingRestore()
        handlePendingFocus()
        handleTailChange()
        // A prepend that lands while the reader is still near the top keeps
        // revealing; a detached window's bottom keeps sliding. A jump's own
        // landing apply is excluded (`suppressEdgeTriggersUntilScroll`):
        // see `handlePendingFocus`.
        if !scrollModel.isFollowingTail, !suppressEdgeTriggersUntilScroll { evaluateEdgeTriggers() }
    }

    /// A row's rendered height settled at something other than measured
    /// (a hosted row self-reporting, a streaming re-measure).
    func updateHeight(ofRow id: String, to height: CGFloat) {
        performLayoutUpdate { $0.updateHeight(ofRow: id, to: height) }
    }

    /// The activity footer's height changed outside an apply.
    func setFooterHeight(_ height: CGFloat) {
        performLayoutUpdate { $0.setFooterHeight(height) }
    }

    /// The single offset write path: mutate the model, write the model's
    /// offset, lay out — all inside one guard so the surface's intermediate
    /// scroll callbacks can't feed back into the model.
    func performLayoutUpdate(_ changes: (inout TimelineScrollModel) -> Void) {
        performLayoutUpdate(changes, present: {})
    }

    /// `present` runs after the model changed and before the offset write,
    /// OUTSIDE the model's `inout` access: a surface applying rows lays out
    /// synchronously, and its layout reads `scrollModel`.
    private func performLayoutUpdate(_ changes: (inout TimelineScrollModel) -> Void, present: () -> Void) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        changes(&scrollModel)
        present()
        surface.setContentOffset(scrollModel.contentOffsetY)
        surface.followingChanged(scrollModel.isFollowingTail)
    }

    // MARK: Position rules

    /// Your own outgoing message always returns you to the bottom.
    private func handleTailChange() {
        let tail = viewModel.lastRenderableItemID
        defer { lastTailID = tail }
        guard let tail, let previous = lastTailID, tail != previous,
              viewModel.lastRenderableItemIsOwn, !scrollModel.isFollowingTail else { return }
        timelineLogger.breadcrumb("follow-tail ON (own send)")
        storedSinceLastMove = false
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
        performLayoutUpdate { model in model.followTail() }
    }

    /// The jump-to-latest button.
    func jumpToBottom() {
        cancelPendingRestore("jump button")
        landedAnchorHoldsTop = false
        storedSinceLastMove = false
        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
        timelineLogger.breadcrumb("follow-tail ON (jump button)")
        performLayoutUpdate { model in
            surface.killMomentum()
            model.followTail()
        }
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
    }

    // MARK: User scrolling

    /// Every user-driven offset — drag, deceleration, bounce — lands in the
    /// model (anchor capture reads it). Offsets the controller writes itself
    /// are already the model's and are skipped.
    func userScrolled(toOffset y: CGFloat) {
        guard !isApplyingLayout else { return }
        scrollModel.noteUserOffset(y)
        evaluateEdgeTriggers()
    }

    /// A status-bar tap scrolls to the top with no drag callbacks; it is
    /// still the user leaving the tail, so it releases follow-tail here
    /// (iOS `scrollViewShouldScrollToTop`).
    func userWillScrollToTop() {
        landedAnchorHoldsTop = false
        if scrollModel.isFollowingTail {
            scrollModel.stopFollowing()
            timelineLogger.breadcrumb("follow-tail OFF (scroll to top)")
            surface.followingChanged(false)
        }
    }

    /// iOS `scrollViewDidScrollToTop`.
    func userScrolledToTop() {
        // The status-bar tap moved the reader: an earlier explicit store is
        // stale now (final review MUST 4).
        storedSinceLastMove = false
        userScrollSettled()
    }

    func userDragBegan() {
        suppressEdgeTriggersUntilScroll = false
        landedAnchorHoldsTop = false
        storedSinceLastMove = false
        cancelPendingRestore("user drag")
        if scrollModel.beginUserDrag() {
            timelineLogger.breadcrumb("follow-tail OFF (user drag)")
            surface.followingChanged(false)
        }
    }

    func userScrollSettled() {
        scrollModel.windowContainsTail = viewModel.windowContainsTail
        if scrollModel.endUserScroll() {
            storedSinceLastMove = false
            timelineLogger.breadcrumb("follow-tail ON (settled at tail)")
            surface.followingChanged(true)
        }
    }

    // MARK: Restoration

    /// Spec §2 Scroll restoration: exact (id, offset) when the row is
    /// applied; widen once when it is loaded but outside the window;
    /// otherwise the entry is gone — forget it and open at the tail.
    /// A pending focus jump wins (review F5).
    private func handlePendingRestore() {
        guard let position = pendingRestore, !scrollModel.rows.isEmpty,
              scrollModel.viewportHeight > 0 else { return }
        if viewModel.pendingFocusID != nil {
            // Back to the no-memory state; `handlePendingFocus` runs next.
            // Final review minor 5: never re-arm follow-tail on a window
            // detached from the live tail — the focus owns that window (its
            // `ensureWindowContains` detached it), so it is not reset here;
            // the jump lands from where the viewport is.
            cancelPendingRestore("pending focus")
            if viewModel.windowContainsTail { performLayoutUpdate { model in model.followTail() } }
            return
        }
        if scrollModel.index(of: position.itemID) != nil {
            pendingRestore = nil
            storedSinceLastMove = false
            var landed = false
            performLayoutUpdate { model in
                if let offset = position.offsetInRow {
                    // `restore` clamps into the row (it may have shrunk).
                    landed = model.restore(.init(rowID: position.itemID, offsetInRow: CGFloat(offset)))
                } else {
                    landed = model.restoreBottomAligned(rowID: position.itemID)
                }
                if !landed { model.followTail() }
            }
            // Task 22 ruling: the landing apply must not fire the edge
            // triggers; only the user's next scroll may.
            suppressEdgeTriggersUntilScroll = true
            // Fix round 2 ruling: a restore does NOT hold the top — tapping
            // the composer after reopening must keep the bottom row the
            // reader was on (spec §2 Keyboard). Only jumps hold the top.
            landedAnchorHoldsTop = false
            timelineLogger.breadcrumb("restore → \(position.itemID) +\(position.offsetInRow.map { Int($0) } ?? -1) landed=\(landed)")
            return
        }
        if !restoreWidened, viewModel.rowAnchorIDs.contains(position.itemID) {
            restoreWidened = true
            viewModel.ensureWindowContains(position.itemID)
            // Synchronous: if the window now holds the row, the apply this
            // triggers lands it; if widening couldn't, give up now.
            if viewModel.windowedRows.contains(where: { TimelineRowContentBuilder.anchorID(for: $0) == position.itemID }) {
                return
            }
        } else if restoreWidened, surface.hasPendingWork {
            // The widened window hasn't applied yet (e.g. a viewport-height
            // retry landed first); the apply that lands it decides.
            return
        }
        pendingRestore = nil
        storedSinceLastMove = false
        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
        timelineLogger.breadcrumb("restore target \(position.itemID) gone (widened=\(restoreWidened)) → tail")
        performLayoutUpdate { model in model.followTail() }
        // Mirror `jumpToBottom` (final review minor 5): following means the
        // window ends at the live tail.
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
    }

    private func cancelPendingRestore(_ reason: String) {
        guard let position = pendingRestore else { return }
        pendingRestore = nil
        timelineLogger.breadcrumb("restore → \(position.itemID) cancelled (\(reason))")
    }

    /// Leaving the room: remember the top anchor, or nothing while following.
    func storeScrollPosition() {
        guard !isTornDown else { return }                // tearDown already stored
        guard pendingRestore == nil else { return }      // never overwrite an unapplied entry
        storedSinceLastMove = true
        guard !scrollModel.isFollowingTail, let anchor = scrollModel.topAnchor() else {
            ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            return
        }
        ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: anchor.rowID,
                                       offsetInRow: Double(anchor.offsetInRow))
    }

    // MARK: Jumps

    /// Spec §2 Jumps. `focus(seq:)` has already widened the window; if our
    /// apply of that window is still pending (precompute), the next sync
    /// lands it. A target the view model no longer has at all is dropped.
    private func handlePendingFocus() {
        guard let target = viewModel.pendingFocusID else { return }
        guard scrollModel.index(of: target) != nil else {
            if !viewModel.rowAnchorIDs.contains(target) {
                timelineLogger.breadcrumb("jump target \(target) not loaded — dropped")
                viewModel.clearPendingFocus()
            } else if !viewModel.windowedRows.contains(where: { TimelineRowContentBuilder.anchorID(for: $0) == target }) {
                viewModel.ensureWindowContains(target)
            }
            return
        }
        viewModel.clearPendingFocus()
        storedSinceLastMove = false
        performLayoutUpdate { model in
            surface.killMomentum()
            _ = model.jumpOffset(toRow: target)
            // Ruling: a jump that clamps to the very bottom while the
            // window still ends at the live tail means the user is sitting
            // at the bottom — re-arm follow-tail rather than leaving them
            // detached there.
            if model.windowContainsTail, model.contentOffsetY >= model.maxOffsetY - 0.5 {
                model.followTail()
            }
        }
        // Ruling: no paging off the back of a jump — this apply must not
        // fire the pagination edge triggers; only the user's next scroll
        // may (cleared in `scrollViewWillBeginDragging`).
        suppressEdgeTriggersUntilScroll = true
        landedAnchorHoldsTop = !scrollModel.isFollowingTail
        timelineLogger.breadcrumb("jump → \(target) (offset \(Int(scrollModel.contentOffsetY)))")
        surface.flashRow(target)
    }

    // MARK: Pagination

    /// Spec §2 Pagination. Older: not following and within 1.5 screens of
    /// the top → `extendHistoryWindow()` (local growth first, network when
    /// the window already shows everything). Newer: a window detached from
    /// the tail, viewport near its bottom → `revealNewerHistory()`. Both
    /// prepends and slides keep the viewport by anchor — no pin, no retry.
    ///
    /// Review fix: `extendInFlight` / `isExtendingWindow` clear a fixed
    /// 150ms after the model change, but a big batch's precompute (and the
    /// apply that follows it) can easily outlive that hold. A scroll frame
    /// landing in that gap saw every guard clear and re-fired — 120 rows,
    /// then 240, then 360. `hasPendingWork` covers exactly that gap (the
    /// precompute in flight, or a sync already coalesced waiting for the
    /// next frame); `afterApply` re-evaluates once the batch actually lands.
    private func evaluateEdgeTriggers() {
        // No paging while a remembered position is still to land: the
        // viewport isn't the user's yet (review F5).
        guard !surface.hasPendingWork, pendingRestore == nil else { return }
        if !scrollModel.isFollowingTail, scrollModel.isNearTop { requestOlderHistory() }
        if !viewModel.windowContainsTail, scrollModel.isNearBottom,
           !viewModel.isExtendingWindow, !viewModel.isPaginatingBackward {
            timelineLogger.breadcrumb("reveal newer (window detached, tail anchor \(viewModel.windowTailAnchorID ?? "nil"))")
            viewModel.revealNewerHistory()
        }
    }

    private func requestOlderHistory() {
        let head = scrollModel.rows.first { !$0.id.hasPrefix("sep:") }?.id
        guard !extendInFlight, !viewModel.isExtendingWindow, !viewModel.isPaginatingBackward,
              head != exhaustedHeadID else { return }
        extendInFlight = true
        extendRequestCount += 1
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.extendHistoryWindow()
            let newHead = self.viewModel.windowedRows.lazy.compactMap { row -> String? in
                if case .message(let item) = row { return item.id }
                return nil
            }.first
            // Latch only when BOTH this call made no progress (the head is
            // exactly where it started) AND the view model's own verdict is
            // real exhaustion. Neither alone is enough: `reachedHistoryStart`
            // stays true for the life of the view model, so gating on it
            // alone latched the head of a later, perfectly SUCCESSFUL local
            // grow too (review fix round 2) — which could then block a
            // legitimate reveal that walks back onto that same head. And
            // "head didn't move" alone also fires on a local slide that
            // merely *held* (120+ consecutive transient rows, no network
            // call at all) — not real exhaustion either (review fix round 1).
            self.exhaustedHeadID = (self.viewModel.reachedHistoryStart && newHead == head) ? head : nil
            self.extendInFlight = false
            timelineLogger.diag("history reveal → head \(newHead ?? "nil") (was \(head ?? "nil")), reachedHistoryStart=\(self.viewModel.reachedHistoryStart)")
        }
    }

    // MARK: Invariant

    /// The blank-chat tripwire: rows exist but no cell is on screen. With
    /// exact heights and one offset writer this should never fire; if it
    /// does, leave a full breadcrumb and put the reader somewhere real.
    ///
    /// Review fix: rows can apply while the viewport is still 0 tall (mount,
    /// or a resize mid-flight) — `sync()` only requires `width > 0`. Without
    /// the viewport-height guard that state reads as "rows but no visible
    /// cells" and snaps for no reason, even over a pending restore.
    func verifyVisibleRows() {
        guard !scrollModel.rows.isEmpty, scrollModel.viewportHeight > 0 else { return }
        guard !surface.hasVisibleRows() else { return }
        invariantSnapCount += 1
        storedSinceLastMove = false
        timelineLogger.breadcrumb("INVARIANT rows=\(scrollModel.rows.count) visible=0 offset=\(Int(scrollModel.contentOffsetY)) contentH=\(Int(scrollModel.contentHeight)) viewport=\(Int(scrollModel.viewportHeight)) following=\(scrollModel.isFollowingTail) → snap to bottom")
        // Review fix: mirror `jumpToBottom` — kill any residual momentum
        // inside the same offset write, and never re-arm follow-tail on a
        // window detached from the live tail.
        performLayoutUpdate { model in
            surface.killMomentum()
            model.followTail()
        }
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
    }
}

private extension TimelineRowContent {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
