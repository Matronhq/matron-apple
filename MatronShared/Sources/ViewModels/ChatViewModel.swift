import Foundation
import SwiftUI
import os
import MatronChat
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
    public private(set) var items: [TimelineItem] = []
    public private(set) var error: String?

    /// Calendar used for date-separator bucketing. Injectable so tests
    /// can pin a deterministic timezone without poking the host
    /// runtime. Default is `Calendar.current` so production callers
    /// don't have to thread anything through.
    public var calendar: Calendar = .current

    /// Render-ready row list: `items` interleaved with `.separator`
    /// rows whenever two adjacent messages straddle a calendar-day
    /// boundary (and one separator at the head of the timeline so the
    /// first cluster also has a header). Computed on each access —
    /// `O(items.count)` and not on the hot scroll path, so the
    /// allocation cost is negligible compared to the SwiftUI diff
    /// downstream. Memoising would risk the cache going stale relative
    /// to `items`; SwiftUI re-evaluates the body on `@Observable`
    /// changes anyway, so the recomputation runs at exactly the right
    /// cadence.
    public var rows: [TimelineRow] {
        // Filter hidden items BEFORE bucketing. Two reasons:
        //   (a) `TimelineServiceLive.mapVirtual` emits placeholder
        //       items for `dateDivider` / `readMarker` / `timelineStart`
        //       with `timestamp = Date(timeIntervalSince1970: 0)`. If
        //       those participate in day-bucketing, a "1 Jan 1970"
        //       separator pops up mid-list — exactly what the user
        //       reported between today's content and last-night's
        //       still-undecryptable events.
        //   (b) `.stateChange` rows are hidden by the view's
        //       `shouldRender` (Phase 7 polish can bring back a
        //       metadata-events toggle), so they shouldn't influence
        //       which days get separators either.
        // Both share the `.stateChange` Kind tag, which makes the
        // filter trivial. Any future hidden Kind needs the same
        // treatment to avoid the same date-bucket pollution.
        let visibleItems = items.filter {
            if case .stateChange = $0.kind { return false }
            return true
        }
        guard !visibleItems.isEmpty else { return [] }
        var out: [TimelineRow] = []
        out.reserveCapacity(visibleItems.count + 4)
        var previousDay: Date?
        for item in visibleItems {
            let day = calendar.startOfDay(for: item.timestamp)
            if previousDay == nil || day != previousDay {
                out.append(.separator(date: item.timestamp))
                previousDay = day
            }
            out.append(.message(item))
        }
        return out
    }
    /// ID of the first item the timeline view actually renders — i.e.
    /// the first non-`.stateChange` item in `items`. Used by the
    /// scroll-up `.onAppear` paginate trigger; comparing against
    /// `items.first?.id` was wrong because `items.first` is regularly a
    /// `.stateChange` (room create / encryption setup at the head of
    /// every Matrix room timeline), and the view filters those out
    /// before rendering. The mismatch silently disabled scroll-up
    /// pagination for any room whose oldest known event was a state
    /// change — which is most rooms. Stays in sync with
    /// `MacTimelineItemView.shouldRender` / `TimelineItemView.shouldRender`
    /// (both hide ALL `.stateChange`); future hidden Kinds need the
    /// same treatment here.
    public var firstRenderableItemID: TimelineItem.ID? {
        items.first(where: { item in
            if case .stateChange = item.kind { return false }
            return true
        })?.id
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

    public init(roomID: String, timeline: TimelineService, media: MediaService) {
        self.roomID = roomID
        self.timeline = timeline
        self.media = media
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
    public func start() async -> Task<Void, Never> {
        observationTask?.cancel()
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
                        self.items = snapshot
                        let firstRenderable = self.firstRenderableItemID
                        Self.logger.notice("snapshot: items \(before, privacy: .public)→\(snapshot.count, privacy: .public) firstRenderable=\(firstRenderable ?? "nil", privacy: .public)")
                        // Clear any prior error once a fresh snapshot lands.
                        self.error = nil
                        // Flip on the first applied snapshot so the
                        // empty-state placeholder gates correctly even
                        // when the snapshot itself is empty.
                        self.hasReceivedFirstSnapshot = true
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
                await MainActor.run { self.hasReceivedFirstSnapshot = true }
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
            Self.logger.debug("paginateBackward: skip — already in flight")
            return
        }
        if reachedHistoryStart {
            Self.logger.debug("paginateBackward: skip — reachedHistoryStart")
            return
        }
        isPaginatingBackward = true
        defer { isPaginatingBackward = false }
        let beforeCount = items.count
        Self.logger.notice("paginateBackward: enter (items=\(beforeCount, privacy: .public))")
        do {
            _ = try await timeline.paginateBackward(requestSize: 30)
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
            Self.logger.notice("paginateBackward: done (items: \(beforeCount, privacy: .public)→\(self.items.count, privacy: .public), grew=\(grew, privacy: .public))")
            if grew {
                consecutiveNoGrowthPaginates = 0
            } else {
                consecutiveNoGrowthPaginates += 1
                if consecutiveNoGrowthPaginates >= Self.noGrowthLimitForReachedStart {
                    reachedHistoryStart = true
                    Self.logger.notice("paginateBackward: reached history start (no growth across \(Self.noGrowthLimitForReachedStart, privacy: .public) consecutive calls)")
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
            let dest = dir.appendingPathComponent(filename)
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

    /// Live count of cached resolved images. Test seam for asserting
    /// LRU eviction without exposing the raw storage.
    public var resolvedImageCount: Int { resolvedImages.count }

    /// Live count of remembered decode failures. Test seam for asserting
    /// LRU eviction without exposing the raw storage.
    public var failedRequestCount: Int { failedRequests.count }
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
