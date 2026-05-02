import Foundation
import SwiftUI
import MatronChat
import MatronModels

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
    public let roomID: String
    public private(set) var items: [TimelineItem] = []
    public private(set) var error: String?
    /// Cache of `mxc://` URL → resolved SwiftUI `Image`. Populated lazily by
    /// `image(for:)` so SwiftUI can re-render the row once the bytes arrive.
    public private(set) var resolvedImages: [URL: Image] = [:]

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

    /// Starts observing the timeline. Returns the observation task so callers
    /// (especially tests) can `await task.value` to know when the stream has
    /// drained — no sleeps required.
    @discardableResult
    public func start() -> Task<Void, Never> {
        observationTask?.cancel()
        let timeline = self.timeline
        let task = Task { [weak self] in
            for await snapshot in timeline.items() {
                guard let self else { return }
                await MainActor.run { self.items = snapshot }
            }
        }
        observationTask = task
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
    /// same URL coalesce to a single in-flight request.
    public func image(for url: URL) -> Image? {
        if let cached = resolvedImages[url] { return cached }
        guard !inFlightRequests.contains(url) else { return nil }
        inFlightRequests.insert(url)
        Task { [weak self, media] in
            let img = await media.swiftUIImage(for: url)
            guard let self else { return }
            await MainActor.run {
                if let img { self.resolvedImages[url] = img }
                self.inFlightRequests.remove(url)
            }
        }
        return nil
    }
}
