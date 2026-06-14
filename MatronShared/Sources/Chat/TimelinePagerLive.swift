import Foundation
import os
import MatrixRustSDK
import MatronEvents
import MatronModels
import MatronSearch
import MatronSync

/// SDK-backed `MatronSearch.TimelinePager`. Lives in MatronChat (not
/// MatronSearch) so it can use the same `Room` / `Timeline` machinery as
/// `TimelineServiceLive` and reuse `TimelineSnapshotListener.parseCustomEvent`
/// for tool-call decoding — keeping `MatronSearch` itself free of the SDK.
///
/// ## Why a cached timeline + listener (not the obvious "build timeline,
/// paginate, read result")
///
/// `Room.timeline()` BUILDS A NEW timeline each call, and the v26 SDK delivers
/// paginated events only through a `TimelineListener` — `paginateBackwards`
/// returns just a `reachedStart` Bool, not the events. Worse, calling
/// `paginateBackwards` on a *fresh* timeline returns almost instantly claiming
/// `reachedStart=false` without doing any real `/messages` round-trip (the fresh
/// timeline sits at the live tail with an empty store — the same bug documented
/// at length in `TimelineServiceLive.cachedTimeline`). So each room gets ONE
/// cached `Timeline` with a `PaginationAccumulator` listener attached; paginate
/// drives that timeline and the accumulator collects the revealed events.
///
/// ## Validation status
///
/// This is the one Phase 6 component without unit coverage — the listener-diff
/// timing after `paginateBackwards` can only be exercised against a live room /
/// the integration harness (the plan and its readiness note both call this out).
/// `BackfillRunner`, which drives this, is fully fake-pager-tested. **Validate
/// end-to-end against a live homeserver before trusting backfill in production.**
public final class TimelinePagerLive: TimelinePager, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let sync: MatronSync.SyncService

    public init(provider: ClientProvider, session: UserSession, sync: MatronSync.SyncService) {
        self.provider = provider
        self.session = session
        self.sync = sync
    }

    /// Per-room state. Reference type so `returned` can be mutated in place under
    /// the pager lock without copy-back.
    private final class RoomPager {
        let timeline: Timeline
        let accumulator: PaginationAccumulator
        let handle: TaskHandle
        var returned: Set<String> = []
        init(timeline: Timeline, accumulator: PaginationAccumulator, handle: TaskHandle) {
            self.timeline = timeline
            self.accumulator = accumulator
            self.handle = handle
        }
    }

    private let lock = NSLock()
    private var pagers: [String: RoomPager] = [:]

    public func paginateBackward(roomID: String, batchSize: Int) async throws -> (items: [BackfillItem], hitStartOfTimeline: Bool) {
        let pager = try await ensurePager(roomID: roomID)
        // Authoritative termination signal — true once history is exhausted.
        let reachedStart = try await pager.timeline.paginateBackwards(numEvents: UInt16(max(1, batchSize)))
        // The accumulator has been fed by the listener during the paginate. Read
        // the full set of events seen so far and return only the ones we haven't
        // handed back yet; BackfillRunner additionally dedups via `contains`.
        let fresh = takeFresh(from: pager.accumulator.snapshot(), pager: pager)
        return (fresh, reachedStart)
    }

    private func ensurePager(roomID: String) async throws -> RoomPager {
        if let existing = cachedPager(roomID) { return existing }

        try await sync.waitUntilReady()
        let room = try await resolveRoom(roomID: roomID)
        let timeline = try await room.timeline()
        let accumulator = PaginationAccumulator()
        let handle = await timeline.addListener(listener: accumulator)
        let pager = RoomPager(timeline: timeline, accumulator: accumulator, handle: handle)
        return store(pager, for: roomID)
    }

    // MARK: - Locked state accessors (synchronous so the lock is never held
    // across an `await` — and so NSLock isn't touched from an async context).

    private func cachedPager(_ roomID: String) -> RoomPager? {
        lock.lock(); defer { lock.unlock() }
        return pagers[roomID]
    }

    /// Stores `pager` for `roomID`, or — if a parallel call already won — drops
    /// our duplicate listener and returns the winner.
    private func store(_ pager: RoomPager, for roomID: String) -> RoomPager {
        lock.lock()
        if let winner = pagers[roomID] {
            lock.unlock()
            pager.handle.cancel()
            return winner
        }
        pagers[roomID] = pager
        lock.unlock()
        return pager
    }

    /// Returns the snapshot items not yet handed back, recording them as
    /// returned. Sorted newest-first: `PaginationAccumulator.snapshot()` yields
    /// `byEventID.values` in arbitrary dict order, but `BackfillRunner`'s cutoff
    /// logic assumes descending timestamps — it stops at the first event older
    /// than `sinceCutoff`. Without this a batch spanning the 90-day boundary
    /// could index messages that should be excluded, or stop early and skip
    /// in-window messages in the same batch (bugbot "Backfill batches lack time
    /// order").
    private func takeFresh(from snapshot: [BackfillItem], pager: RoomPager) -> [BackfillItem] {
        lock.lock(); defer { lock.unlock() }
        let fresh = snapshot.filter { !pager.returned.contains($0.eventID) }
        for item in fresh { pager.returned.insert(item.eventID) }
        return fresh.sorted { $0.timestamp > $1.timestamp }
    }

    /// Same resolution path as `TimelineServiceLive.resolveRoom`: `getRoom` first,
    /// then the room-list-service fallback for rooms only surfaced by sliding sync
    /// (a cold start has every chat in the list but not yet in the BaseClient
    /// store).
    private func resolveRoom(roomID: String) async throws -> Room {
        let client = try await provider.client(for: session)
        if let room = try client.getRoom(roomId: roomID) {
            return room
        }
        if let sdkSync = await sync.sdkService() {
            if let room = try? sdkSync.roomListService().room(roomId: roomID) {
                return room
            }
        }
        throw TimelinePagerError.roomNotFound(roomID)
    }
}

