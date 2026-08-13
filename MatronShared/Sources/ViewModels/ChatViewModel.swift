import CryptoKit
import Foundation
import SwiftUI
import os
import MatronChat
import MatronEvents
import MatronJournal
import MatronModels
import MatronStorage

/// Rendering unit for the chat timeline. The view-model walks `items`
/// once and interleaves `.separator` rows whenever two adjacent messages
/// straddle a calendar-day boundary; views render the resulting
/// `[TimelineRow]` directly instead of duplicating the bucketing logic
/// across iOS and Mac.
///
/// `.separator` carries only the boundary `Date` — the human-readable
/// label ("Today" / "Yesterday" / "Tuesday" / "5 Mar 2026") is resolved
/// at render time by the View through `DateSeparatorLabel.format` so
/// `MatronViewModels` doesn't need a `MatronDesignSystem` dependency
/// (which would pull SwiftUI / MarkdownUI into a non-View module).
///
/// `id` is `Hashable` so SwiftUI's `ForEach` can diff the row stream
/// without manual `id:` parameters. Separator ids key on the start-of-
/// day epoch so two snapshots on the same day re-use the same SwiftUI
/// identity slot — a row remount on every snapshot would burn the
/// `.transition` animation budget for no behavioural gain.
public enum TimelineRow: Identifiable, Equatable, Sendable {
    case message(TimelineItem)
    case separator(date: Date)

    public var id: String {
        switch self {
        case .message(let item): return "msg:\(item.id)"
        case .separator(let date):
            // Bucket by calendar day so a stream of items spanning a
            // single day all collide on one identity even if the
            // boundary `Date` value is the first item's exact
            // timestamp (which differs per render).
            let day = Calendar.current.startOfDay(for: date)
            return "sep:\(Int(day.timeIntervalSince1970))"
        }
    }
}

/// Drives a single chat screen. Subscribes to a room's `TimelineService.items()`
/// stream, exposes the current snapshot as `items`, and forwards
/// pagination + mark-as-read calls to the underlying service.
///
/// `start()` returns the observation `Task` so callers (especially tests) can
/// `await task.value` to know when the stream has drained — the live impl
/// keeps the stream open across diff updates, but the in-memory fake finishes
/// after yielding all queued snapshots, which makes tests deterministic
/// without sleeps.
///
/// Task 12b added a `MediaService` dependency and a `resolvedImages` cache so
/// `TimelineItemView` can hand a real `Image?` to `AttachmentImage` for
/// `mxc://` image attachments. The cache is populated lazily on first
/// `image(for:)` call; subsequent calls hit the in-memory dictionary.
///
/// Note: there is no `deinit { observationTask?.cancel() }`. Swift 6 / Xcode 26
/// strict concurrency forbids accessing `@MainActor`-isolated properties from
/// a nonisolated `deinit`. SwiftUI views must call `stop()` explicitly from
/// `View.onDisappear` (mirroring `ChatListViewModel.cancel()` from Phase 1).
@Observable
@MainActor
public final class ChatViewModel {
    /// Cap for both `resolvedImages` and `failedRequests`. A long session
    /// in a media-heavy room previously held a SwiftUI `Image` reference
    /// per `mxc://` URL it had ever rendered — separate from
    /// `MediaServiceLive`'s NSCache (which evicts opaquely on memory
    /// pressure) — so the in-process retain set grew unbounded for the
    /// lifetime of the room push (QA finding #4). 100 entries is enough
    /// to cover the visible window plus a generous lookahead while
    /// keeping the upper bound predictable. Static so tests can pin the
    /// exact eviction boundary.
    public static let mediaCacheLimit: Int = 100

    /// Subsystem-tagged logger for view-model diagnostics. Same
    /// "chat.matron" subsystem the rest of the package uses so output
    /// streams together in `os_log` consumers.
    private static let logger = os.Logger(subsystem: "chat.matron", category: "chat-view-model")


    public let roomID: String
    /// The raw timeline snapshot from the SDK. Setter is private so
    /// every mutation flows through `applySnapshot(_:)` which keeps
    /// the memoised derived state (`rows`, `firstRenderableItemID`,
    /// `lastRenderableItemID`) in sync. Reading `items` directly is
    /// still cheap; what we needed to avoid was the derived state
    /// recomputing on every body re-eval (see the doc-comment on
    /// `rows`).
    public private(set) var items: [TimelineItem] = []
    public private(set) var error: String?

    /// Last-known session status for this conversation (context gauge +
    /// usage limits), merged across partial frames — absent parts keep
    /// their previous value. Rendered by the Mac chat header and the iOS
    /// session-status sheet. Nil until the first status frame (the journal
    /// replays the cached one on convo-open, so this populates promptly).
    public private(set) var sessionStatus: SessionStatus?

    /// TOC summary entries for this conversation, newest-first — mirrors
    /// `TimelineService.summaryEntriesStream()`. Empty until the journal
    /// replays the room's summary rows (or forever, on backends without one).
    public private(set) var summaryEntries: [ConversationSummaryEntry] = []

    /// True while the conversation's session state is "running" — the
    /// bridge flips it via durable `session_status` journal events at
    /// turn start and turn end. Drives the floating `StopTurnButton`,
    /// which must hold solid for the whole turn: the ephemeral
    /// `activityLabel` legitimately clears mid-turn (the bridge dedups
    /// activity frames and the overlay staleness sweep drops a quiet
    /// indicator after 30s), so it can't carry that job alone.
    public private(set) var isTurnRunning = false

    /// Calendar used for date-separator bucketing. Injectable so tests
    /// can pin a deterministic timezone without poking the host
    /// runtime. Default is `Calendar.current` so production callers
    /// don't have to thread anything through.
    public var calendar: Calendar = .current {
        didSet {
            // Bucket boundaries depend on calendar; recompute so a
            // late timezone change in tests doesn't desync the row
            // list from items.
            applyDerivedRecompute()
        }
    }

    /// Render-ready row list: `items` interleaved with `.separator`
    /// rows whenever two adjacent messages straddle a calendar-day
    /// boundary (and one separator at the head of the timeline so the
    /// first cluster also has a header).
    ///
    /// Memoised — recomputed once per `applySnapshot(_:)` rather than
    /// on every read. The previous computed-property version did an
    /// O(N) filter + O(N) bucket pass on every access; SwiftUI calls
    /// `viewModel.rows` from the ForEach binding AND from
    /// `.onChange(of: scrolledItemID)`, the latter firing on every
    /// scroll-position tick, so a 1000-item room re-bucketed ~60K
    /// items/second during scroll. Caching once per snapshot drops
    /// that to ~zero on the hot path. Stale-cache risk is bounded
    /// because the only `items` mutation site is the snapshot
    /// listener, and it routes through `applySnapshot(_:)`.
    public private(set) var rows: [TimelineRow] = []

    /// The tail slice of `rows` the views actually render. Rendering the
    /// full timeline is what made the scroll layer unstable: hundreds of
    /// wildly heterogeneous rows in a lazy stack swung the content-height
    /// estimate 5x on every container resize (2026-07-14 06:51 device
    /// trace: keyboard up → contentH 115K→497K→90K, viewport stranded
    /// 2,000pt off the tail). The window bounds the row count so the
    /// views can afford to lay every row out EAGERLY (plain `VStack`) —
    /// exact heights, no estimates, nothing to churn — the standard
    /// chat-app approach. Older rows reveal via `extendHistoryWindow()`.
    public private(set) var windowedRows: [TimelineRow] = []

    /// Current render-window size in rows. Grows via
    /// `extendHistoryWindow()` / `ensureWindowContains(_:)` while the
    /// user reads history; never shrinks while they're up there
    /// (yanking rows from beneath a reader). It snaps back to
    /// `defaultWindowSize` via `resetHistoryWindow()` when the user
    /// returns to the tail (jump button) or leaves the room while
    /// following it, so the eager stack stays small in steady state.
    public private(set) var visibleWindowSize = ChatViewModel.defaultWindowSize

    /// Steady-state render-window size, sized so the eager stack's
    /// layout cost stays negligible.
    private static let defaultWindowSize = 120

    /// How many rows each `extendHistoryWindow()` reveals.
    private static let windowGrowthStep = 120

    /// `true` while a window extension's prepend is being laid out —
    /// the views anchor `.sizeChanges` to `.bottom` while this is up,
    /// same contract as `isPaginatingBackward`.
    public private(set) var isExtendingWindow = false

    /// ID of the first item the timeline view actually renders — i.e.
    /// the first non-`.stateChange` item in `items`. Used by the
    /// scroll-up `.onAppear` paginate trigger. Memoised alongside
    /// `rows` for the same reason — every body re-eval was running
    /// an O(N) `first(where:)` scan; now it's a stored property
    /// updated once per snapshot. See `applyDerivedRecompute()` for
    /// the in-sync update.
    public private(set) var firstRenderableItemID: TimelineItem.ID?

    /// Tail mirror of `firstRenderableItemID`. Same memoisation
    /// rationale — auto-follow / jump-to-bottom / scroll-memory all
    /// read this on every scroll-tick body re-eval. Stays in
    /// lockstep with `firstRenderableItemID` and the `rows` filter
    /// (all three derive from the same `.stateChange`-skip
    /// predicate); any future hidden Kind needs the same treatment
    /// in `applyDerivedRecompute()`.
    public private(set) var lastRenderableItemID: TimelineItem.ID?

    /// Whether the current tail row is the user's own message. The views
    /// use this on tail changes: your own outgoing message always returns
    /// you to the bottom (standard chat behaviour), even if follow-tail
    /// mode was disarmed at the moment you sent.
    public private(set) var lastRenderableItemIsOwn = false

