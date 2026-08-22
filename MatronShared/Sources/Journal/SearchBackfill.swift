import Foundation
import MatronSearch
import os

extension JournalEvent {
    /// The text the search index should hold for this event, or `nil` when
    /// the event carries nothing searchable. Single source of truth for all
    /// three index feeders — live sync (`JournalSyncEngine`), backward
    /// pagination (`JournalTimelineService`), and the history backfill —
    /// so what the user can SEE is what search can FIND.
    public var searchableBody: String? {
        let body: String? = switch type {
        case JournalEventType.text: payload["body"] as? String
        case JournalEventType.toolOutput: payload["snippet"] as? String
        // diff → snippet precedence mirrors JournalTimelineMapper.
        case JournalEventType.diff: payload["diff"] as? String ?? payload["snippet"] as? String
        default: nil
        }
        guard let body, !body.isEmpty else { return nil }
        return body
    }
}

/// Walks every conversation's server-side history backward through
/// `GET /convo/:id/messages` and indexes it into the local FTS store.
///
/// Why this exists: the live index feeders only cover events this device has
/// actually seen. A device that bootstraps from `/snapshot` (fresh install, or
/// a replay gap past the server's valve) receives conversation metadata but no
/// message bodies, so its search index starts empty and pre-bootstrap history
/// is findable only by manually scrolling each chat. This coordinator fills
/// that hole from the server's durable journal.
///
/// The walk is serial across conversations and throttled between pages — it's
/// a low-priority background sweep, not a race. Per-conversation progress
/// persists in the search store's `indexed_rooms` bookkeeping
/// (`recordBackfillProgress` / `backfillOldestEventID`), so an interrupted
/// walk resumes where it left off and a completed conversation costs one
/// local read on later sweeps. Indexing is idempotent (INSERT OR REPLACE on
/// event id), so overlap with the live feeders is harmless.
public actor SearchBackfillCoordinator {
    /// Page fetcher, `JournalAPI.messages(convoID:beforeSeq:limit:)`-shaped.
    /// A closure rather than the concrete API client so tests script pages
    /// without a network stack.
    public typealias FetchPage = @Sendable (_ convoID: String, _ beforeSeq: Int64?, _ limit: Int) async throws -> [JournalEvent]

    private let search: any SearchService
    private let fetchPage: FetchPage
    private let pageSize: Int
    private let throttle: Duration
    /// Bumped by `reset()`. A walk captures it per conversation and drops
    /// its writes once it has moved — see `reset()` for why actor isolation
    /// alone cannot provide that ordering.
    private var generation = 0
    private static let logger = os.Logger(subsystem: "chat.matron", category: "search-backfill")

    /// Thrown mid-walk when `reset()` moved the generation; `run` catches it
    /// and stops the sweep so the caller retries against the cleared
    /// bookkeeping.
    private struct GenerationMoved: Error {}

    public init(search: any SearchService, fetchPage: @escaping FetchPage,
                pageSize: Int = 200, throttle: Duration = .milliseconds(100)) {
        self.search = search
        self.fetchPage = fetchPage
        self.pageSize = pageSize
        self.throttle = throttle
    }

    /// Clears the search store's backfill bookkeeping AND invalidates any
    /// walk in flight. This is the only safe way to reset while a sweep may
    /// be running: calling `search.resetBackfill()` directly (as
    /// `coldStartIfNeeded` once did) races the walk — a batch suspended in
    /// `fetchPage` commits its `recordBackfillProgress` after the delete,
    /// resurrecting the watermark/complete flag the reset just cleared, and
    /// every later sweep then skips exactly the head-side range the reset
    /// exists to re-walk.
    ///
    /// Actor isolation alone cannot give that ordering: the walk suspends at
    /// every await and the actor is reentrant there, so a reset CAN land
    /// mid-batch. Hence the epoch — the generation moves BEFORE the delete,
    /// so a batch that captured the old value fails its write-time check.
    /// The second bump covers a batch that started during the delete and
    /// read bookkeeping the delete had not committed yet: its resume point
    /// is equally void. A dropped sweep is cheap (`run` returns `false` and
    /// the caller's retry loop re-walks from the cleared bookkeeping).
    /// Best-effort like the direct call was: a failed delete leaves search
    /// coverage where it was.
    public func reset() async {
        generation &+= 1
        try? await search.resetBackfill()
        generation &+= 1
    }

    /// Sweeps `convoIDs` serially. Returns `true` when every conversation is
    /// fully indexed; `false` when any failed (offline, server error) or the
    /// task was cancelled, so the caller can retry the sweep later. A failed
    /// conversation never blocks the rest of the sweep.
    @discardableResult
    public func run(convoIDs: [String]) async -> Bool {
        var allComplete = true
        for convoID in convoIDs {
            if Task.isCancelled { return false }
            do {
                try await backfill(convoID: convoID)
            } catch is CancellationError {
                return false
            } catch is GenerationMoved {
                // reset() invalidated the sweep mid-flight: the remaining
                // conversations would walk against pre-reset bookkeeping
                // too. Stop; the caller's retry re-sweeps from scratch.
                return false
            } catch {
                // Transient by assumption (the sweep retries): record and move on.
                allComplete = false
                Self.logger.warning("backfill failed for \(convoID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return allComplete
    }

    private func backfill(convoID: String) async throws {
        // Everything below is premised on bookkeeping as of this epoch;
        // `reset()` moving it voids the premise (see there).
        let epoch = generation
        let complete = try await search.backfillComplete(roomID: convoID)
        // The complete read is an await like any other: a reset() landing
        // inside it voids the answer. Returning "done" on the stale true
        // would be the one epoch escape left — no write to guard, but `run`
        // reports the sweep complete and the just-cleared room waits for
        // the next idle retry instead of re-walking now.
        guard generation == epoch else { throw GenerationMoved() }
        if complete { return }
        // Resume point: the oldest seq a previous walk reached. `nil` starts
        // at the newest page — those events are usually live-indexed already,
        // but re-indexing is idempotent and the head page is what anchors the
        // downward walk.
        var oldest = (try await search.backfillOldestEventID(roomID: convoID)).flatMap { Int64($0) }
        while true {
            try Task.checkCancellation()
            let events = try await fetchPage(convoID, oldest, pageSize)
            // The server already filters `seq < before_seq`; keep the guard
            // anyway so a misbehaving page can't rewind `oldest` (mirrors
            // `paginateBackward`'s belt-and-braces filter).
            let older = oldest.map { bound in events.filter { $0.seq < bound } } ?? events
            // ONE transaction per page, not one per event. The per-event
            // `search.index` version fsync'd a write transaction per message
            // and re-dirtied FTS b-tree interior pages for every commit —
            // against a ~175 MB index that amplified to ~1 MB of WAL writes
            // per MESSAGE, and the 2026-08-10 post-wipe sweep (2,179 rooms,
            // ~200K messages) tripped macOS's disk-writes resource limit
            // (8.6 GB dirtied in 12 minutes, 15 MB/s sustained). Batching a
            // 200-event page into one commit amortises the tree churn the
            // same way the catch-up replay path (`didApplyBatch`) already
            // does.
            let entries = older.compactMap { event -> SearchIndexEntry? in
                guard let body = event.searchableBody else { return nil }
                return SearchIndexEntry(roomID: event.convoID, eventID: String(event.seq),
                                        sender: event.sender, timestamp: event.ts, body: body)
            }
            // Write-time epoch check: `fetchPage` is a seconds-wide
            // suspension and the actor is reentrant there, so a `reset()`
            // can land mid-batch. Committing this page afterwards would
            // re-insert bookkeeping the reset deleted — worst case
            // re-marking the room complete, hiding the very head-side hole
            // the reset exists to expose — so the batch is dropped instead.
            guard generation == epoch else { throw GenerationMoved() }
            try await search.indexBatch(entries)
            let pageOldest = older.map(\.seq).min()
            if let pageOldest { oldest = pageOldest }
            // A short page means history is exhausted. A full page that made
            // no progress can only come from a server ignoring `before_seq`;
            // terminating (as complete) beats looping on it forever.
            let exhausted = events.count < pageSize || pageOldest == nil
            let indexedCount = try await search.eventCount(roomID: convoID)
            // Re-checked after `indexBatch`/`eventCount` suspended again:
            // the progress row is the dangerous write — it carries the
            // pre-reset watermark/complete flag.
            guard generation == epoch else { throw GenerationMoved() }
            try await search.recordBackfillProgress(
                roomID: convoID, indexedCount: indexedCount,
                oldestEventID: oldest.map(String.init), complete: exhausted)
            if exhausted { return }
            try await Task.sleep(for: throttle)
        }
    }
}
