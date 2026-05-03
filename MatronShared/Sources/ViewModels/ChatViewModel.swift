import Foundation
import SwiftUI
import MatronChat
import MatronModels
import MatronStorage

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

    public let roomID: String
    public private(set) var items: [TimelineItem] = []
    public private(set) var error: String?
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
            for await snapshot in timeline.items() {
                guard let self else {
                    firstSignal.fireOnce()
                    return
                }
                await MainActor.run { self.items = snapshot }
                firstSignal.fireOnce()
            }
            // Stream finished without yielding any snapshot — still
            // resume so the caller of `start()` doesn't hang on a room
            // that the live timeline never populates (or a fake set up
            // with no `snapshotsToEmit`).
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
        do {
            try await timeline.paginateBackward(requestSize: 30)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func markAsRead() async {
        try? await timeline.markAsRead()
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
