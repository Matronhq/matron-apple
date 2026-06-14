import Foundation

/// Aggregate backfill progress across all rooms (distinct from the per-room
/// `BackfillProgress`). Surfaced to the search UI for the "Indexing chats…"
/// empty state.
public struct AggregateBackfillProgress: Equatable, Sendable {
    public let roomsCompleted: Int
    public let roomsTotal: Int

    public init(roomsCompleted: Int, roomsTotal: Int) {
        self.roomsCompleted = roomsCompleted
        self.roomsTotal = roomsTotal
    }

    public var inProgress: Bool { roomsCompleted < roomsTotal }
}

/// Owns the `BackfillRunner` and drives it across every known room once per
/// session, publishing aggregate progress. Lives in MatronSearch so it stays
/// testable (its only collaborator is the SDK-free `BackfillRunner`); the app
/// layer constructs it with an SDK-backed runner and kicks it off post-login.
///
/// Backfill runs **serially** — it's a low-priority background sweep and serial
/// keeps homeserver `/messages` load gentle. `progressStream()` is multi-consumer
/// (each subscriber gets the current value replayed immediately, then live
/// updates), so any number of `SearchViewModel`s can render the indexing state.
public actor BackfillCoordinator {
    private let runner: BackfillRunner
    private let cutoff: Date
    /// Pause between sweep retry passes over rooms whose backfill failed
    /// (e.g. a not-yet-synced room). Injectable so tests don't sleep.
    private let retryDelay: Duration
    private var current = AggregateBackfillProgress(roomsCompleted: 0, roomsTotal: 0)
    private var observers: [UUID: AsyncStream<AggregateBackfillProgress>.Continuation] = [:]
    private var hasRun = false

    public init(runner: BackfillRunner, cutoff: Date, retryDelay: Duration = .seconds(5)) {
        self.runner = runner
        self.cutoff = cutoff
        self.retryDelay = retryDelay
    }

    /// The latest aggregate progress (for pull-style reads).
    public var progress: AggregateBackfillProgress { current }

    /// A stream that immediately replays the current progress, then delivers
    /// live updates. Safe to call from multiple consumers.
    public func progressStream() -> AsyncStream<AggregateBackfillProgress> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.yield(current)
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    /// Backfills every room in `roomIDs`, serially, publishing progress after
    /// each. Idempotent per coordinator instance — a second call is a no-op so a
    /// re-fired `.task` can't restart the sweep (individual rooms are also
    /// resume-guarded by `BackfillRunner` via `backfillComplete`).
    public func run(roomIDs: [String]) async {
        guard !hasRun else { return }
        // An empty list means the first non-empty chat-list snapshot hadn't
        // landed yet (sync still warming, or `firstSnapshotRoomIDs()` hit its
        // 30s bound). Don't latch `hasRun`: a 0/0 sweep isn't a real sweep, and
        // latching would permanently skip every room for the session — later
        // rooms would only ever get indexed by being opened for live indexing
        // (bugbot "Backfill never retries empty snapshot"). The caller retries
        // with a populated list, and per-room `backfillComplete` still guards
        // against redundant work.
        guard !roomIDs.isEmpty else { return }
        hasRun = true
        let total = roomIDs.count
        publish(AggregateBackfillProgress(roomsCompleted: 0, roomsTotal: total))

        // Count only rooms whose backfill actually succeeds. A room can fail
        // transiently — e.g. `TimelinePagerError.roomNotFound` when it's on the
        // chat list but not yet in the SDK store on a cold start. The old
        // `try?`-then-advance counted such a room as done even though nothing
        // was indexed (bugbot "Failed room backfill still counts"). Failures
        // are retried a few times within the sweep (succeeded rooms are skipped
        // cheaply by `BackfillRunner.backfillComplete`); anything still failing
        // is left uncounted and `backfillComplete == false`, so the next launch
        // retries it instead of treating it as done.
        var completed = 0
        var pending = roomIDs
        for attempt in 0..<3 {
            var stillPending: [String] = []
            for roomID in pending {
                do {
                    try await runner.backfill(roomID: roomID, sinceCutoff: cutoff)
                    completed += 1
                    publish(AggregateBackfillProgress(roomsCompleted: completed, roomsTotal: total))
                } catch {
                    stillPending.append(roomID)
                }
            }
            pending = stillPending
            if pending.isEmpty { break }
            if attempt < 2 { try? await Task.sleep(for: retryDelay) }
        }
    }

    private func publish(_ progress: AggregateBackfillProgress) {
        current = progress
        for continuation in observers.values {
            continuation.yield(progress)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
