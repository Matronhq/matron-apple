import Foundation

/// Walks a room's timeline backward (via a `TimelinePager`) and indexes its
/// history into the `SearchService`, until one of: the depth limit, the
/// `sinceCutoff` age boundary, or the start of the timeline. SDK-free by design
/// — all SDK contact is behind `TimelinePager` — so the loop is fully covered by
/// `BackfillTests` against a fake pager.
public final class BackfillRunner: @unchecked Sendable {
    private let timeline: TimelinePager
    private let search: SearchService

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
        if try await search.backfillComplete(roomID: roomID) { return }

        // Resume-aware: count what's already indexed for this room.
        var indexedCount = (try? await search.eventCount(roomID: roomID)) ?? 0
        var oldestEventID: String? = nil
        var oldestTimestamp: Date = .distantFuture

        outer: while indexedCount < depthLimit {
            let result = try await timeline.paginateBackward(roomID: roomID, batchSize: 50)
            if result.items.isEmpty { break }

            for item in result.items where item.indexable {
                // Newest-first ordering: the first event older than the cutoff means
                // every remaining event is older too. Stop here, leaving it unindexed.
                if item.timestamp < sinceCutoff { break outer }
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
                if indexedCount >= depthLimit { break outer }
            }

            if result.hitStartOfTimeline { break }
        }

        try await search.recordBackfillProgress(
            roomID: roomID,
            indexedCount: indexedCount,
            oldestEventID: oldestEventID,
            complete: true
        )
    }
}