public enum TimelinePagerError: Error, Equatable, Sendable {
    case roomNotFound(String)
}

/// Accumulates every event the timeline reveals (live tail + everything
/// paginated in) into a dict keyed by REAL Matrix event ID. Backfill only cares
/// about the cumulative set, so removal diffs (`popFront`/`remove`/`truncate`/
/// `clear`) are ignored and `reset` upserts rather than clears — the set is
/// monotonic across paginate calls. Mapping mirrors `TimelineSnapshotListener`:
/// `.text`/`.notice`/`.emote` and tool-call results are `indexable`; everything
/// else is returned as non-indexable so the runner can still count pagination
/// depth.
final class PaginationAccumulator: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var byEventID: [String: BackfillItem] = [:]

    func onUpdate(diff: [TimelineDiff]) {
        lock.lock()
        defer { lock.unlock() }
        for d in diff {
            switch d {
            case .append(let values):
                for v in values { upsert(v) }
            case .reset(let values):
                // Don't clear — keep accumulating so paginated history isn't lost
                // if a re-sync resets the live window mid-backfill.
                for v in values { upsert(v) }
            case .pushFront(let value):
                upsert(value)
            case .pushBack(let value):
                upsert(value)
            case .insert(_, let value):
                upsert(value)
            case .set(_, let value):
                upsert(value)
            case .popFront, .popBack, .remove, .truncate, .clear:
                break   // irrelevant to a cumulative index
            }
        }
    }

    func snapshot() -> [BackfillItem] {
        lock.lock()
        defer { lock.unlock() }
        return Array(byEventID.values)
    }

    private func upsert(_ sdk: MatrixRustSDK.TimelineItem) {
        guard let item = Self.map(sdk) else { return }
        byEventID[item.eventID] = item
    }

    /// SDK item → `BackfillItem`, or nil for virtual items / local echoes (no
    /// real event ID). Indexing needs the real event ID so search's
    /// jump-to-message can focus the timeline.
    static func map(_ sdk: MatrixRustSDK.TimelineItem) -> BackfillItem? {
        guard let ev = sdk.asEvent() else { return nil }
        guard case .eventId(let eventID) = ev.eventOrTransactionId else { return nil }
        let ts = Date(timeIntervalSince1970: TimeInterval(ev.timestamp) / 1000)
        let sender = ev.sender

        // Tool-call custom event → index its result text (reuses the same pure
        // parser the live listener uses).
        if case .msgLike(let msg) = ev.content,
           case .other(let messageLikeEventType) = msg.kind,
           case .other(let typeString) = messageLikeEventType,
           let json = ev.lazyProvider.debugInfo().originalJson,
           case .toolCall(_, let evt)? = TimelineSnapshotListener.parseCustomEvent(typeString: typeString, originalJson: json, eventID: eventID),
           let result = evt.resultText {
            return BackfillItem(eventID: eventID, sender: sender, timestamp: ts,
                                body: "[\(evt.tool)] \(result)", indexable: true)
        }

        // Plain text / notice / emote → index the body.
        if case .msgLike(let msg) = ev.content,
           case .message(let messageContent) = msg.kind {
            switch messageContent.msgType {
            case .text(let c):
                return BackfillItem(eventID: eventID, sender: sender, timestamp: ts, body: c.body, indexable: true)
            case .notice(let c):
                return BackfillItem(eventID: eventID, sender: sender, timestamp: ts, body: c.body, indexable: true)
            case .emote(let c):
                return BackfillItem(eventID: eventID, sender: sender, timestamp: ts, body: c.body, indexable: true)
            default:
                break
            }
        }

        // Images, files, state, ask_user, button answers, unknown — not indexed,
        // but still returned (empty body) so depth/oldest tracking is accurate.
        return BackfillItem(eventID: eventID, sender: sender, timestamp: ts, body: "", indexable: false)
    }
}
