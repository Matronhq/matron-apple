import Foundation
import GRDB
import os

/// What one table's rows did in one commit, by SQLite rowid.
///
/// Rows come as committed: the feed reads them after the commit, so a row
/// written several times in one transaction appears once, with its final
/// value, and a rowid that was deleted and then handed to a new row in the
/// same transaction is an upsert of that new row. An index keeps a
/// rowid → key map so it can drop whatever key it held at a rowid that is
/// deleted, or that now holds a different key.
public struct RowChanges<Row: Sendable>: Sendable {
    /// Rowid → the row as committed.
    public var upserted: [Int64: Row] = [:]
    /// Rowids whose row no longer exists after the commit.
    public var deleted: Set<Int64> = []

    public var isEmpty: Bool { upserted.isEmpty && deleted.isEmpty }

    public init(upserted: [Int64: Row] = [:], deleted: Set<Int64> = []) {
        self.upserted = upserted
        self.deleted = deleted
    }
}

extension RowChanges: Equatable where Row: Equatable {}

/// Everything one commit changed in the tables the feed reports. Today
/// that is `conversation` only; the item, comment and event tables join
/// with the indexes that read them, as further fields here.
public struct StoreChangeSet: Sendable {
    /// Strictly increasing across the store's lifetime, in commit order.
    public let commit: UInt64
    public var conversations = RowChanges<ConversationRecord>()
    /// The commit replaced the observed tables wholesale (`wipe()`), or
    /// changed them in a way the feed cannot itemise. The row changes are
    /// empty; a subscriber drops what it holds and reloads.
    public var isReset = false

    public init(commit: UInt64, conversations: RowChanges<ConversationRecord> = RowChanges(), isReset: Bool = false) {
        self.commit = commit
        self.conversations = conversations
        self.isReset = isReset
    }
}

/// What a snapshot subscriber of the feed receives: one `.snapshot` of the
/// database as of its registration, then one `.changes` per later commit
/// that touched a reported table, in commit order. A reset commit arrives
/// as a new `.snapshot`, read right after that commit, which replaces
/// everything the subscriber held.
public enum StoreFeedEvent<Snapshot: Sendable>: Sendable {
    case snapshot(Snapshot)
    case changes(StoreChangeSet)
}

/// Row-level change sets for the store's big tables, from one
/// `TransactionObserver` on the writer.
///
/// The `ValueObservation`s this exists to replace re-fetch a whole table
/// after every commit that touches it, and say nothing about which rows
/// changed: the chat list's fetch of every visible conversation ran on
/// every journal frame. This observer instead records the rowids SQLite
/// reports during a transaction and, in `databaseDidCommit`, still on the
/// writer, reads just those rows back with one `WHERE rowid IN (…)` query.
/// The cost per commit is the number of rows the commit touched, usually
/// one.
///
/// It sits under SQLite's update hook, so no write path can forget to
/// report a change, with two exceptions the store has to respect:
///
/// - The hook does not report rows that REPLACE conflict resolution
///   deletes. `StoreChangeFeedTests` fails if any source in this module
///   uses it.
/// - A write that clears a table wholesale, or anything that could
///   renumber rowids (VACUUM, which the store never runs), must call
///   `markReset()` inside its transaction. `wipe()` does.
///
/// Observing deletions also turns off SQLite's truncate optimisation for
/// `conversation`, so `DELETE FROM conversation` deletes row by row. The
/// only such statement is `wipe()`'s.
///
/// With no subscriber the feed resolves nothing: it records rowids and
/// drops them at the commit, so an app that reads nothing from it pays
/// almost nothing for it.
final class StoreChangeFeed: TransactionObserver, @unchecked Sendable {
    typealias Subscriber = (Database, StoreChangeSet) -> Void

    /// A live registration. Cancelling it, from any thread, stops further
    /// deliveries; a delivery already running on the writer finishes.
    final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var onCancel: (() -> Void)?

        var isCancelled: Bool { lock.withLock { cancelled } }

        /// What cancelling undoes. Runs at once if already cancelled.
        fileprivate func setOnCancel(_ body: @escaping () -> Void) {
            let runNow = lock.withLock { () -> Bool in
                guard !cancelled else { return true }
                onCancel = body
                return false
            }
            if runNow { body() }
        }