    /// Every scroll-target id in the current snapshot: `item.id` for
    /// message rows (the views tag rows with the ITEM id, not
    /// `TimelineRow.id`'s `msg:`-prefixed form) plus the separator row
    /// ids. The views validate remembered scroll positions against this
    /// before restoring — a remembered id the room no longer contains
    /// would scroll to nothing (bugbot "Scroll anchor ID mismatch" for
    /// the namespace subtlety).
    ///
    /// Computed on demand with a per-snapshot memo rather than rebuilt
    /// eagerly: restores read it a handful of times per room open, but
    /// the eager build hashed every row id on EVERY snapshot commit —
    /// measurable at 3,000-item rooms × several commits/sec while
    /// streaming (2026-08-05 sample: `Hasher._combine` in the hot
    /// stacks).
    public var rowAnchorIDs: Set<String> {
        if let cached = rowAnchorIDsCache { return cached }
        let built = Set(rows.map { row in
            if case .message(let item) = row { return item.id }
            return row.id
        })
        rowAnchorIDsCache = built
        return built
    }

    /// Label of the bot's trailing activity indicator (typing / tool-use),
    /// or `nil` when idle. Extracted from the snapshot's `activityIndicator`
    /// item during `applyDerivedRecompute` — the views render it as a fixed
    /// footer between the timeline and the composer (see the row-filter
    /// comment there for why it must not be a scrollable row).
    public private(set) var activityLabel: String?

    /// Single mutation entry point for `items`. Updates the raw
    /// snapshot and the three derived caches atomically so a body
    /// re-eval that reads any combination of `items` / `rows` /
    /// `firstRenderableItemID` / `lastRenderableItemID` always sees
    /// a consistent view.
    private func applySnapshot(_ snapshot: [TimelineItem]) {
        self.items = snapshot
        applyDerivedRecompute()
    }

    /// Minimum spacing between snapshot commits while a stream is live.
    /// During an agent turn the journal delivers full-timeline snapshots
    /// several times a second; each commit reassigns the `@Observable`
    /// arrays and re-renders the whole visible window, which kept the
    /// main thread ~40% busy on a 2026-08-05 sample and made chat
    /// switches queue behind render passes. Commits outside a turn are
    /// unaffected — the first snapshot after 250ms of quiet applies
    /// immediately. `var` so tests can widen it to make coalescing
    /// deterministic.
    var snapshotCoalesceInterval: Duration = .milliseconds(250)
    /// Latest stream snapshot received inside the coalesce window,
    /// waiting for `coalesceTask` (or a flush) to commit it. Newer
    /// arrivals overwrite it — only the freshest snapshot matters.
    private var pendingSnapshot: [TimelineItem]?
    private var coalesceTask: Task<Void, Never>?
    private var lastCommitInstant: ContinuousClock.Instant?
    /// Count of snapshots actually applied (not skipped as no-ops, not
    /// superseded in the coalescer). Diagnostic; tests use it to pin the
    /// skip/coalesce behaviour.
    private(set) var appliedSnapshotCount = 0

    /// Entry point for every snapshot the live stream yields. Commits
    /// immediately when the commit is load-bearing for a caller's
    /// contract — the first snapshot (`start()` returns after it), a
    /// paginate in flight (`isPaginatingBackward` holds the views'
    /// bottom anchor until the prepend lands), or a window extension —
    /// and otherwise coalesces bursts so streaming turns commit at most
    /// once per `snapshotCoalesceInterval`.
    private func receiveSnapshot(_ snapshot: [TimelineItem]) {
        if !hasReceivedFirstSnapshot || isPaginatingBackward || isExtendingWindow {
            commitSnapshot(snapshot)
            return
        }
        let now = ContinuousClock.now
        if let last = lastCommitInstant, now - last < snapshotCoalesceInterval {
            pendingSnapshot = snapshot
            scheduleCoalescedCommit(after: snapshotCoalesceInterval - (now - last))
        } else {
            commitSnapshot(snapshot)
        }
    }

    /// The single commit path for stream snapshots. Identical snapshots
    /// are skipped without touching the `@Observable` arrays — the
    /// journal re-yields the full timeline on events that change nothing
    /// visible (the 11:22 log window shows long runs of "items 764→764"),
    /// and every no-op reassignment forced SwiftUI to re-walk the whole
    /// rendered window. The Equatable compare is O(N) worst case but
    /// costs far less than the render it prevents.
    private func commitSnapshot(_ snapshot: [TimelineItem]) {
        pendingSnapshot = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        lastCommitInstant = .now
        let before = items.count
        if !hasReceivedFirstSnapshot || snapshot != items {
            appliedSnapshotCount += 1
            applySnapshot(snapshot)
            Self.logger.diag("snapshot: items \(before)→\(snapshot.count) firstRenderable=\(self.firstRenderableItemID ?? "nil")")
        } else {
            Self.logger.diag("snapshot: unchanged (items=\(before)) — commit skipped")
        }
        // Clear any prior error once a fresh snapshot lands.
        self.error = nil
        // Flip on the first processed snapshot so the empty-state
        // placeholder gates correctly even when the snapshot itself
        // is empty.
        self.hasReceivedFirstSnapshot = true
        // Debounce the empty-state so a transient timeline clear
        // (sliding-sync reset) doesn't flash the "no messages yet"
        // placeholder.
        self.updateSettledEmpty(isEmpty: snapshot.isEmpty)
        // Content → empty is the signature of the local mirror being
        // wiped underneath an open view (snapshot_required: the server
        // declined to replay a too-large gap and the engine wiped the
        // store). Nothing else refetches an already-open chat —
        // paginate only fires on open and on scroll-up — so without
        // this the visible messages vanish and the view stays blank
        // forever.
        if before > 0 && snapshot.isEmpty {
            self.scheduleHistoryRefill()
        }
    }

