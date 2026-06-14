import Foundation
import os

/// Walks a room's timeline backward (via a `TimelinePager`) and indexes its
/// history into the `SearchService`, until one of: the depth limit, the
/// `sinceCutoff` age boundary, or the start of the timeline. SDK-free by design
/// — all SDK contact is behind `TimelinePager` — so the loop is fully covered by
/// `BackfillTests` against a fake pager.
public final class BackfillRunner: @unchecked Sendable {
    private let timeline: TimelinePager
    private let search: SearchService

    // DIAGNOSTIC (throwaway branch): always-on so it's visible on a real device
    // via Console.app without enabling MatronDebug. Lets us see, per room,
    // whether backfill completes or bails on an empty first page.
    private static let logger = os.Logger(subsystem: "chat.matron", category: "backfill")

    public init(timeline: TimelinePager, search: SearchService) {
        self.timeline = timeline
        self.search = search
    }

    /// Indexes history for `roomID` until depth limit, `sinceCutoff`, or
    /// start-of-timeline. `sinceCutoff` is the oldest timestamp we care about:
    /// because backward pagination yields events newest-first, the loop stops as
    /// soon as it reaches an indexable event older than the cutoff — and that
    /// event (and everything beyond it) is left unindexed.
    public func backfill(roomID: String, depthLimit: Int = 1000, sinceCutoff: Date) async throws {
        if try await search.backfillComplete(roomID: roomID) {
            Self.logger.notice("backfill SKIP room=\(roomID, privacy: .public) (alreadyComplete)")
            return
        }

        // Resume-aware: count what's already indexed for this room.
        var indexedCount = (try? await search.eventCount(roomID: roomID)) ?? 0
        var oldestEventID: String? = nil
        var oldestTimestamp: Date = .distantFuture
        // Whether we reached a genuine terminus — start-of-timeline, the age
        // cutoff, or the depth limit. Only then is the room marked complete.
        // An empty batch is NOT a terminus (see below), so it must not flip
        // this.
        var reachedEnd = false

        // DIAGNOSTIC counters.
        var pages = 0
        var firstPageItemCount = -1
        var stopReason = "loopExit"

        outer: while indexedCount < depthLimit {
            let result = try await timeline.paginateBackward(roomID: roomID, batchSize: 50)
            pages += 1
            if firstPageItemCount < 0 { firstPageItemCount = result.items.count }

            for item in result.items where item.indexable {
                // Newest-first ordering: the first event older than the cutoff means
                // every remaining event is older too. Stop here, leaving it unindexed.
                if item.timestamp < sinceCutoff { reachedEnd = true; stopReason = "cutoff"; break outer }
                if try await search.contains(eventID: item.eventID) { continue }
                try await search.index(
                    roomID: roomID,
                    eventID: item.eventID,
                    sender: item.sender,
                    timestamp: item.timestamp,
                    body: item.body
                )
                indexedCount += 1
                if item.timestamp < oldestTimestamp {
                    oldestTimestamp = item.timestamp
                    oldestEventID = item.eventID
                }
                if indexedCount >= depthLimit { stopReason = "depthLimit"; break outer }
            }

            // Authoritative "history exhausted" signal from the pager.
            if result.hitStartOfTimeline { reachedEnd = true; stopReason = "startOfTimeline"; break }

            // No events surfaced this round but history isn't exhausted: the
            // pager's listener hasn't delivered the paginated diff yet
            // (TimelinePagerLive documents this timing gap). Stop WITHOUT
            // marking the room complete — recording `complete: true` here
            // persists a "done" flag that permanently skips the room, even
            // across sessions, so its history would never get indexed (bugbot
            // "Empty page marks backfill done"). A later open / next launch
            // retries; already-indexed events are deduped via `contains`.
            if result.items.isEmpty { stopReason = "emptyPage"; break }
        }

        // Hitting the depth limit is a genuine terminus too (we've indexed our
        // cap), including the resume case where the room was already at the
        // limit on entry and the loop body never ran.
        if indexedCount >= depthLimit { reachedEnd = true }

        Self.logger.notice("backfill END room=\(roomID, privacy: .public) complete=\(reachedEnd, privacy: .public) indexed=\(indexedCount, privacy: .public) pages=\(pages, privacy: .public) firstPageItems=\(firstPageItemCount, privacy: .public) stop=\(stopReason, privacy: .public)")

        try await search.recordBackfillProgress(
            roomID: roomID,
            indexedCount: indexedCount,
            oldestEventID: oldestEventID,
            complete: reachedEnd
        )
    }
}