        func cancel() {
            let body = lock.withLock { () -> (() -> Void)? in
                guard !cancelled else { return nil }
                cancelled = true
                defer { onCancel = nil }
                return onCancel
            }
            body?()
        }
    }

    static let conversationTable = ConversationRecord.databaseTableName

    /// Bound parameters per `rowid IN (…)` query. A cold snapshot touches
    /// every conversation in one commit; SQLite's own limit on bound
    /// parameters is far above this, but chunking keeps every statement
    /// small and cacheable whatever the build's limit.
    static let resolveChunkSize = 500

    private let metrics: StoreMetrics

    // Writer-confined: touched only from the transaction observer
    // callbacks and `markReset()`, all of which run on the writer.
    private var pendingConversations: Set<Int64> = []
    private var pendingReset = false
    private var lastCommit: UInt64 = 0

    private struct Registered {
        let id: UInt64
        let deliver: Subscriber
    }
    private let subscribers = OSAllocatedUnfairLock(initialState: (nextID: UInt64(0), list: [Registered]()))

    init(metrics: StoreMetrics) {
        self.metrics = metrics
    }

    /// Adds a raw subscriber: called on the writer, inside each commit's
    /// `databaseDidCommit`, with the database (readable, not writable) and
    /// the change set. No snapshot; see `JournalStore.observeChanges` for
    /// the gap-free form. Deliveries run in subscription order.
    func subscribe(_ deliver: @escaping Subscriber) -> Subscription {
        let id = subscribers.withLock { state -> UInt64 in
            state.nextID += 1
            state.list.append(Registered(id: state.nextID, deliver: deliver))
            return state.nextID
        }
        let subscription = Subscription()
        subscription.setOnCancel { [weak self] in
            self?.subscribers.withLock { state in state.list.removeAll { $0.id == id } }
        }
        return subscription
    }

    var subscriberCount: Int { subscribers.withLock { $0.list.count } }

    /// Marks the current transaction as a reset. Call it on the writer,
    /// inside the transaction that clears or rewrites a reported table
    /// wholesale. A rollback forgets it.
    func markReset() {
        pendingReset = true
    }

    // MARK: TransactionObserver

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == Self.conversationTable
    }

    func databaseDidChange(with event: DatabaseEvent) {
        pendingConversations.insert(event.rowID)
    }

    /// A change GRDB could not itemise (`Database.notifyChanges(in:)`).
    /// The store makes none today; if it ever does, subscribers reload.
    func databaseDidChange() {
        pendingReset = true
    }

    func databaseDidCommit(_ db: Database) {
        let rowids = pendingConversations
        let reset = pendingReset
        pendingConversations = []
        pendingReset = false
        guard reset || !rowids.isEmpty else { return }
        let targets = subscribers.withLock { $0.list }
        guard !targets.isEmpty else { return }

        lastCommit += 1
        var set = StoreChangeSet(commit: lastCommit)
        if reset {
            set.isReset = true
        } else {
            do {
                let rows = try metrics.measureFetch("storeChangeFeed") {
                    try Self.conversationRows(db, rowids: rowids)
                }
                set.conversations.upserted = Dictionary(uniqueKeysWithValues: rows)
                set.conversations.deleted = rowids.subtracting(set.conversations.upserted.keys)
            } catch {
                // The commit happened and its rows could not be read back.
                // Publishing nothing would leave every subscriber stale for
                // good; a reset makes each of them reload instead.
                Self.logger.error("change feed could not resolve commit \(self.lastCommit): \(error.localizedDescription, privacy: .public) — publishing a reset")
                set.isReset = true
            }
        }
        for target in targets { target.deliver(db, set) }
    }

    func databaseDidRollback(_ db: Database) {
        pendingConversations = []
        pendingReset = false
    }

    // MARK: Reads

    private static let logger = os.Logger(subsystem: "chat.matron", category: "store-change-feed")

    /// `(rowid, row)` for every conversation, or only for `rowids`, in
    /// rowid order. The snapshot read and the per-commit resolution both
    /// come through here so the two can never decode a row differently.
    static func conversationRows(_ db: Database, rowids: Set<Int64>? = nil) throws -> [(Int64, ConversationRecord)] {
        guard let rowids else {
            return try fetchConversationRows(db, sql: "SELECT rowid, * FROM conversation ORDER BY rowid", arguments: [])
        }
        var rows: [(Int64, ConversationRecord)] = []
        rows.reserveCapacity(rowids.count)
        let sorted = rowids.sorted()
        for start in stride(from: 0, to: sorted.count, by: resolveChunkSize) {
            let chunk = Array(sorted[start..<min(start + resolveChunkSize, sorted.count)])
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            rows += try fetchConversationRows(
                db, sql: "SELECT rowid, * FROM conversation WHERE rowid IN (\(marks)) ORDER BY rowid",
                arguments: StatementArguments(chunk))
        }
        return rows
    }

    private static func fetchConversationRows(_ db: Database, sql: String,
                                              arguments: StatementArguments) throws -> [(Int64, ConversationRecord)] {
        var rows: [(Int64, ConversationRecord)] = []
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try cursor.next() {
            rows.append((row["rowid"], try ConversationRecord(row: row)))
        }
        return rows
    }
}

