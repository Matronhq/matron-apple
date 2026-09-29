import Foundation
import GRDB
import os

/// Thrown by `LockAwareSearchService` for any operation that would have to
/// touch the index file while iOS holds it shut.
public enum SearchIndexUnavailable: Error, Equatable {
    case protectedDataUnavailable
}

/// A `SearchService` that never touches the index while the device's
/// protected data is unavailable.
///
/// Why this exists: `matron-search.sqlite` is `NSFileProtectionComplete`, so
/// about ten seconds after the phone locks its key is evicted and the file
/// becomes unreadable. The app keeps running in the background after that —
/// BGAppRefresh catch-up, the outbox grace window — and live sync used to
/// keep indexing every applied frame. SQLite maps the WAL index (`-shm`) into
/// memory, so the first write that needed a page of it faulted on the
/// unreadable file and the process died with SIGBUS "FS pagein error: 1
/// Operation not permitted" inside `SearchServiceLive.indexBatch` (five such
/// reports from one phone, builds 1.0.4 → 1.2.0). A thrown error was never on
/// the table: a page-in fault is a signal, not an `errno`.
///
/// So the gate is in front of the database, not behind it:
/// - **Indexing** (`index`/`indexBatch`, from live sync and the history
///   backfill) is buffered in memory while locked and written on unlock, in
///   arrival order. The buffer is capped (`maxPendingEntries` entries,
///   `maxPendingBodyBytes` of body text — this runs in a background process
///   with a small memory budget); a batch that would exceed it is dropped,
///   and once the buffer has been flushed the host's `overflowRecovery`
///   runs. That hook exists because the backfill sweep does NOT re-cover a
///   dropped live entry on its own: it skips conversations already flagged
///   complete and otherwise only walks DOWN from its recorded oldest point,
///   while a dropped live entry sits at the conversation's head. The host
///   wires the hook to a backfill bookkeeping reset, the same remedy the
///   engine applies after a snapshot re-bootstrap.
/// - **Everything else** — queries, backfill bookkeeping reads and writes,
///   retention removals, wipe — throws `SearchIndexUnavailable` while
///   locked. Every such caller already treats a throw as "try again later":
///   the backfill sweep backs off, and the retention sweep keeps its
///   watermark and retries the same rows next pass.
///
/// Writes also fall back to the buffer when the underlying database refuses
/// them with an interruption (`SQLITE_INTERRUPT`/`SQLITE_ABORT`): that is
/// what an in-flight write gets when `protectedDataWillBecomeUnavailable()`
/// interrupts it, and what every write gets while GRDB suspension is in
/// force (see `DatabaseSuspensionController`). Neither should lose the
/// entries, and both end with a `flushPending()` from the host (on unlock, or
/// when the databases resume).
///
/// While anything is buffered, new entries queue behind it rather than
/// overtaking it, so the index sees writes in the order they were made.
public actor LockAwareSearchService: SearchService {
    public static let defaultMaxPendingEntries = 5_000
    public static let defaultMaxPendingBodyBytes = 16 * 1024 * 1024
    /// Entries per write transaction when flushing — the same bound the
    /// retention sweep uses, for the same reason: the index has ONE
    /// connection, and one transaction for thousands of rows would hold it
    /// (and dirty that many FTS pages) in a single commit.
    static let flushChunkSize = 500

    private static let logger = os.Logger(subsystem: "chat.matron", category: "search-lock-gate")

    private let base: any SearchService
    private let isProtectedDataAvailable: @Sendable () -> Bool
    private let interruptInFlight: @Sendable () -> Void
    private let maxPendingEntries: Int
    private let maxPendingBodyBytes: Int

    private var pending: [SearchIndexEntry] = []
    private var pendingBodyBytes = 0
    /// Entries dropped at the cap since the last completed recovery.
    private var droppedCount = 0
    private var flushing = false
    /// Bumped whenever `pending` is edited other than by appending — a flush
    /// suspended in its write must not then `removeFirst` entries whose
    /// positions have shifted underneath it.
    private var pendingEpoch = 0
    private let overflowRecovery: (@Sendable () async -> Void)?

    /// - Parameters:
    ///   - base: the real index.
    ///   - isProtectedDataAvailable: current protected-data state. On iOS the
    ///     host backs this with `UIApplication.isProtectedDataAvailable`,
    ///     already flipped to `false` when
    ///     `protectedDataWillBecomeUnavailableNotification` fires. Called on
    ///     this actor, so it must be cheap and thread-safe.
    ///   - interruptInFlight: aborts the statement `base` is running right
    ///     now (`SearchServiceLive.interrupt()`).
    ///   - overflowRecovery: run after a flush that followed dropped entries
    ///     — see the type comment for why the host must reset backfill there.
    public init(base: any SearchService,
                isProtectedDataAvailable: @escaping @Sendable () -> Bool,
                interruptInFlight: @escaping @Sendable () -> Void = {},
                maxPendingEntries: Int = LockAwareSearchService.defaultMaxPendingEntries,
                maxPendingBodyBytes: Int = LockAwareSearchService.defaultMaxPendingBodyBytes,
                overflowRecovery: (@Sendable () async -> Void)? = nil) {
        self.base = base
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.interruptInFlight = interruptInFlight
        self.maxPendingEntries = maxPendingEntries
        self.maxPendingBodyBytes = maxPendingBodyBytes
        self.overflowRecovery = overflowRecovery
    }

    /// Buffered entries awaiting a flush — diagnostics and tests.
    public var pendingCount: Int { pending.count }

    /// Call when iOS posts `protectedDataWillBecomeUnavailableNotification`,
    /// AFTER `isProtectedDataAvailable` has started returning `false`:
    /// nothing new reaches the index from then on, and this stops the write
    /// that may already be running, whose entries fall back to the buffer.
    /// Nonisolated so the notification handler interrupts synchronously
    /// rather than after an actor hop.
    public nonisolated func protectedDataWillBecomeUnavailable() {
        interruptInFlight()
    }

    /// Writes the buffered entries to the index, oldest first, while
    /// protected data stays available. Call on unlock and whenever the
    /// databases resume; a no-op when nothing is buffered or a flush is
    /// already running (that flush drains whatever arrives meanwhile).
    public func flushPending() async {
        await drainPending()
        guard pending.isEmpty, droppedCount > 0, let overflowRecovery else { return }
        Self.logger.info("search buffer overflowed by \(self.droppedCount, privacy: .public) entries while locked; resetting backfill so the sweep re-covers them")
        droppedCount = 0
        await overflowRecovery()
    }

    private func drainPending() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while !pending.isEmpty, isProtectedDataAvailable() {
            let chunk = Array(pending.prefix(Self.flushChunkSize))
            let epoch = pendingEpoch
            do {
                try await base.indexBatch(chunk)
            } catch where shouldRetryLater(error) {
                // Locked again, or the database is suspended: everything
                // stays buffered for the next flush.
                return
            } catch {
                // Not a transient refusal — retrying these rows would fail
                // the same way forever and wedge every entry behind them.
                // Count them as dropped so the overflow recovery re-covers
                // them from the server instead.
                Self.logger.error("search flush dropped \(chunk.count, privacy: .public) entries: \(String(describing: error), privacy: .public)")
                droppedCount += chunk.count
            }
            // The buffer was edited while the write was in flight: the chunk
            // is no longer necessarily its prefix. Go round again —
            // re-indexing an already-written entry is an idempotent upsert.
            guard epoch == pendingEpoch else { continue }
            pending.removeFirst(chunk.count)
            pendingBodyBytes -= Self.bodyBytes(chunk)
        }
    }

    private func enqueue(_ entries: [SearchIndexEntry]) {
        let bytes = Self.bodyBytes(entries)
        guard pending.count + entries.count <= maxPendingEntries,
              pendingBodyBytes + bytes <= maxPendingBodyBytes else {
            droppedCount += entries.count
            Self.logger.warning("search buffer full (\(self.pending.count, privacy: .public) entries); dropped \(entries.count, privacy: .public)")
            return
        }
        pending.append(contentsOf: entries)
        pendingBodyBytes += bytes
    }

    private func shouldRetryLater(_ error: Error) -> Bool {
        !isProtectedDataAvailable() || (error as? DatabaseError)?.isInterruptionError == true
    }

    private func requireAvailable() throws {
        guard isProtectedDataAvailable() else { throw SearchIndexUnavailable.protectedDataUnavailable }
    }

    private static func bodyBytes(_ entries: [SearchIndexEntry]) -> Int {
        entries.reduce(0) { $0 + $1.body.utf8.count }
    }

    // MARK: SearchService

    public func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        try await indexBatch([SearchIndexEntry(roomID: roomID, eventID: eventID, sender: sender,
                                               timestamp: timestamp, body: body)])
    }

    public func indexBatch(_ entries: [SearchIndexEntry]) async throws {
        guard !entries.isEmpty else { return }
        guard isProtectedDataAvailable() else {
            enqueue(entries)
            return
        }
        // A running flush drains everything appended behind it, in order.
        if flushing {
            enqueue(entries)
            return
        }
        // Something is still buffered from an earlier refusal: queue behind
        // it and try to drain now, so a missed flush trigger can't leave live
        // indexing parked in memory for the rest of the foreground session.
        if !pending.isEmpty {
            enqueue(entries)
            await flushPending()
            return
        }
        do {
            try await base.indexBatch(entries)
        } catch where shouldRetryLater(error) {
            enqueue(entries)
        }
    }

    public func remove(eventID: String) async throws {
        purgePending(eventIDs: [eventID])
        try requireAvailable()
        try await base.remove(eventID: eventID)
    }

    public func removeAll(eventIDs: [String]) async throws {
        // Purged even when the removal itself must wait: a buffered copy
        // flushed after the removal ran would resurrect the row.
        purgePending(eventIDs: Set(eventIDs))
        try requireAvailable()
        try await base.removeAll(eventIDs: eventIDs)
    }

    private func purgePending(eventIDs: Set<String>) {
        guard !pending.isEmpty, !eventIDs.isEmpty else { return }
        let kept = pending.filter { !eventIDs.contains($0.eventID) }
        guard kept.count != pending.count else { return }
        pending = kept
        pendingBodyBytes = Self.bodyBytes(kept)
        pendingEpoch &+= 1
    }

    public func query(_ text: String, limit: Int) async throws -> [SearchHit] {
        try requireAvailable()
        return try await base.query(text, limit: limit)
    }

    public func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] {
        try requireAvailable()
        return try await base.queryGrouped(text, limit: limit)
    }

    public func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] {
        try requireAvailable()
        return try await base.query(text, roomID: roomID, limit: limit)
    }

    public func wipe() async throws {
        // Sign-out/fresh-login wipes: buffered entries belong to the account
        // being wiped, so they go regardless of whether the file can be
        // reached right now.
        pending.removeAll()
        pendingBodyBytes = 0
        droppedCount = 0
        pendingEpoch &+= 1
        try requireAvailable()
        try await base.wipe()
    }

    public func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {
        try requireAvailable()
        try await base.recordBackfillProgress(roomID: roomID, indexedCount: indexedCount,
                                              oldestEventID: oldestEventID, complete: complete)
    }

    public func backfillComplete(roomID: String) async throws -> Bool {
        try requireAvailable()
        return try await base.backfillComplete(roomID: roomID)
    }

    public func backfillOldestEventID(roomID: String) async throws -> String? {
        try requireAvailable()
        return try await base.backfillOldestEventID(roomID: roomID)
    }

    public func resetBackfill() async throws {
        try requireAvailable()
        try await base.resetBackfill()
    }

    public func eventCount(roomID: String) async throws -> Int {
        try requireAvailable()
        return try await base.eventCount(roomID: roomID)
    }

    public func contains(eventID: String) async throws -> Bool {
        try requireAvailable()
        return try await base.contains(eventID: eventID)
    }
}