    private func scheduleCoalescedCommit(after delay: Duration) {
        guard coalesceTask == nil else { return }
        coalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.coalesceTask = nil
            if let pending = self.pendingSnapshot {
                self.commitSnapshot(pending)
            }
        }
    }

    /// Commits whatever the coalescer is still holding, immediately.
    /// Called on stream end / stream error (so the last delivered state
    /// is never lost) and on `stop()` (so a cached VM's items are
    /// current when the room is next opened).
    func flushPendingSnapshot() {
        coalesceTask?.cancel()
        coalesceTask = nil
        if let pending = pendingSnapshot {
            commitSnapshot(pending)
        }
    }

    /// Rebuilds `rows` + `firstRenderableItemID` + `lastRenderableItemID`
    /// from the current `items`. Pulled out so a calendar change can
    /// also re-bucket without going through `applySnapshot`. Single
    /// pass — filter + bucket + first/last extraction in one walk so
    /// we don't traverse `items` four times.
    private func applyDerivedRecompute() {
        // Single pass over items so a 1000-item room doesn't walk
        // four arrays. Filter hidden items inline and capture the
        // first / last visible IDs as we go.
        var nextRows: [TimelineRow] = []
        nextRows.reserveCapacity(items.count + 4)
        var first: TimelineItem.ID?
        var last: TimelineItem.ID?
        var lastIsOwn = false
        var nextActivityLabel: String?
        currentDayInterval = nil
        for item in items {
            // The trailing activity indicator renders as a fixed footer
            // (below the scrollable timeline, above the composer), NOT a
            // row: as a row it became the scroll anchor during every bot
            // turn and vanished on completion — the most routine
            // dead-anchor source in the 2026-07-13 device traces. Kept
            // out of rows / first / last / day bucketing so it can never
            // be an anchor target or a stored scroll position.
            if case .activityIndicator(let label) = item.kind {
                nextActivityLabel = label
                continue
            }
            // `.stateChange` is the only hidden Kind today; both the
            // view-side `shouldRender` and the date-bucket logic
            // skip it. The "1 Jan 1970" separator bug came from
            // virtual stateChange items (timestamp = epoch zero)
            // participating in day bucketing — the filter here is
            // what kept that fix in place.
            if case .stateChange = item.kind { continue }
            // `.askUserAnswer` is pendingAsk bookkeeping (button
            // responses are hidden, matching Matron X) — keep it out
            // of the rows AND out of day bucketing, same reasoning as
            // the virtual stateChange filter above.
            if case .askUserAnswer = item.kind { continue }
            if first == nil { first = item.id }
            last = item.id
            lastIsOwn = item.isOwn
            // Day bucketing via a cached day interval, not
            // `startOfDay(for:)` per item — this recompute runs on every
            // committed snapshot, and in a 3,000-item room the per-item
            // calendar call dominated the pass (2026-08-05 sample:
            // multiple commits/sec while streaming). Consecutive items
            // almost always share a day, so the common case is two Date
            // compares. Deliberately half-open (`< end`): DateInterval's
            // own `contains` includes the end instant, which would
            // misfile an exactly-midnight timestamp into the previous day.
            let ts = item.timestamp
            let sameDay = currentDayInterval.map { ts >= $0.start && ts < $0.end } ?? false
            if !sameDay {
                currentDayInterval = calendar.dateInterval(of: .day, for: ts)
                nextRows.append(.separator(date: ts))
            }
            nextRows.append(.message(item))
        }
        self.rows = nextRows
        self.firstRenderableItemID = first
        self.lastRenderableItemID = last
        self.lastRenderableItemIsOwn = lastIsOwn
        self.activityLabel = nextActivityLabel
        self.rowAnchorIDsCache = nil
        recomputeWindow()
    }

    /// Backing memo for `rowAnchorIDs`. `@ObservationIgnored` — the set
    /// is consulted imperatively at scroll-restore moments, never from a
    /// `body`, so observation tracking would only add overhead.
    @ObservationIgnored private var rowAnchorIDsCache: Set<String>?

    /// Scratch state for `applyDerivedRecompute`'s day bucketing —
    /// reset at the top of every pass; a property only so the loop
    /// body reads clearly.
    @ObservationIgnored private var currentDayInterval: DateInterval?

    /// Rebuilds `windowedRows` from `rows` and the current window size.
    /// If the window cut lands mid-day, a leading date separator for the
    /// first visible message is re-synthesized so the window never opens
    /// on a context-free bubble (separator ids are deterministic
    /// per-day, so this is stable across recomputes).
    private func recomputeWindow() {
        var window = Array(rows.suffix(visibleWindowSize))
        if case .message(let firstItem)? = window.first {
            window.insert(.separator(date: firstItem.timestamp), at: 0)
        }
        self.windowedRows = window
    }

    /// Reveals older content when the user nears the visual top: grows
    /// the render window over already-loaded rows first (local,
    /// instant); only when the window already shows everything local
    /// does it fetch another page from the server. `isExtendingWindow`
    /// is held through the reveal's layout pass (the views anchor
    /// `.sizeChanges` to `.bottom` while it's up, which is what keeps
    /// the same rows on screen as content prepends above the viewport).
    public func extendHistoryWindow() async {
        if isExtendingWindow || isPaginatingBackward { return }
        if visibleWindowSize < rows.count {
            isExtendingWindow = true
            visibleWindowSize = min(rows.count, visibleWindowSize + Self.windowGrowthStep)
            Self.logger.diag("window extend → \(visibleWindowSize) rows (of \(rows.count) local)")
            recomputeWindow()
            // Hold the flag past the layout pass that applies the
            // grown window, so the bottom anchor covers the prepend.
            try? await Task.sleep(nanoseconds: 150_000_000)
            isExtendingWindow = false
            return
        }
        await paginateBackward()
        if visibleWindowSize < rows.count {
            isExtendingWindow = true
            visibleWindowSize = min(rows.count, visibleWindowSize + Self.windowGrowthStep)
            Self.logger.diag("window extend (post-paginate) → \(visibleWindowSize) rows (of \(rows.count) local)")
            recomputeWindow()
            try? await Task.sleep(nanoseconds: 150_000_000)
            isExtendingWindow = false
        }
    }

    /// Scroll-target id the views pin the viewport to across a
    /// history-window extension (non-animated `proxy.scrollTo`, anchor
    /// `.top`). The declarative `.sizeChanges` bottom anchor only covers
    /// the prepend while `isExtendingWindow` is up — at a few hundred
    /// rows the eager stack's layout pass outlives that hold, the
    /// viewport parks at the NEW head, and the "first row visible"
    /// trigger re-fires in a loop (2026-07-15 Mac trace: 240→1920 rows
    /// in 14s, contentH 180Kpt). Pinning an actual row makes the
    /// post-extend position — and therefore the trigger re-arm —
    /// deterministic instead of timing-based.
    ///
    /// Prefers the topmost VISIBLE row (zero visual jump); separator ids
    /// are skipped because they are day-keyed and relocate when the
    /// window head moves (the same-day separator synthesized at the old
    /// cut point re-materializes at the new head). Falls back to the
    /// pre-extend window's first message row, then nil (nothing safe to
    /// pin — callers skip the scrollTo and the anchor hold is the only
    /// cover, i.e. today's behaviour).
    nonisolated public static func historyPinTarget(visibleIDs: [String],
                                                    preExtendRows: [TimelineRow]) -> String? {
        if let id = visibleIDs.first(where: { !$0.hasPrefix("sep:") }) { return id }
        for row in preExtendRows {
            if case .message(let item) = row { return item.id }
        }
        return nil
    }

    /// First-paint window size on room entry. Switching rooms rebuilds
    /// the whole detail pane (`.id(id)`-keyed), and eagerly laying out
    /// `defaultWindowSize` heterogeneous rows in that one transaction is
    /// the bulk of the 0.5–1.2s switch stall traced on 2026-08-05.
    /// Painting a smaller tail first and growing to steady state right
    /// after the first frame splits the cost into two transactions, the
    /// second of which lands behind a bottom anchor (invisible at the
    /// tail).
    private static let entryWindowSize = 40

    /// Shrinks the window to `entryWindowSize` for a room's first paint.
    /// Called by the views at the top of their open sequence, BEFORE
    /// `start()`. Guarded to the untouched steady-state size so it never
    /// fights a window someone else grew — a scroll-position restore's
    /// `ensureWindowContains` (either order: our shrink then its grow,
    /// or its grow then our no-op) and a reader left up in history both
    /// keep their larger window.
    public func beginEntryWindow() {
        guard visibleWindowSize == Self.defaultWindowSize else { return }
        visibleWindowSize = Self.entryWindowSize
        recomputeWindow()
    }

    /// Grows the entry window to steady state after the first frame has
    /// painted. Same `isExtendingWindow` hold as `extendHistoryWindow`
    /// so the views' bottom anchor covers the prepend. No-op if the
    /// window already reached (or passed) steady state — e.g. a restore
    /// widened it first.
    public func settleEntryWindow() async {
        guard visibleWindowSize < Self.defaultWindowSize else { return }
        isExtendingWindow = true
        visibleWindowSize = Self.defaultWindowSize
        Self.logger.diag("entry window settle → \(self.visibleWindowSize) rows (of \(self.rows.count) local)")
        recomputeWindow()
        try? await Task.sleep(nanoseconds: 150_000_000)
        isExtendingWindow = false
    }

    /// Snaps the render window back to its steady-state size. Called by
    /// the views only at moments when no reader can be up in history —
    /// the jump-to-bottom tap and leaving the room while following the
    /// tail — so shrinking never removes rows anyone is looking at.
    public func resetHistoryWindow() {
        guard visibleWindowSize != Self.defaultWindowSize else { return }
        Self.logger.diag("window reset \(visibleWindowSize) → \(Self.defaultWindowSize) rows")
        visibleWindowSize = Self.defaultWindowSize
        recomputeWindow()
    }

    /// Grows the window (without animation concerns — called before the
    /// view scrolls) so a remembered scroll position outside the default
    /// tail window can actually be scrolled to on restore. Holds
    /// `isExtendingWindow` through the widening's layout pass exactly
    /// like `extendHistoryWindow` above: restore runs with follow-tail
    /// off, so without the flag the views' `.sizeChanges` anchor is
    /// `nil` while the prepend lands and the viewport can jump before
    /// the caller's `scrollTo` positions it (Bugbot, PR #18).
    public func ensureWindowContains(_ id: String) {
        let index = rows.lastIndex { row in
            if case .message(let item) = row { return item.id == id }
            return row.id == id
        }
        guard let index else { return }
        let needed = rows.count - index + 20
        if needed > visibleWindowSize {
            isExtendingWindow = true
            visibleWindowSize = needed
            recomputeWindow()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                isExtendingWindow = false
            }
        }
    }

    /// Pending scroll anchor for a TOC jump. Views observe this exactly
    /// like the existing scroll-restore flow (`pendingRestoreID` in
    /// ChatView.swift / MacChatView.swift): disengage tail-follow, call
    /// `ensureWindowContains(id)`, `proxy.scrollTo(id, anchor: .top)`,
    /// then `clearPendingFocus()`.
    public private(set) var pendingFocusID: String?

    /// Clears `pendingFocusID` once a view has consumed it and scrolled.
    public func clearPendingFocus() { pendingFocusID = nil }

    /// Navigates the transcript to the message nearest (at or before)
    /// `seq` — the summaries TOC panel's jump-to-message action. Pages
    /// history backward until the target region is loaded locally,
    /// giving up when `reachedHistoryStart` latches (see
    /// `paginateBackward()`'s doc comment for why that latch, not the
    /// SDK's own return value, is the source of truth); at that point it
    /// lands on the oldest row actually available rather than doing
    /// nothing.
    ///
    /// `paginateBackward()` guarantees progress-or-latch (each call
    /// either grows `items` or advances `consecutiveNoGrowthPaginates`
    /// toward `reachedHistoryStart`) — BUT only on the path that
    /// actually runs. Its reentrancy guard (`if isPaginatingBackward {
    /// return }`) early-returns with no suspension point, so if another
    /// call is already in flight (the near-top scroll listener,
    /// `scheduleHistoryRefill`) when a TOC jump lands, looping straight
    /// back into `await paginateBackward()` would spin the MainActor
    /// synchronously forever without ever yielding it to that in-flight
    /// call's own continuation. Each iteration below checks whether its
    /// `paginateBackward()` call actually moved anything; if not, it
    /// either yields (genuinely contended — give the in-flight call a
    /// turn, then retry) or bails to the oldest-row fallback (no
    /// contention and no movement — belt-and-braces exit in case the
    /// progress-or-latch guarantee above is ever violated).
    public func focus(seq: Int64) async {
        focusTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFocus(seq: seq)
        }
        focusTask = task
        await task.value
    }

    /// Backing task for `focus(seq:)` — see that method's doc comment for
    /// why a second call must supersede rather than race the first: two
    /// in-flight jumps would busy-yield against each other's
    /// `paginateBackward()` calls on the MainActor with no ordering
    /// guarantee over which one's `pendingFocusID` write wins. Cancelling
    /// the superseded task makes the outcome deterministic — but only
    /// because BOTH exits from the paginate loop below re-check
    /// `Task.isCancelled`: the loop-top check for the common case where
    /// cancellation lands mid-paginate, and a second check right after
    /// the loop for the uncontended `break` (no growth and nothing else
    /// in flight), which otherwise falls straight through to the
    /// unconditional `pendingFocusID` write below with no cancellation
    /// check in between. Only the most recent call's target is ever
    /// landed.
    private var focusTask: Task<Void, Never>?

    private func performFocus(seq: Int64) async {
        while nearestMessageID(atOrBefore: seq) == nil && !reachedHistoryStart {
            if Task.isCancelled { return }
            let beforeCount = items.count
            await paginateBackward()
            let madeProgress = items.count != beforeCount || reachedHistoryStart
            if !madeProgress {
                guard isPaginatingBackward else { break }
                await Task.yield()
            }
        }
        // Every exit from the loop above — including the uncontended
        // `break` — must re-check: a superseded task that breaks out
        // would otherwise land its fallback target over the newer call's.
        if Task.isCancelled { return }
        let target = nearestMessageID(atOrBefore: seq) ?? oldestMessageID()
        guard let target else { return }
        ensureWindowContains(target)
        pendingFocusID = target
    }

    /// Latest `rows` message id whose seq is `<= seq`, or nil if every
    /// loaded message postdates it. `rows` is ascending (oldest first —
    /// see `applyDerivedRecompute`), so the scan can stop at the first
    /// row past the target.
    private func nearestMessageID(atOrBefore seq: Int64) -> String? {
        var best: String?
        for row in rows {
            guard case .message(let item) = row, let rowSeq = Int64(item.id) else { continue }
            if rowSeq <= seq { best = item.id } else { break }
        }
        return best
    }

    /// The oldest loaded message row's id — the fallback landing spot
    /// when the target region never loads (history genuinely doesn't
    /// reach that far back).
    private func oldestMessageID() -> String? {
        for row in rows {
            if case .message(let item) = row, Int64(item.id) != nil { return item.id }
        }
        return nil
    }

    /// `true` while a `paginateBackward()` call is in flight — and,
    /// crucially, until the paginated snapshot has been APPLIED (the call
    /// awaits the items stream delivery before returning). The views
    /// lean on that guarantee: while reading history they switch the
    /// scroll engine's `.sizeChanges` anchor to `.bottom` for the
    /// duration of a paginate, which is what keeps the same rows on
    /// screen when the fetched page prepends above the viewport. Also
    /// guards re-entry and drives the "loading earlier…" pill.
    public private(set) var isPaginatingBackward: Bool = false
    /// Flips to `true` once we've observed enough consecutive
    /// zero-growth paginate calls to be confident the SDK genuinely has
    /// no more history to surface. Setting this stops further paginate
    /// triggers from the views' near-top scroll listener — without it,
    /// hovering near the head fires paginate on every geometry change,
    /// hammering the SDK for no result.
    /// Empirical: matrix-rust-sdk's `paginateBackwards` returns `false`
    /// (more events might exist) even when /messages has no more events
    /// for this user, so we can't trust the SDK signal alone — needed
    /// the consecutive-zero-growth heuristic. See the threshold const.
    public private(set) var reachedHistoryStart: Bool = false
    /// Counts consecutive paginate calls that produced zero new items.
    /// When this hits `noGrowthLimitForReachedStart`, we flip
    /// `reachedHistoryStart`. Reset to 0 on any growth.
    private var consecutiveNoGrowthPaginates: Int = 0
    /// How many zero-growth paginates before we declare history-start.
    /// 2 is enough to filter the one-shot spurious result on a freshly-
    /// opened timeline (see `paginateBackward` doc-comment) without
    /// requiring a long stall before we stop hammering the SDK.
    private static let noGrowthLimitForReachedStart = 2
    /// Maximum time to wait after `timeline.paginateBackward` returns
    /// for `timeline.items()` to deliver a snapshot containing the new
    /// events. The SDK runs the actual /messages fetch + decrypt +
    /// dedup pipeline asynchronously and yields the new snapshot when
    /// it's ready — typically 100-500ms on a warm cache, longer if a
    /// network round-trip is involved. 2.5s gives realistic networks
    /// headroom while keeping the no-growth verdict timely enough that
    /// a genuine end-of-history doesn't spin the user.
    private static let snapshotWaitTimeout: TimeInterval = 2.5
    /// Poll interval for the snapshot-arrival wait. Short enough that
    /// the loop reacts within a SwiftUI frame of the snapshot landing.
    private static let snapshotPollInterval: UInt64 = 50_000_000  // 50ms
    /// Flips to `true` after `start()` processes its first snapshot
    /// (even if that snapshot is empty) or the upstream stream finishes
    /// without yielding. The empty-state placeholder gates on this so
    /// it doesn't flash during the initial sliding-sync warm-up:
    /// `items.isEmpty` ambiguously means both "still loading" and
    /// "settled empty room" until we've definitively seen one snapshot.
    public private(set) var hasReceivedFirstSnapshot: Bool = false
    /// True only once the timeline has been CONTINUOUSLY empty for
    /// `emptyPlaceholderGraceMs`. The empty-state placeholder gates on
    /// this rather than raw `items.isEmpty`, because the matrix-rust-sdk
    /// timeline can transiently clear and repopulate within a sync tick
    /// (a sliding-sync reset against a live homeserver delivers a bare
    /// `Clear` then re-`Append`s) — applying that empty snapshot directly
    /// flashed "no messages yet" until the events came back. Debouncing
    /// the empty→settled transition rides those resets; a genuinely empty
    /// room stays empty past the grace and still surfaces the placeholder.
    public private(set) var settledEmpty: Bool = false
    /// Grace window before an empty timeline counts as settled-empty.
    /// `var` so tests can shorten it; ~400ms comfortably covers a
    /// sliding-sync clear+repopulate without a perceptible delay before a
    /// genuinely empty room shows its placeholder.
    var emptyPlaceholderGraceMs: Int = 400
    private var emptyDebounceTask: Task<Void, Never>?
    /// True from app-foreground (`handleForeground`) until the timeline
    /// re-populates or the re-sync ceiling elapses. While set, the empty
    /// placeholder is suppressed: returning from background tears the
    /// timeline down to empty and rebuilds it over SECONDS (the encrypted
    /// SDK store is sealed under file protection while locked, sync pauses,
    /// then a full re-sync clears+re-appends) — far longer than
    /// `emptyPlaceholderGraceMs`, so the debounce alone would flash
    /// "no messages yet" mid-resync.
    private var isResuming = false
    /// Ceiling on the resume-suppression window. A re-sync shorter than
    /// this never flashes the placeholder; content arrival ends the window
    /// early. Only a genuinely-empty room waits the full ceiling before its
    /// placeholder shows — generous on purpose (re-sync over a poor mobile
    /// link can take several seconds). `var` for tests.
    var resumeGraceMs: Int = 10_000
    private var resumeTask: Task<Void, Never>?
    /// Cache of `mxc://` URL → resolved SwiftUI `Image`. Populated lazily by
    /// `image(for:)` so SwiftUI can re-render the row once the bytes arrive.
    /// Backed by an `LRUCache` (capped at `mediaCacheLimit`) so a long
    /// session in a media-heavy room can't grow this set without bound
    /// (QA finding #4). The value-type `LRUCache` lives directly on the
    /// view-model — `@MainActor` isolation gives us the required
    /// single-threaded mutating-get access without extra synchronisation.
    /// Values are `SizedImage` (image + native pixel size) rather than a
    /// bare `Image` because `Image` is opaque — the Mac fullscreen viewer
    /// needs the bitmap's resolution to size its sheet without upscaling.
    private var resolvedImages: LRUCache<URL, SizedImage> = LRUCache(limit: ChatViewModel.mediaCacheLimit)
    /// URLs whose fetch completed but the bytes failed to decode into a
    /// SwiftUI `Image`. Without this, `image(for:)` would loop forever:
    /// the call returns nil → `@Observable` re-renders → `image(for:)`
    /// is called again → cache miss, no in-flight guard → re-fetch.
    /// Bounded by the same LRU cap as `resolvedImages` so a session that
    /// hits many decode failures (e.g. broken thumbnails) can't leak
    /// either (QA finding #4). Stores `()` — only the key membership
    /// matters.
    private var failedRequests: LRUCache<URL, Void> = LRUCache(limit: ChatViewModel.mediaCacheLimit)

    private let timeline: TimelineService
    private let media: MediaService
    private var observationTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var summaryEntriesTask: Task<Void, Never>?
    /// Tracks `mxc://` URLs with a request already in flight so we don't
    /// fire duplicate fetches on every SwiftUI re-render.
    private var inFlightRequests: Set<URL> = []

    /// File-attachment URLs whose blob download is currently in flight.
    /// `@Observable` state — the timeline's file chip reads it via
    /// `isDownloadingFile(_:)` to draw a spinner, because a large PDF
    /// takes double-digit seconds to pull through the journal server and
    /// a tap with no visible reaction reads as a dead tap.
    private var downloadingFiles: Set<URL> = []
    /// Attachment URL → temp file already written by `writeTempFile`.
    /// Re-opening an attachment must not re-download a multi-MB blob the
    /// user just waited for.
    private var fileTempURLs: [URL: URL] = [:]
    /// Media URLs (file OR image attachments) whose fetch returned a
    /// definitive 404 — reaped server-side, permanently gone. Unbounded
    /// like `fileTempURLs`, and bounded in practice by attachments the
    /// user's session has actually tried to fetch.
    private var unavailableMedia: Set<URL> = []

    /// Event IDs of ask-user prompts the user has answered (or
    /// dismissed) on THIS device, persisted across launches under
    /// `matron.answeredPrompts.<roomID>` so push re-decryption /
    /// re-opening the room can't re-pop an already-answered sheet.
    /// Cross-DEVICE answers are detected from the timeline instead —
    /// see `pendingAsk()`.
    private var answeredPromptIDs: Set<String>

    private var answeredPromptsDefaultsKey: String {
        "matron.answeredPrompts.\(roomID)"
    }

    /// Answers agent-chat consent cards. Optional so the many call sites
    /// that don't render them (tests, previews) construct unchanged; a card
    /// with no answerer renders read-only rather than offering buttons that
    /// would do nothing — the exact failure this whole change exists to fix.
    private let agentChat: (any AgentChatAnswering)?

    /// Consent cards answered on THIS device, keyed by journal seq, with the
    /// decision made. Persisted under `matron.agentChatAnswers.<roomID>`.
    ///
    /// Unlike an ask-user reply, answering a consent card is an HTTP call and
    /// produces no journal event — so there is nothing in the timeline to
    /// read the outcome back from, on this device or any other. Local memory
    /// is the only thing standing between the user and a card that looks
    /// unanswered forever.
    private var agentChatAnswers: [String: String]

    private var agentChatAnswersDefaultsKey: String {
        "matron.agentChatAnswers.\(roomID)"
    }

    /// Live per-card state while a call is in flight or has failed. Not
    /// persisted: a send that was interrupted should come back answerable.
    private var agentChatTransientStates: [String: AgentChatCardState] = [:]

    public init(roomID: String, timeline: TimelineService, media: MediaService,
                agentChat: (any AgentChatAnswering)? = nil) {
        self.roomID = roomID
        self.timeline = timeline
        self.media = media
        self.agentChat = agentChat
        let stored = UserDefaults.standard.stringArray(forKey: "matron.answeredPrompts.\(roomID)") ?? []
        self.answeredPromptIDs = Set(stored)
        self.agentChatAnswers = UserDefaults.standard
            .dictionary(forKey: "matron.agentChatAnswers.\(roomID)") as? [String: String] ?? [:]
    }

    // MARK: Agent-chat consent cards

    /// Render state for one consent card. A remembered decision wins over
    /// everything: once answered, the card is history.
    public func agentChatState(_ eventID: String) -> AgentChatCardState {
        if let decision = agentChatAnswers[eventID] {
            if decision == "expired" { return .expired }
            return .answered(approved: decision == AgentChatDecision.approve.rawValue)
        }
        if let transient = agentChatTransientStates[eventID] { return transient }
        // No answerer wired: show the card, but don't offer buttons that
        // cannot resolve it.
        return agentChat == nil ? .expired : .idle
    }

    /// Answers a consent card. The ONLY path that resolves one — a reply
    /// into the room never reaches the parked row.
    ///
    /// A 409 means the row stopped awaiting an answer between the card being
    /// drawn and the tap (answered on another device, or 24h expired); that
    /// is not an error the user can act on, so it settles the card as
    /// expired rather than showing a failure they'd only retry.
    public func answerAgentChat(
        eventID: String, request: AgentChatRequest, decision: AgentChatDecision
    ) async {
        guard let agentChat, agentChatAnswers[eventID] == nil else { return }
        if case .sending = agentChatState(eventID) { return }
        agentChatTransientStates[eventID] = .sending
        do {
            try await agentChat.answerAgentChat(
                roomID: request.roomID, targetDeviceID: request.targetDeviceID,
                decision: decision)
            rememberAgentChatAnswer(eventID, decision.rawValue)
        } catch JournalAPIError.conflict {
            rememberAgentChatAnswer(eventID, "expired")
        } catch {
            agentChatTransientStates[eventID] = .failed(Self.describeAgentChatError(error))
        }
    }

    private func rememberAgentChatAnswer(_ eventID: String, _ value: String) {
        agentChatTransientStates.removeValue(forKey: eventID)
        agentChatAnswers[eventID] = value
        UserDefaults.standard.set(agentChatAnswers, forKey: agentChatAnswersDefaultsKey)
    }

    static func describeAgentChatError(_ error: Error) -> String {
        switch error {
        case JournalAPIError.transport:
            return "Couldn't reach the server — check your connection and try again."
        case JournalAPIError.notFound:
            return "That request is no longer on the server."
        default:
            return "The server refused that answer."
        }
    }

    /// Debounces the empty → `settledEmpty` transition (see `settledEmpty`).
    /// A non-empty snapshot clears it immediately (and ends any resume
    /// window — content is back); an empty one schedules the flip after the
    /// grace, so a transient clear that repopulates first never surfaces
    /// the placeholder. While `isResuming` (just returned from background),
    /// an empty snapshot is held — re-sync may still be repopulating, and
    /// `handleForeground`'s ceiling is what eventually trusts an empty
    /// room. `internal` so tests can drive the state machine directly.
    func updateSettledEmpty(isEmpty: Bool) {
        emptyDebounceTask?.cancel()
        emptyDebounceTask = nil
        guard isEmpty else {
            settledEmpty = false
            isResuming = false
            resumeTask?.cancel()
            resumeTask = nil
            return
        }
        if isResuming { return }
        let graceMs = emptyPlaceholderGraceMs
        emptyDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(graceMs))
            guard !Task.isCancelled, let self else { return }
            self.settledEmpty = true
        }
    }

    /// Call when the app returns to the foreground (scenePhase → `.active`
    /// from background). Enters the resume window: hides the empty
    /// placeholder and suppresses it until the timeline re-populates (a
    /// content snapshot ends the window) or the `resumeGraceMs` ceiling
    /// elapses and the room is confirmed still empty. Without this, a
    /// background→foreground timeline rebuild flashes "no messages yet"
    /// because the rebuild's empty window outlasts `emptyPlaceholderGraceMs`.
    public func handleForeground() {
        settledEmpty = false
        emptyDebounceTask?.cancel()
        emptyDebounceTask = nil
        isResuming = true
        let ceilingMs = resumeGraceMs
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ceilingMs))
            guard !Task.isCancelled, let self else { return }
            // Re-sync window elapsed — trust the current state now.
            self.isResuming = false
            self.updateSettledEmpty(isEmpty: self.items.isEmpty)
        }
    }

    /// Monotonic token identifying the current observation run; bumped by
    /// every `start()`. Views that share a cached VM record it after their
    /// `start()` and pass it to `stop(ifGeneration:)` on disappear, so a
    /// stale view instance's teardown can never cancel a successor's
    /// freshly-started stream (Mac same-room remount hazard).
    public private(set) var observationGeneration: Int = 0

    /// Starts observing the timeline. Returns *after* the first snapshot has
    /// been applied (or the stream has finished without yielding), so callers
    /// that chain `markAsRead()` after `start()` mark the actual head of the
    /// timeline as read instead of marking an empty room as read. Returns
    /// the long-lived observation `Task` so tests can still
    /// `await task.value` to know when the stream has fully drained — the
    /// fake stream finishes after yielding queued snapshots, the live
    /// stream stays open until `stop()` cancels it.
    ///
    /// Round 3 bugbot finding #3: previously `start()` returned the task
    /// synchronously and the View's `.task { viewModel.start(); await
    /// viewModel.markAsRead() }` raced — `markAsRead()` fired before the
    /// observation Task had a chance to apply the first snapshot, so on
    /// first open the SDK marked "no events" as read and unread counts
    /// were never cleared.
    @discardableResult
    public func start() async -> Task<Void, Never> {
        observationGeneration += 1
        observationTask?.cancel()
        // Fresh subscription — drop stale settled-empty state before the
        // new stream's snapshots arrive. Deliberately does NOT touch
        // `isResuming` / `resumeTask`: a background→foreground resume can
        // be in flight when `start()` runs (or runs just before it), and
        // clobbering it here would undo the suppression and flash the
        // placeholder during the rebuild (bugbot "Start clears resume
        // window"). The resume window ends on its own — content arrival or
        // the ceiling — and a fresh VM has it cleared already.
        settledEmpty = false
        emptyDebounceTask?.cancel()
        emptyDebounceTask = nil
        // Reset the snapshot coalescer so the NEW stream's first snapshot
        // commits immediately — `start()`'s "returns after the first
        // snapshot has been applied" contract must hold on a warm remount
        // too, not just on a fresh VM.
        flushPendingSnapshot()
        lastCommitInstant = nil
        // Held meters are only as fresh as the engine's status replay
        // cache: on re-subscribe the engine yields the cached value back
        // immediately when it's still valid, and after a mirror wipe (which
        // clears that cache) the meters correctly start blank instead of
        // presenting pre-wipe usage as current.
        sessionStatus = nil
        let timeline = self.timeline
        // Box wrapping a single-shot CheckedContinuation. The observation
        // Task resumes it on the first snapshot processed (or on stream
        // completion if no snapshot ever arrives). All other paths — late
        // snapshots, stream end after the first snapshot — are no-ops.
        // Boxed via a class so the value-type continuation can be flipped
        // from inside the long-lived Task without value-type copy issues.
        let firstSignal = FirstSnapshotSignal()
        let task = Task { [weak self] in
            do {
                for try await snapshot in timeline.items() {
                    guard let self else {
                        firstSignal.fireOnce()
                        return
                    }
                    await MainActor.run {
                        self.receiveSnapshot(snapshot)
                    }
                    firstSignal.fireOnce()
                }
            } catch {
                // Stream threw — surface the message so the View can
                // render an overlay instead of an infinite spinner
                // (QA finding #10). Logged un-gated: a dead stream under
                // an open view is exactly the "panel went blank/stale"
                // evidence we need persisted after the fact.
                Self.logger.warning("timeline stream threw under an open view: \(error.localizedDescription, privacy: .public)")
                MatronFileLog.append("timeline stream threw under an open view: \(error.localizedDescription)")
                let message = error.localizedDescription
                if let self {
                    await MainActor.run {
                        // Flush BEFORE recording the error — a commit
                        // clears `error`, so the reverse order would
                        // swallow the message we're about to surface.
                        self.flushPendingSnapshot()
                        self.error = message
                    }
                }
            }
            // Stream finished (or threw) without yielding any snapshot —
            // still resume so the caller of `start()` doesn't hang on a
            // room that the live timeline never populates (or a fake set
            // up with no `snapshotsToEmit`). Flip the first-snapshot
            // flag too so the empty-state placeholder isn't stuck
            // hidden on rooms whose live timeline never warms up.
            //
            // Un-gated log: a non-cancelled finish means live updates are
            // dead for this view — the signature of a "panel froze/blanked"
            // report. Cancellation (view closed) is routine; skip it.
            if !Task.isCancelled {
                Self.logger.warning("timeline stream finished under an open view (items=\(self?.items.count ?? -1))")
                MatronFileLog.append("timeline stream finished under an open view (items=\(self?.items.count ?? -1))")
            }
            if let self {
                await MainActor.run {
                    // Stream over — apply any snapshot still held by the
                    // coalescer so the final state reflects the last thing
                    // the stream delivered. Tests lean on this: they await
                    // the observation task's completion and then assert on
                    // `items`, and a trailing coalesced snapshot must not
                    // still be pending at that point.
                    self.flushPendingSnapshot()
                    self.hasReceivedFirstSnapshot = true
                    // A room whose live timeline never warmed up is
                    // genuinely empty — let the placeholder settle in.
                    self.updateSettledEmpty(isEmpty: self.items.isEmpty)
                }
            }
            firstSignal.fireOnce()
        }
        observationTask = task

        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await update in timeline.sessionStatus() {
                guard let self else { return }
                await MainActor.run {
                    var merged = self.sessionStatus ?? SessionStatus()
                    merged.apply(update)
                    self.sessionStatus = merged
                }
            }
        }

        // Deliberately NOT reset before the stream re-arms: on a warm
        // remount mid-turn the observation re-emits the current state
        // immediately, and a false-then-true blip would flicker the stop
        // button on every chat switch.
        sessionStateTask?.cancel()
        sessionStateTask = Task { [weak self] in
            for await state in timeline.sessionState() {
                guard let self else { return }
                await MainActor.run {
                    let running = state == "running"
                    if self.isTurnRunning != running { self.isTurnRunning = running }
                }
            }
        }

        summaryEntriesTask?.cancel()
        summaryEntriesTask = Task { [weak self] in
            guard let stream = self?.timeline.summaryEntriesStream() else { return }
            for await entries in stream {
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.summaryEntries = entries
                }
            }
        }

        await firstSignal.wait()
        return task
    }

    /// Generation-guarded `stop()`: no-op unless `generation` still names
    /// the current observation. Use from views sharing a cached VM — an
    /// unconditional `stop()` in `onDisappear` can fire AFTER a same-room
    /// successor view's `start()` and kill its live stream.
    public func stop(ifGeneration generation: Int) {
        guard generation == observationGeneration else { return }
        stop()
    }

    /// Cancels the in-flight observation task. Call from `View.onDisappear`
    /// to release the AsyncStream's continuation. Idempotent.
    public func stop() {
        // Land any coalesced snapshot before tearing the stream down —
        // the VM outlives the view (ChatVMCache) and its items must be
        // current when the room is next opened.
        flushPendingSnapshot()
        observationTask?.cancel()
        observationTask = nil
        statusTask?.cancel()
        statusTask = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        summaryEntriesTask?.cancel()
        summaryEntriesTask = nil
        emptyDebounceTask?.cancel()
        emptyDebounceTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        historyRefillTask?.cancel()
        historyRefillTask = nil
        focusTask?.cancel()
        focusTask = nil
    }

    private var historyRefillTask: Task<Void, Never>?

    /// One-shot refetch of the newest history page after the timeline
    /// went content → empty (see the call site in `start()`'s snapshot
    /// loop). Resets the end-of-history verdict first: a wipe invalidates
    /// it, and a stale `reachedHistoryStart == true` would short-circuit
    /// the very paginate this exists to run. Single-flight so a burst of
    /// empty snapshots (store fire + overlay sweep) queues one refill.
    private func scheduleHistoryRefill() {
        guard historyRefillTask == nil else { return }
        reachedHistoryStart = false
        consecutiveNoGrowthPaginates = 0
        // Un-gated (notice, not diag): this fires at most once per mirror
        // wipe and is the pivotal breadcrumb for any "chat went blank"
        // report — it must be in the persisted log even with MatronDebug off.
        Self.logger.breadcrumb("timeline went empty under an open view — refetching newest page")
        historyRefillTask = Task { [weak self] in
            await self?.paginateBackward()
            self?.historyRefillTask = nil
        }
    }

    public func paginateBackward() async {
        // Re-entrancy guard + reached-history-start short-circuit. The
        // `reachedHistoryStart` flag isn't driven by the SDK's `Bool`
        // return — that signal is unreliable in matrix-rust-sdk 26.4.1
        // (returns `false` even when `/messages` is genuinely
        // returning duplicates / nothing the Timeline can surface).
        // Instead we count consecutive zero-growth paginate calls and
        // flip the flag after `noGrowthLimitForReachedStart`.
        if isPaginatingBackward {
            Self.logger.diag("paginateBackward: skip — already in flight")
            return
        }
        if reachedHistoryStart {
            Self.logger.diag("paginateBackward: skip — reachedHistoryStart")
            return
        }
        isPaginatingBackward = true
        defer { isPaginatingBackward = false }
        let beforeCount = items.count
        Self.logger.diag("paginateBackward: enter (items=\(beforeCount))")
        do {
            let sdkReachedStart = try await timeline.paginateBackward(requestSize: 30)
            Self.logger.diag("paginateBackward: SDK returned reachedStart=\(sdkReachedStart)")
            // Wait for the timeline.items() AsyncStream to deliver the
            // new snapshot. The SDK fetches /messages over the network,
            // decrypts, dedups, then yields — easily 200-1000ms of
            // pipeline before the new items show up in `self.items`.
            // The previous fixed 50ms wait was a guess and lost on
            // every realistic round-trip; a few back-to-back lost
            // checks tipped `consecutiveNoGrowthPaginates` over the
            // threshold and flipped `reachedHistoryStart=true`
            // permanently, bricking scroll-up after the first paginate.
            // Poll instead: short-circuit the moment items grows, and
            // only count "no growth" if we've actually waited long
            // enough for a snapshot to plausibly arrive.
            let deadline = Date().addingTimeInterval(Self.snapshotWaitTimeout)
            while items.count == beforeCount && Date() < deadline {
                // A superseded focus jump (or a room switch) cancels us mid-wait:
                // `try? await Task.sleep` would then return instantly and spin this
                // poll on the MainActor until the deadline. Leave instead — a
                // cancelled wait is no evidence about history depth, so it must not
                // reach the no-growth accounting below either.
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: Self.snapshotPollInterval)
            }
            let grew = items.count > beforeCount
            Self.logger.diag("paginateBackward: done (items: \(beforeCount)→\(self.items.count), grew=\(grew))")
            if grew {
                consecutiveNoGrowthPaginates = 0
            } else {
                consecutiveNoGrowthPaginates += 1
                if consecutiveNoGrowthPaginates >= Self.noGrowthLimitForReachedStart {
                    reachedHistoryStart = true
                    Self.logger.diag("paginateBackward: reached history start (no growth across \(Self.noGrowthLimitForReachedStart) consecutive calls)")
                }
            }
        } catch {
            Self.logger.error("paginateBackward: threw — \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    public func markAsRead() async {
        try? await timeline.markAsRead()
    }

    /// In-flight latch for `sendCommand` — repeated taps on a Compact
    /// affordance (banner or gauge button) must not each queue another
    /// bare /compact while the first is still sending.
    private var commandInFlight = false

    /// Sends a command on the user's behalf — the Compact buttons next
    /// to the context gauge (Mac header, iOS session sheet) wire here
    /// with "/compact", and the floating `StopTurnButton` with "!esc".
    /// Deliberately bypasses `ComposerViewModel`:
    /// a button press must not disturb the composer's draft text, staged
    /// attachments, or Up-arrow history. The command lands in the
    /// timeline as an ordinary own-message, so delivery (and the
    /// bridge's response) is visible in the chat itself; a failure is
    /// logged rather than surfaced because the button has no error UI
    /// and the missing echo already tells the user nothing went out.
    public func sendCommand(_ command: String) async {
        guard !commandInFlight else { return }
        commandInFlight = true
        defer { commandInFlight = false }
        do {
            try await timeline.sendText(command)
        } catch {
            Self.logger.warning("sendCommand \(command, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Retry handler for own-messages whose send state is `.failed` or
    /// `.queued` — the timeline's tap-to-retry affordance. Requeues the
    /// message's outbox row and forces a send attempt (or a reconnect
    /// nudge when offline); the echo's state updates flow back through
    /// the normal `items()` snapshot stream.
    public func retrySend(itemID: String) {
        Self.logger.info("retrySend tapped for item=\(itemID, privacy: .public)")
        let timeline = self.timeline
        Task { await timeline.retrySend(itemID: itemID) }
    }

    /// Discards an unsent (queued/failed) own-message — the escape hatch
    /// for a message the user no longer wants delivered.
    public func discardSend(itemID: String) {
        Self.logger.info("discardSend tapped for item=\(itemID, privacy: .public)")
        let timeline = self.timeline
        Task { await timeline.discardSend(itemID: itemID) }
    }

    /// Mac toolbar refresh button + ⌘R menu shortcut wire here. Re-paginating
    /// from the head re-fetches the latest events; on Mac there's no
    /// pull-to-refresh gesture so this is the only manual-refresh path.
    public func refresh() async {
        await paginateBackward()
    }

    /// Returns the cached SwiftUI `Image` for an `mxc://` URL, or `nil` and
    /// kicks off a background fetch. The fetch updates `resolvedImages` on
    /// completion, which triggers `@Observable` re-evaluation so the row
    /// can render the resolved image. Idempotent: repeat calls for the
    /// same URL coalesce to a single in-flight request, and URLs whose
    /// fetch returned non-decodable bytes are remembered so we don't loop.
    public func image(for url: URL) -> Image? {
        if let cached = resolvedImages[url] { return cached.image }
        if unavailableMedia.contains(url) { return nil }
        if failedRequests.contains(url) { return nil }
        guard !inFlightRequests.contains(url) else { return nil }
        inFlightRequests.insert(url)
        Task { [weak self, media] in
            // `fetchOutcome`, not `sizedImage(for:)` — a reaped image's 404
            // must land in `unavailableMedia` (permanent, drives the
            // "Image expired" placeholder) rather than the retry-bounded
            // `failedRequests` LRU (Bugbot, PR #139).
            let outcome = await media.fetchOutcome(mxcURL: url)
            let img: SizedImage? = {
                if case .data(let bytes) = outcome { return SizedImage.decode(bytes) }
                return nil
            }()
            guard let self else { return }
            await MainActor.run {
                if let img {
                    self.resolvedImages[url] = img
                } else if case .notFound = outcome {
                    self.unavailableMedia.insert(url)
                } else {
                    // `()` — only the key membership matters; `LRUCache`
                    // doesn't expose an insert-key-only API so the value
                    // is the unit type.
                    self.failedRequests[url] = ()
                }
                self.inFlightRequests.remove(url)
            }
        }
        return nil
    }

    /// Fetches bytes for an `mxc://` attachment URL and writes them to
    /// a temporary file under `FileManager.default.temporaryDirectory`,
    /// returning the URL. Used by the fullscreen-preview path on file
    /// attachments — iOS hands the temp URL to `ShareLink`, Mac hands
    /// it to `NSWorkspace.shared.open`. Returns `nil` if the fetch
    /// fails so the View can fall back to a no-op (better than
    /// presenting a broken preview).
    ///
    /// The temp filename preserves the original `filename` so the
    /// downstream preview / share UI shows a sensible label instead
    /// of a UUID. Files written here are *not* cleaned up — the OS
    /// reaps the temp directory between launches and the size cost
    /// is bounded by attachments the user has actively opened.
    /// Whether a file attachment's blob download is currently in flight —
    /// drives the timeline chip's spinner. `@Observable` re-evaluates the
    /// row when `downloadingFiles` changes, so the spinner appears on tap
    /// and clears when the open/preview fires.
    public func isDownloadingFile(_ mxcURL: URL) -> Bool {
        downloadingFiles.contains(mxcURL)
    }

    /// Whether a fetch for this attachment came back 404 — the blob was
    /// reaped server-side (journal media reaper), which is permanent: blob
    /// ids are immutable. Drives the chip's "Expired" state for events that
    /// synced BEFORE the reap and so never carry the payload tombstone
    /// (`TimelineItem.Kind`'s `expired`) — the 404 on tap is how an
    /// already-synced client learns. Same row-invalidation channel as
    /// `isDownloadingFile`.
    public func isMediaUnavailable(_ mxcURL: URL) -> Bool {
        unavailableMedia.contains(mxcURL)
    }

    public func writeTempFile(mxcURL: URL, filename: String) async -> URL? {
        // Known-reaped blob: no request — the server already said 404 and
        // ids never come back.
        guard !unavailableMedia.contains(mxcURL) else { return nil }
        // Repeat open: serve the temp file written last time (the OS may
        // have reaped it between launches — fall through and re-download
        // if it's gone).
        if let cached = fileTempURLs[mxcURL],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        // Re-tap while the (multi-second) download is still running: a
        // no-op, not a second parallel download. The chip's spinner
        // (driven by `isDownloadingFile`) is the "hold on" signal.
        guard !downloadingFiles.contains(mxcURL) else { return nil }
        downloadingFiles.insert(mxcURL)
        defer { downloadingFiles.remove(mxcURL) }
        let data: Data
        switch await media.fetchOutcome(mxcURL: mxcURL) {
        case .data(let bytes):
            data = bytes
        case .notFound:
            // Permanent: flip the chip to Expired and stop re-fetching.
            unavailableMedia.insert(mxcURL)
            return nil
        case .failure:
            // Transient (network/auth): stay silent and retryable.
            return nil
        }
        // Namespace by a digest of the attachment URL: distinct
        // attachments routinely share a display filename ("report.pdf"
        // from two rooms), and a shared flat directory would let the
        // second download clobber the first — after which the temp-file
        // cache above serves the wrong attachment's bytes (Bugbot,
        // PR #138). The human-friendly basename is preserved for the
        // share/preview label; uniqueness lives in the parent directory.
        let urlDigest = SHA256.hash(data: Data(mxcURL.absoluteString.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("matron-attachments", isDirectory: true)
            .appendingPathComponent(urlDigest, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            // Sanitise the filename: strip directory separators and
            // parent-dir traversal so a malicious sender can't craft
            // `../../.ssh/authorized_keys` to escape the temp dir. The
            // filename arrives from Matrix event metadata, which is
            // attacker-controllable. We keep the basename for human-
            // friendly preview / share labels, falling back to a UUID
            // if sanitisation produces an empty string.
            let safeFilename = Self.sanitisedAttachmentFilename(filename)
            let dest = dir.appendingPathComponent(safeFilename)
            try data.write(to: dest, options: .atomic)
            fileTempURLs[mxcURL] = dest
            return dest
        } catch {
            Self.logger.error("writeTempFile failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Read-only view of the resolved-image cache for a single URL. Wraps
    /// the underlying `LRUCache`'s `mutating get` so external observers
    /// (tests, debug overlays) can check what's resolved without holding
    /// a write reference to the view-model. Touching a URL through this
    /// accessor does promote it to MRU on the underlying LRU — the same
    /// behaviour `image(for:)` produces, so observation stays aligned
    /// with rendering.
    public func resolvedImage(for url: URL) -> Image? { resolvedImages[url]?.image }

    /// Native pixel size of an already-resolved image, or `nil` while the
    /// fetch is still outstanding (or failed). Passive — never triggers a
    /// fetch; callers pair it with `image(for:)`, which does. The Mac
    /// fullscreen viewer uses this to open its sheet at the image's
    /// natural on-screen size instead of a fixed small frame.
    public func imagePixelSize(for url: URL) -> CGSize? { resolvedImages[url]?.pixelSize }

    /// Strip path-traversal and directory-separator components from a
    /// Matrix-event-attached filename. Inputs that reduce to an empty
    /// string (all-`/`, `..`, hidden-only) fall back to a UUID so we
    /// never pass `/` to `appendingPathComponent` or write a hidden
    /// file by accident. Test seam: `internal` so
    /// `ChatViewModelTests` can assert the contract directly without
    /// rendering or hitting disk.
    static func sanitisedAttachmentFilename(_ raw: String) -> String {
        // Last path component drops any leading directory tree the
        // sender embedded — `Foundation.URL`-style normalisation
        // collapses `..` / `.` segments along the way.
        let trimmed = (raw as NSString).lastPathComponent
        // Replace remaining separators (rare, but `:` on macOS
        // historically and `\` on Windows-style senders) with `_`.
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "_")
                              .replacingOccurrences(of: ":", with: "_")
        // Reject empty or `.`/`..`-only strings — fall back to a UUID
        // so the write always lands inside the attachments dir.
        let stripped = cleaned.trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty || stripped == "." || stripped == ".." {
            return UUID().uuidString
        }
        return stripped
    }

    // MARK: - Ask-user prompts (Phase 5 Task 11)

    /// The most recent ask-user prompt the user still needs to answer,
    /// or nil. Views key the sheet presentation off this from
    /// `.onChange(of: viewModel.items)`.
    ///
    /// A prompt counts as answered when ANY of:
    /// - it was answered/dismissed on this device
    ///   (`answeredPromptIDs`, UserDefaults-persisted);
    /// - the timeline contains a `chat.matron.button_response` for it
    ///   (`.askUserAnswer`) — covers the user's other devices, which
    ///   per-device bookkeeping can't see (Task 13's cross-platform
    ///   smoke test);
    /// - the timeline contains one of the user's own replies
    ///   (`m.in_reply_to`) targeting it — same cross-device story for
    ///   the `ask_user` text-reply channel.
    ///
    /// Already-expired prompts are skipped entirely: popping a sheet
    /// whose `awaitExpiry` would immediately dismiss it is just a
    /// flash of dead UI.
    public func pendingAsk() -> AskUserPromptContext? {
        persistVisibleAnswers()
        var answeredInTimeline: Set<String> = []
        for item in items {
            // `isOwn` on BOTH paths: a `button_response` / reply only
            // counts as OUR answer if it came from this Matrix user
            // (this device or another of ours — both `isOwn`). In a
            // multi-user room another member's button answer must NOT
            // suppress the prompt for us (bugbot "Others' button answers
            // dismiss sheet").
            if case .askUserAnswer(let promptID, _) = item.kind,
               !promptID.isEmpty, item.isOwn {
                answeredInTimeline.insert(promptID)
            }
            if item.isOwn, let target = item.inReplyToEventID {
                answeredInTimeline.insert(target)
            }
        }
        for item in items.reversed() {
            guard case .askUser(let id, let evt) = item.kind else { continue }
            if answeredPromptIDs.contains(id) { continue }
            if answeredInTimeline.contains(id) { continue }
            if let expiresAt = evt.expiresAt, Date.now >= expiresAt { continue }
            return AskUserPromptContext(id: id, event: evt)
        }
        return nil
    }

    /// Folds cross-device answers visible in the current timeline into
    /// the persisted `answeredPromptIDs` set, so a prompt resolved on
    /// another device (or here) stays resolved across later snapshots.
    ///
    /// The inline `AskUserCard` reads answered-state from the live
    /// timeline via `isPromptAnswered`. On a fresh timeline the
    /// encrypted answer event can lag decryption behind the prompt, and
    /// a transient sliding-sync snapshot can momentarily drop it; in
    /// that window `isPromptAnswered` flips back to `false`, so a
    /// resolved prompt looks unanswered again and accepts a duplicate
    /// reply (bugbot "Cross-device answers not persisted"). Folding the
    /// answer into the UserDefaults set the moment it's first seen makes
    /// the resolved state sticky. The old half-sheet folded inside
    /// `pendingAsk()` on every `items` change; the inline cards no
    /// longer call `pendingAsk()`, so the views drive this on `items`.
    ///
    /// Intersected with the prompts actually present: `answeredInTimeline`
    /// also holds the user's replies to ORDINARY messages, and persisting
    /// those would grow the defaults set without bound.
    public func persistVisibleAnswers() {
        var answeredInTimeline: Set<String> = []
        var promptIDsInTimeline: Set<String> = []
        for item in items {
            if case .askUserAnswer(let promptID, _) = item.kind,
               !promptID.isEmpty, item.isOwn {
                answeredInTimeline.insert(promptID)
            }
            if item.isOwn, let target = item.inReplyToEventID {
                answeredInTimeline.insert(target)
            }
            if case .askUser(let id, _) = item.kind {
                promptIDsInTimeline.insert(id)
            }
        }
        for id in answeredInTimeline.intersection(promptIDsInTimeline)
        where !answeredPromptIDs.contains(id) {
            markPromptAnswered(id)
        }
    }

    /// True if `eventID`'s ask-user prompt has been answered by US — on
    /// this device (persisted in `answeredPromptIDs`) or on another of
    /// our devices (an `isOwn` `button_response` or `m.in_reply_to` reply
    /// for it is in the current timeline). Another user's button answer
    /// in a multi-member room does NOT count (bugbot "Others' button
    /// answers dismiss sheet"). Distinct from `pendingAsk()`'s
    /// "should a prompt pop" test: this answers "is THIS prompt resolved",
    /// which the views use to decide whether an already-open sheet should
    /// close. Critically it does NOT key on `pendingAsk()` returning nil —
    /// a transient sliding-sync clear empties `items` momentarily, and an
    /// open sheet must not drop on that (bugbot "Ask sheet drops on
    /// clear") nor be yanked to a newer prompt (bugbot "New prompt
    /// replaces open sheet").
    public func isPromptAnswered(_ eventID: String) -> Bool {
        if answeredPromptIDs.contains(eventID) { return true }
        for item in items where item.isOwn {
            if case .askUserAnswer(let promptID, _) = item.kind, promptID == eventID {
                return true
            }
            if item.inReplyToEventID == eventID {
                return true
            }
        }
        return false
    }

    /// Called after a successful send (or explicit dismissal) so the
    /// prompt can't re-pop — push re-decryption can re-deliver the
    /// same event after the user already answered. Persisted per room.
    public func markPromptAnswered(_ eventID: String) {
        answeredPromptIDs.insert(eventID)
        UserDefaults.standard.set(Array(answeredPromptIDs), forKey: answeredPromptsDefaultsKey)
    }

    /// Builds the sheet ViewModel for a pending prompt. Factory lives
    /// here so the `TimelineService` stays private to this class —
    /// the Views never hold a service reference directly.
    public func makeAskUserSheetViewModel(
        eventID: String,
        event: AskUserEvent,
        onClose: @escaping () -> Void
    ) -> AskUserSheetViewModel {
        AskUserSheetViewModel(
            event: event,
            promptEventID: eventID,
            timeline: timeline,
            onClose: onClose
        )
    }

    /// Stable per-prompt `AskUserSheetViewModel` cache for the inline
    /// `AskUserCard`. The card looks its VM up by prompt event ID every render;
    /// without caching, a fresh VM each timeline snapshot would reset the user's
    /// in-progress selection / typing. Keyed by prompt event ID, bounded by the
    /// room's open-prompt count and torn down with this (per-room) view model.
    private var askViewModels: [String: AskUserSheetViewModel] = [:]

    /// Returns the stable `AskUserSheetViewModel` for the `.askUser` prompt with
    /// `eventID`, creating + caching it on first use. `nil` if no such prompt is
    /// in the current timeline. Send-success marks the prompt answered (via the
    /// VM's `onClose`) so the inline card flips to its resolved state.
    public func askViewModel(forPrompt eventID: String) -> AskUserSheetViewModel? {
        if let existing = askViewModels[eventID] { return existing }
        guard let event = askEvent(forPrompt: eventID) else { return nil }
        let vm = makeAskUserSheetViewModel(eventID: eventID, event: event) { [weak self] in
            self?.markPromptAnswered(eventID)
        }
        askViewModels[eventID] = vm
        return vm
    }

    /// The chosen answer for `promptEventID`, for the card's resolved state, or
    /// `nil` if not yet answered. Buttons: maps the hidden `.askUserAnswer`
    /// `selectedValues` back to option labels via the prompt's options (so
    /// cross-device answers display). Text channel: the reply message body.
    public func answerSummary(forPrompt promptEventID: String) -> String? {
        for item in items {
            if case .askUserAnswer(let pid, let values) = item.kind,
               pid == promptEventID, item.isOwn {
                return mapValuesToLabels(values, promptEventID: promptEventID)
            }
        }
        for item in items where item.isOwn && item.inReplyToEventID == promptEventID {
            if case .text(let body, _) = item.kind { return body }
        }
        return nil
    }

    /// The `AskUserEvent` for a prompt event ID, scanned from the timeline.
    private func askEvent(forPrompt eventID: String) -> AskUserEvent? {
        for item in items {
            if case .askUser(let id, let evt) = item.kind, id == eventID { return evt }
        }
        return nil
    }

    private func mapValuesToLabels(_ values: [String], promptEventID: String) -> String {
        var labelByValue: [String: String] = [:]
        if let evt = askEvent(forPrompt: promptEventID) {
            switch evt.kind {
            case .choice(let options, _), .multiChoice(let options, _):
                for opt in options { labelByValue[opt.value] = opt.label }
            case .text, .boolean:
                break
            }
        }
        return values.map { labelByValue[$0] ?? $0 }.joined(separator: ", ")
    }

    /// Live count of cached resolved images. Test seam for asserting
    /// LRU eviction without exposing the raw storage.
    public var resolvedImageCount: Int { resolvedImages.count }

    /// Live count of remembered decode failures. Test seam for asserting
    /// LRU eviction without exposing the raw storage.
    public var failedRequestCount: Int { failedRequests.count }
}

/// Identifiable payload for the ask-user sheet presentation —
/// `.sheet(item:)` keys on the prompt's event ID, so a NEW prompt
/// arriving while a sheet is up swaps the content, while re-snapshots
/// of the SAME prompt leave the presented sheet untouched.
public struct AskUserPromptContext: Identifiable, Equatable, Sendable {
    /// The prompt's Matrix event ID.
    public let id: String
    public let event: AskUserEvent

    public init(id: String, event: AskUserEvent) {
        self.id = id
        self.event = event
    }
}

/// Single-shot signal used by `ChatViewModel.start()` to bridge "first
/// timeline snapshot processed" from the long-lived observation Task back
/// to the `start()` caller. Class-typed so the underlying continuation can
/// be flipped by reference from inside the Task closure (a value-type
/// `CheckedContinuation` would be copied each time it's captured).
///
/// `fireOnce()` is idempotent: subsequent calls are no-ops, so it's safe
/// to call from both the first-snapshot path and the stream-completion
/// fallback. `wait()` returns immediately if `fireOnce()` already ran;
/// otherwise it suspends until it does.
///
/// `@unchecked Sendable` is required because the `CheckedContinuation` that
/// `wait()` parks must be flipped from inside the long-lived observation
/// `Task` (a different actor / thread). Strict concurrency would otherwise
/// reject capturing `pending` across that hop. The `NSLock` enforces the
/// safety the type signature elides.
private final class FirstSnapshotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var pending: [CheckedContinuation<Void, Never>] = []

    func fireOnce() {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        let waiters = pending
        pending = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                cont.resume()
            } else {
                pending.append(cont)
                lock.unlock()
            }
        }
    }
}