extension JournalStore {
    /// Subscribes to the change feed, gap-free: `snapshot` reads the
    /// database in the same writer turn as the registration, so every
    /// commit is either in the snapshot or in exactly one later change set.
    ///
    /// The turn is `asyncWriteWithoutTransaction`, so this returns at once
    /// and the caller's thread never waits on the writer. The snapshot is
    /// read on the writer itself, on a `DatabaseQueue` and a `DatabasePool`
    /// alike. On a pool this one function could instead register on the
    /// writer and read the snapshot with `asyncConcurrentRead`, the
    /// technique GRDB's own concurrent observer uses, so the writer is not
    /// held for the read.
    ///
    /// `onEvent` and `onError` run on the writer, synchronously inside the
    /// registration turn and each commit. They must not touch the database
    /// (the `Database` they run under is mid-commit; a write there would
    /// recurse into the feed) and must not block or wait on anything that
    /// may itself wait on the writer, which would deadlock it: copy what
    /// they need and hand the work to another queue. Reads in `snapshot`
    /// run read-only. A reset commit re-runs `snapshot` there and delivers
    /// a new `.snapshot`. If a snapshot read throws, the subscription ends
    /// and `onError` runs (on the writer); the caller decides whether to
    /// subscribe again.
    func observeChanges<Snapshot>(
        snapshot: @escaping (Database) throws -> Snapshot,
        onEvent: @escaping (StoreFeedEvent<Snapshot>) -> Void,
        onError: @escaping (Error) -> Void
    ) -> StoreChangeFeed.Subscription {
        let outer = StoreChangeFeed.Subscription()
        let feed = changeFeed
        db.asyncWriteWithoutTransaction { db in
            guard !outer.isCancelled else { return }
            do {
                onEvent(.snapshot(try db.readOnly { try snapshot(db) }))
            } catch {
                outer.cancel()
                onError(error)
                return
            }
            let inner = feed.subscribe { db, set in
                guard !outer.isCancelled else { return }
                guard set.isReset else { return onEvent(.changes(set)) }
                do {
                    onEvent(.snapshot(try db.readOnly { try snapshot(db) }))
                } catch {
                    outer.cancel()
                    onError(error)
                }
            }
            outer.setOnCancel { inner.cancel() }
        }
        return outer
    }

    /// `observeChanges` as an `AsyncStream`: the snapshot first, then one
    /// element per commit. Elements are yielded on the writer, in commit
    /// order, into an unbounded buffer, so a slow consumer delays nothing
    /// but itself. A failed snapshot read is logged and the subscription is
    /// retried after `ResubscribeBackoff`'s delay, and the retry starts with
    /// a new `.snapshot`; the same recovery `stream(_:in:)` gives the value
    /// observations, but backing off while the failures repeat.
    public func changes<Snapshot: Sendable>(
        snapshot: @escaping @Sendable (Database) throws -> Snapshot
    ) -> AsyncStream<StoreFeedEvent<Snapshot>> {
        AsyncStream { continuation in
            let holder = FeedSubscriptionHolder()
            func subscribe() {
                let subscription = observeChanges(snapshot: snapshot, onEvent: { event in
                    if case .snapshot = event { holder.recordSuccess() }
                    continuation.yield(event)
                }, onError: { error in
                    let (failures, delay) = holder.recordFailure()
                    Self.feedLogger.error("change feed snapshot failed (\(failures) in a row) — retrying in \(delay, format: .fixed(precision: 0))s: \(error.localizedDescription, privacy: .public)")
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        guard !holder.isCancelled else { return }
                        subscribe()
                    }
                })
                holder.replace(with: subscription)
            }
            subscribe()
            continuation.onTermination = { _ in holder.cancel() }
        }
    }

    private static let feedLogger = os.Logger(subsystem: "chat.matron", category: "store-change-feed")
}

/// How long to wait before subscribing to the feed again after a failure:
/// 1 s, doubling with each consecutive failure, capped at 30 s. A database
/// that keeps failing its snapshot read (I/O trouble, a suspended store
/// that stays suspended) is retried a few times a minute, not every second
/// for as long as it lasts.
struct ResubscribeBackoff {
    static let firstDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 30

    private(set) var consecutiveFailures = 0

    /// Counts a failure and returns the delay before the next attempt.
    mutating func recordFailure() -> TimeInterval {
        consecutiveFailures += 1
        let doublings = Double(min(consecutiveFailures - 1, 16))
        return min(Self.maxDelay, Self.firstDelay * pow(2, doublings))
    }

    /// A subscription delivered its snapshot: the next failure starts over.
    mutating func recordSuccess() {
        consecutiveFailures = 0
    }
}

/// The live subscription behind `JournalStore.changes(snapshot:)`, swapped
/// on each retry, plus a latch so a termination that races a retry cancels
/// whichever subscription is current, and the retry backoff.
private final class FeedSubscriptionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: StoreChangeFeed.Subscription?
    private var cancelled = false
    private var backoff = ResubscribeBackoff()

    func recordFailure() -> (failures: Int, delay: TimeInterval) {
        lock.withLock {
            let delay = backoff.recordFailure()
            return (backoff.consecutiveFailures, delay)
        }
    }

    func recordSuccess() {
        lock.withLock { backoff.recordSuccess() }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func replace(with new: StoreChangeFeed.Subscription) {
        let cancelNow = lock.withLock { () -> Bool in
            subscription = new
            return cancelled
        }
        if cancelNow { new.cancel() }
    }

    func cancel() {
        let current = lock.withLock { () -> StoreChangeFeed.Subscription? in
            cancelled = true
            return subscription
        }
        current?.cancel()
    }
}
