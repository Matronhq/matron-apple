import Foundation
import SwiftUI
import os
import MatronChat
import MatronEvents
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

    /// Single mutation entry point for `items`. Updates the raw
    /// snapshot and the three derived caches atomically so a body
    /// re-eval that reads any combination of `items` / `rows` /
    /// `firstRenderableItemID` / `lastRenderableItemID` always sees
    /// a consistent view.
    private func applySnapshot(_ snapshot: [TimelineItem]) {
        self.items = snapshot
        applyDerivedRecompute()
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
        var previousDay: Date?
        for item in items {
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
            let day = calendar.startOfDay(for: item.timestamp)
            if previousDay == nil || day != previousDay {
                nextRows.append(.separator(date: item.timestamp))
                previousDay = day
            }
            nextRows.append(.message(item))
        }
        self.rows = nextRows
        self.firstRenderableItemID = first
        self.lastRenderableItemID = last
    }

    /// `true` while a `paginateBackward()` call is in flight. Surfaces to
    /// the view so the topmost row's `.onAppear` trigger can guard
    /// against re-entering the paginate loop on every re-layout, and so
    /// the view can show a tiny "loading earlier…" spinner if it wants.
    public private(set) var isPaginatingBackward: Bool = false
    /// Flips to `true` once we've observed enough consecutive
    /// zero-growth paginate calls to be confident the SDK genuinely has
    /// no more history to surface. Setting this stops further paginate
    /// triggers from the scroll-position listener — without it the
    /// `.onChange(of: scrolledItemID)` trigger fires paginate on every
    /// row change at the head, hammering the SDK for no result.
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
    /// Cache of `mxc://` URL → resolved SwiftUI `Image`. Populated lazily by
    /// `image(for:)` so SwiftUI can re-render the row once the bytes arrive.
    /// Backed by an `LRUCache` (capped at `mediaCacheLimit`) so a long
    /// session in a media-heavy room can't grow this set without bound
    /// (QA finding #4). The value-type `LRUCache` lives directly on the
    /// view-model — `@MainActor` isolation gives us the required
    /// single-threaded mutating-get access without extra synchronisation.
    private var resolvedImages: LRUCache<URL, Image> = LRUCache(limit: ChatViewModel.mediaCacheLimit)
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
    /// Tracks `mxc://` URLs with a request already in flight so we don't
    /// fire duplicate fetches on every SwiftUI re-render.
    private var inFlightRequests: Set<URL> = []

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

    public init(roomID: String, timeline: TimelineService, media: MediaService) {
        self.roomID = roomID
        self.timeline = timeline
        self.media = media
        let stored = UserDefaults.standard.stringArray(forKey: "matron.answeredPrompts.\(roomID)") ?? []
        self.answeredPromptIDs = Set(stored)
    }

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
    /// Debounces the empty → `settledEmpty` transition (see `settledEmpty`).
    /// A non-empty snapshot clears it immediately and cancels any pending
    /// flip; an empty one schedules the flip after the grace, so a
    /// transient clear that repopulates first never surfaces the
    /// placeholder. `@MainActor` (the whole VM is) so the scheduled task
    /// touches `settledEmpty` on the main actor.
    private func updateSettledEmpty(isEmpty: Bool) {
        emptyDebounceTask?.cancel()
        emptyDebounceTask = nil
        guard isEmpty else {
            settledEmpty = false
            return
        }
        let graceMs = emptyPlaceholderGraceMs
        emptyDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(graceMs))
            guard !Task.isCancelled, let self else { return }
            self.settledEmpty = true
        }
    }

    public func start() async -> Task<Void, Never> {
        observationTask?.cancel()
        // Fresh subscription — drop any stale settled-empty state from a
        // prior room/timeline before the new stream's snapshots arrive.
        settledEmpty = false
        emptyDebounceTask?.cancel()
        emptyDebounceTask = nil
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
                        let before = self.items.count
                        self.applySnapshot(snapshot)
                        Self.logger.diag("snapshot: items \(before)→\(snapshot.count) firstRenderable=\(self.firstRenderableItemID ?? "nil")")
                        // Clear any prior error once a fresh snapshot lands.
                        self.error = nil
                        // Flip on the first applied snapshot so the
                        // empty-state placeholder gates correctly even
                        // when the snapshot itself is empty.
                        self.hasReceivedFirstSnapshot = true
                        // Debounce the empty-state so a transient timeline
                        // clear (sliding-sync reset) doesn't flash the
                        // "no messages yet" placeholder.
                        self.updateSettledEmpty(isEmpty: snapshot.isEmpty)
                    }
                    firstSignal.fireOnce()
                }
            } catch {
                // Stream threw — surface the message so the View can
                // render an overlay instead of an infinite spinner
                // (QA finding #10).
                let message = error.localizedDescription
                if let self {
                    await MainActor.run { self.error = message }
                }
            }
            // Stream finished (or threw) without yielding any snapshot —
            // still resume so the caller of `start()` doesn't hang on a
            // room that the live timeline never populates (or a fake set
            // up with no `snapshotsToEmit`). Flip the first-snapshot
            // flag too so the empty-state placeholder isn't stuck
            // hidden on rooms whose live timeline never warms up.
            if let self {
                await MainActor.run {
                    self.hasReceivedFirstSnapshot = true
                    // A room whose live timeline never warmed up is
                    // genuinely empty — let the placeholder settle in.
                    self.updateSettledEmpty(isEmpty: self.items.isEmpty)
                }
            }
            firstSignal.fireOnce()
        }
        observationTask = task
        await firstSignal.wait()
        return task
    }

    /// Cancels the in-flight observation task. Call from `View.onDisappear`
    /// to release the AsyncStream's continuation. Idempotent.
    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        emptyDebounceTask?.cancel()
        emptyDebounceTask = nil
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

    /// Retry handler for own-messages whose send state is `.failed`.
    /// Currently a stub: real SDK retry wiring lands later (the
    /// `MatrixRustSDK` exposes `Timeline.retryDecryption` /
    /// `Timeline.send` queue replays, but the right hook for "retry
    /// this specific failed local-echo" needs a service-layer
    /// addition to `TimelineService` that hasn't shipped yet).
    /// Logging-only so taps are observable in the debugger; no state
    /// mutation here so the failed glyph stays visible until the
    /// underlying snapshot updates.
    ///
    /// TODO(phase-3+): replace this stub with `timeline.retrySend(itemID:)`
    /// once the service-layer surface lands. Until then the UI
    /// affordance exists but the behaviour is a noop — this is
    /// deliberate so the visual treatment can ship ahead of the SDK
    /// wiring without the call site silently swallowing taps.
    public func retrySend(itemID: String) {
        Self.logger.info("retrySend tapped for item=\(itemID, privacy: .public) (stub)")
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
        if let cached = resolvedImages[url] { return cached }
        if failedRequests.contains(url) { return nil }
        guard !inFlightRequests.contains(url) else { return nil }
        inFlightRequests.insert(url)
        Task { [weak self, media] in
            let img = await media.swiftUIImage(for: url)
            guard let self else { return }
            await MainActor.run {
                if let img {
                    self.resolvedImages[url] = img
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
    public func writeTempFile(mxcURL: URL, filename: String) async -> URL? {
        guard let data = await media.fetchBytes(mxcURL: mxcURL) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("matron-attachments", isDirectory: true)
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
    public func resolvedImage(for url: URL) -> Image? { resolvedImages[url] }

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
        // Persist cross-device answers the moment the timeline shows
        // them (bugbot PR #6 finding): on a fresh timeline the
        // encrypted answer event can lag decryption behind the prompt,
        // and a snapshot caught in that window would re-pop a sheet
        // for a prompt already answered elsewhere. Folding timeline
        // knowledge into the UserDefaults set makes the answered state
        // survive snapshots that temporarily lack the answer event.
        // Intersected with the prompts actually present: only a
        // visible prompt can re-pop, and `answeredInTimeline` also
        // holds the user's replies to ORDINARY messages — persisting
        // those would grow the defaults set without bound.
        var promptIDsInTimeline: Set<String> = []
        for item in items {
            if case .askUser(let id, _) = item.kind {
                promptIDsInTimeline.insert(id)
            }
        }
        for id in answeredInTimeline.intersection(promptIDsInTimeline)
        where !answeredPromptIDs.contains(id) {
            markPromptAnswered(id)
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
