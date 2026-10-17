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

/// The tables the feed reports. A subscriber names the ones it reads, and
/// hears only about commits that touched one of them.
public struct StoreFeedTables: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let conversation = StoreFeedTables(rawValue: 1 << 0)
    public static let item = StoreFeedTables(rawValue: 1 << 1)
    /// `item_comment`, as `ItemCommentRecord` rows.
    public static let comment = StoreFeedTables(rawValue: 1 << 2)
    /// `event`, as conversation and seq only (see `StoreChangeSet.events`).
    public static let event = StoreFeedTables(rawValue: 1 << 3)
    public static let all: StoreFeedTables = [.conversation, .item, .comment, .event]
}

/// Everything one commit changed in the tables the feed reports:
/// `conversation`, `item`, `item_comment` and `event`.
public struct StoreChangeSet: Sendable {
    /// Strictly increasing across the store's lifetime, in commit order.
    public let commit: UInt64
    public var conversations = RowChanges<ConversationRecord>()
    public var items = RowChanges<ItemRecord>()
    public var comments = RowChanges<ItemCommentRecord>()
    /// Conversation id → the seqs of its events the commit inserted or
    /// updated, ascending. Only the keys are read back, never the rows: an
    /// event row is a JSON payload, and its one reader (an open timeline)
    /// wants only its own conversation's, which it fetches itself.
    public var events: [String: [Int64]] = [:]
    /// Rowids of the events the commit deleted. An event's seq is its
    /// `INTEGER PRIMARY KEY`, so its rowid IS its seq: a reader holding
    /// seqs maps a deleted rowid straight to the seq it held there, and a
    /// rowid can never come back as another event.
    public var deletedEventRowIDs: Set<Int64> = []
    /// The tables the commit replaced wholesale (`wipe()`, `wipeItems()`),
    /// or changed in a way the feed cannot itemise. Their row changes are
    /// empty; a subscriber that reads one of them drops what it holds and
    /// reloads.
    public var resetTables: StoreFeedTables = []

    /// Whether the commit reset any table this set reports.
    public var isReset: Bool { !resetTables.isEmpty }

    public init(commit: UInt64, conversations: RowChanges<ConversationRecord> = RowChanges(),
                items: RowChanges<ItemRecord> = RowChanges(),
                comments: RowChanges<ItemCommentRecord> = RowChanges(),
                events: [String: [Int64]] = [:], deletedEventRowIDs: Set<Int64> = [],
                resetTables: StoreFeedTables = []) {
        self.commit = commit
        self.conversations = conversations
        self.items = items
        self.comments = comments
        self.events = events
        self.deletedEventRowIDs = deletedEventRowIDs
        self.resetTables = resetTables
    }

    /// Whether the commit inserted, updated or deleted any event.
    public var hasEventChanges: Bool { !events.isEmpty || !deletedEventRowIDs.isEmpty }

    /// Whether the commit changed, or reset, any of `tables`.
    func touches(_ tables: StoreFeedTables) -> Bool {
        if !resetTables.isDisjoint(with: tables) { return true }
        if tables.contains(.conversation), !conversations.isEmpty { return true }
        if tables.contains(.item), !items.isEmpty { return true }
        if tables.contains(.comment), !comments.isEmpty { return true }
        if tables.contains(.event), hasEventChanges { return true }
        return false
    }

    /// The set as a subscriber to `tables` sees it: the other tables' rows
    /// and resets left out, so a reset of the items says nothing to a
    /// reader of conversations.
    func restricted(to tables: StoreFeedTables) -> StoreChangeSet {
        guard tables != .all else { return self }
        var set = StoreChangeSet(commit: commit, resetTables: resetTables.intersection(tables))
        if tables.contains(.conversation) { set.conversations = conversations }
        if tables.contains(.item) { set.items = items }
        if tables.contains(.comment) { set.comments = comments }
        if tables.contains(.event) {
            set.events = events
            set.deletedEventRowIDs = deletedEventRowIDs
        }
        return set
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
/// Each subscriber names the tables it reads (`StoreFeedTables`). A commit
/// reaches only the subscribers whose tables it touched, and a table's rows
/// are read back only when some subscriber reads that table, so an item
/// write costs the conversation index nothing.
///
/// It sits under SQLite's update hook, so no write path can forget to
/// report a change, with two exceptions the store has to respect:
///
/// - The hook does not report rows that REPLACE conflict resolution
///   deletes. `StoreChangeFeedTests` fails if any source in this module
///   uses it.
/// - A write that clears a table wholesale, or anything that could
///   renumber rowids (VACUUM, which the store never runs), must call
///   `markReset(_:)` inside its transaction, before it deletes. `wipe()`
///   and `wipeItems()` do.
///
/// Observing deletions also turns off SQLite's truncate optimisation for
/// the four tables, so an unfiltered `DELETE` deletes row by row, except
/// inside a transaction that has already called `markReset(_:)` for that
/// table: there the feed declines the deletions (`observes(eventsOfKind:)`),
/// so a wipe of a few hundred thousand events is not recorded one rowid at
/// a time, and SQLite may truncate when nothing else observes the table.
///
/// `event` is reported by key only: conversation id and seq, never the
/// payload (see `StoreChangeSet.events`).
///
/// With no subscriber the feed resolves nothing: it records rowids and
/// drops them at the commit, so an app that reads nothing from it pays
/// almost nothing for it.
final class StoreChangeFeed: TransactionObserver, @unchecked Sendable {
    typealias Subscriber = (Database, StoreChangeSet) -> Void

    typealias Table = StoreFeedTables

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
    static let itemTable = ItemRecord.databaseTableName
    static let commentTable = ItemCommentRecord.databaseTableName
    static let eventTable = EventRecord.databaseTableName

    /// The reported table a SQLite table name stands for.
    private static func table(named name: String) -> StoreFeedTables? {
        switch name {
        case conversationTable: return .conversation
        case itemTable: return .item
        case commentTable: return .comment
        case eventTable: return .event
        default: return nil
        }
    }

    /// Bound parameters per `rowid IN (…)` query. A cold snapshot touches
    /// every conversation in one commit, and a first item sync every item;
    /// SQLite's own limit on bound
    /// parameters is far above this, but chunking keeps every statement
    /// small and cacheable whatever the build's limit.
    static let resolveChunkSize = 500

    private let metrics: StoreMetrics

    // Writer-confined: touched only from the transaction observer
    // callbacks and `markReset(_:)`, all of which run on the writer.
    private var pendingConversations: Set<Int64> = []
    private var pendingItems: Set<Int64> = []
    private var pendingComments: Set<Int64> = []
    private var pendingEvents: Set<Int64> = []
    private var pendingReset: StoreFeedTables = []
    private var lastCommit: UInt64 = 0

    private struct Registered {
        let id: UInt64
        let tables: StoreFeedTables
        let deliver: Subscriber
    }
    private let subscribers = OSAllocatedUnfairLock(initialState: (nextID: UInt64(0), list: [Registered]()))

    init(metrics: StoreMetrics) {
        self.metrics = metrics
    }

    /// Adds a raw subscriber: called on the writer, inside the
    /// `databaseDidCommit` of each commit that touched one of `tables`,
    /// with the database (readable, not writable) and the change set,
    /// restricted to `tables`. No snapshot; see `JournalStore.observeChanges`
    /// for the gap-free form. Deliveries run in subscription order.
    func subscribe(tables: StoreFeedTables = .all, _ deliver: @escaping Subscriber) -> Subscription {
        let id = subscribers.withLock { state -> UInt64 in
            state.nextID += 1
            state.list.append(Registered(id: state.nextID, tables: tables, deliver: deliver))
            return state.nextID
        }
        let subscription = Subscription()
        subscription.setOnCancel { [weak self] in
            self?.subscribers.withLock { state in state.list.removeAll { $0.id == id } }
        }
        return subscription
    }

    var subscriberCount: Int { subscribers.withLock { $0.list.count } }

    /// Marks the current transaction as a reset of `tables`. Call it on
    /// the writer, inside the transaction that clears or rewrites a
    /// reported table wholesale. A rollback forgets it.
    func markReset(_ tables: StoreFeedTables = .all) {
        pendingReset.formUnion(tables)
    }

    // MARK: TransactionObserver

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        guard let table = Self.table(named: eventKind.tableName) else { return false }
        // The transaction resets this table: its subscribers reload, so
        // its deletions need not be recorded, and declining them lets
        // SQLite truncate. Asked on the writer, as each statement is
        // compiled and run, so it sees the `markReset` that precedes it.
        if case .delete = eventKind, pendingReset.contains(table) { return false }
        return true
    }

    func databaseDidChange(with event: DatabaseEvent) {
        guard let table = Self.table(named: event.tableName), !pendingReset.contains(table) else { return }
        switch table {
        case .item: pendingItems.insert(event.rowID)
        case .comment: pendingComments.insert(event.rowID)
        case .event: pendingEvents.insert(event.rowID)
        default: pendingConversations.insert(event.rowID)
        }
    }

    /// A change GRDB could not itemise (`Database.notifyChanges(in:)`).
    /// The store makes none today; if it ever does, subscribers reload.
    func databaseDidChange() {
        pendingReset = .all
    }

    func databaseDidCommit(_ db: Database) {
        let reset = pendingReset
        // A reset table's rows are not itemised: its subscribers reload.
        // (`databaseDidChange` stops recording a table once it is reset,
        // but rows changed before the `markReset` call are still here.)
        let conversationRowids = reset.contains(.conversation) ? [] : pendingConversations
        let itemRowids = reset.contains(.item) ? [] : pendingItems
        let commentRowids = reset.contains(.comment) ? [] : pendingComments
        let eventRowids = reset.contains(.event) ? [] : pendingEvents
        clearPending()
        guard !reset.isEmpty || !conversationRowids.isEmpty || !itemRowids.isEmpty
                || !commentRowids.isEmpty || !eventRowids.isEmpty else { return }
        let targets = subscribers.withLock { $0.list }
        guard !targets.isEmpty else { return }
        // Only the tables someone reads are read back.
        let wanted = targets.reduce(into: StoreFeedTables()) { $0.formUnion($1.tables) }

        lastCommit += 1
        var set = StoreChangeSet(commit: lastCommit, resetTables: reset)
        let resolveConversations = wanted.contains(.conversation) && !conversationRowids.isEmpty
        let resolveItems = wanted.contains(.item) && !itemRowids.isEmpty
        let resolveComments = wanted.contains(.comment) && !commentRowids.isEmpty
        let resolveEvents = wanted.contains(.event) && !eventRowids.isEmpty
        if resolveConversations || resolveItems || resolveComments || resolveEvents {
            do {
                set = try metrics.measureFetch("storeChangeFeed", rows: { (resolved: StoreChangeSet) in
                    resolved.conversations.upserted.count + resolved.items.upserted.count
                        + resolved.comments.upserted.count + resolved.events.values.reduce(0) { $0 + $1.count }
                }) { [set] () -> StoreChangeSet in
                    var resolved = set
                    if resolveConversations {
                        resolved.conversations = try Self.resolve(conversationRowids) { try Self.conversationRows(db, rowids: $0) }
                    }
                    if resolveItems {
                        resolved.items = try Self.resolve(itemRowids) { try Self.itemRows(db, rowids: $0) }
                    }
                    if resolveComments {
                        resolved.comments = try Self.resolve(commentRowids) { try Self.commentRows(db, rowids: $0) }
                    }
                    if resolveEvents {
                        let keys = try Self.resolve(eventRowids) { try Self.eventKeys(db, rowids: $0) }
                        resolved.events = Dictionary(grouping: keys.upserted.values, by: \.convoID)
                            .mapValues { $0.map(\.seq).sorted() }
                        resolved.deletedEventRowIDs = keys.deleted
                    }
                    return resolved
                }
            } catch {
                // The commit happened and its rows could not be read back.
                // Publishing nothing would leave every subscriber stale for
                // good; a reset makes each of them reload instead.
                Self.logger.error("change feed could not resolve commit \(self.lastCommit): \(error.localizedDescription, privacy: .public) — publishing a reset")
                set = StoreChangeSet(commit: lastCommit, resetTables: .all)
            }
        }
        for target in targets where set.touches(target.tables) {
            target.deliver(db, set.restricted(to: target.tables))
        }
    }

    func databaseDidRollback(_ db: Database) {
        clearPending()
    }

    private func clearPending() {
        pendingConversations = []
        pendingItems = []
        pendingComments = []
        pendingEvents = []
        pendingReset = []
    }

    /// The rows still present at `rowids` as upserts, the rest as deletions.
    private static func resolve<Row>(_ rowids: Set<Int64>,
                                     _ read: (Set<Int64>) throws -> [(Int64, Row)]) rethrows -> RowChanges<Row> {
        let upserted = Dictionary(uniqueKeysWithValues: try read(rowids))
        return RowChanges(upserted: upserted, deleted: rowids.subtracting(upserted.keys))
    }

    // MARK: Reads

    private static let logger = os.Logger(subsystem: "chat.matron", category: "store-change-feed")

    /// `(rowid, row)` for every conversation, or only for `rowids`, in
    /// rowid order. The snapshot read and the per-commit resolution both
    /// come through here so the two can never decode a row differently.
    static func conversationRows(_ db: Database, rowids: Set<Int64>? = nil) throws -> [(Int64, ConversationRecord)] {
        try tableRows(db, table: conversationTable, rowids: rowids)
    }

    /// `(rowid, row)` for every item, or only for `rowids`, in rowid
    /// order; the same one-path rule as `conversationRows`.
    static func itemRows(_ db: Database, rowids: Set<Int64>? = nil) throws -> [(Int64, ItemRecord)] {
        try tableRows(db, table: itemTable, rowids: rowids)
    }

    /// `(rowid, row)` for every comment, or only for `rowids`, in rowid
    /// order; the same one-path rule as `conversationRows`.
    static func commentRows(_ db: Database, rowids: Set<Int64>? = nil) throws -> [(Int64, ItemCommentRecord)] {
        try tableRows(db, table: commentTable, rowids: rowids)
    }

    /// `(rowid, row)` for one item's comments, in rowid order: the
    /// snapshot of a thread reader (`JournalStore.commentsStream`).
    static func commentRows(_ db: Database, itemID: String) throws -> [(Int64, ItemCommentRecord)] {
        try fetchRows(db, sql: "SELECT rowid, * FROM \(commentTable) WHERE item_id = ? ORDER BY rowid",
                      arguments: [itemID])
    }

    /// An event's key, all the feed reads of an event row.
    struct EventKey: Hashable, Sendable {
        var convoID: String
        var seq: Int64
    }

    /// `(rowid, key)` for every event, or only for `rowids`, in rowid
    /// order. Reads `rowid, convo_id, seq` and nothing else.
    static func eventKeys(_ db: Database, rowids: Set<Int64>? = nil) throws -> [(Int64, EventKey)] {
        func keys(_ sql: String, _ arguments: StatementArguments) throws -> [(Int64, EventKey)] {
            var out: [(Int64, EventKey)] = []
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try cursor.next() {
                out.append((row[0], EventKey(convoID: row[1], seq: row[2])))
            }
            return out
        }
        let select = "SELECT rowid, convo_id, seq FROM \(eventTable)"
        guard let rowids else { return try keys("\(select) ORDER BY rowid", []) }
        var out: [(Int64, EventKey)] = []
        out.reserveCapacity(rowids.count)
        let sorted = rowids.sorted()
        for start in stride(from: 0, to: sorted.count, by: resolveChunkSize) {
            let chunk = Array(sorted[start..<min(start + resolveChunkSize, sorted.count)])
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            out += try keys("\(select) WHERE rowid IN (\(marks)) ORDER BY rowid", StatementArguments(chunk))
        }
        return out
    }

    private static func tableRows<Record: FetchableRecord>(_ db: Database, table: String,
                                                           rowids: Set<Int64>?) throws -> [(Int64, Record)] {
        guard let rowids else {
            return try fetchRows(db, sql: "SELECT rowid, * FROM \(table) ORDER BY rowid", arguments: [])
        }
        var rows: [(Int64, Record)] = []
        rows.reserveCapacity(rowids.count)
        let sorted = rowids.sorted()
        for start in stride(from: 0, to: sorted.count, by: resolveChunkSize) {
            let chunk = Array(sorted[start..<min(start + resolveChunkSize, sorted.count)])
            let marks = chunk.map { _ in "?" }.joined(separator: ",")
            rows += try fetchRows(
                db, sql: "SELECT rowid, * FROM \(table) WHERE rowid IN (\(marks)) ORDER BY rowid",
                arguments: StatementArguments(chunk))
        }
        return rows
    }

    private static func fetchRows<Record: FetchableRecord>(_ db: Database, sql: String,
                                                           arguments: StatementArguments) throws -> [(Int64, Record)] {
        var rows: [(Int64, Record)] = []
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try cursor.next() {
            rows.append((row["rowid"], try Record(row: row)))
        }
        return rows
    }
}

extension JournalStore {
    /// Subscribes to the change feed for `tables`, gap-free: `snapshot`
    /// reads the database in the same writer turn as the registration, so
    /// every commit is either in the snapshot or in exactly one later
    /// change set. Commits that touch none of `tables` are not delivered.
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
    /// run read-only. A commit that resets one of `tables` re-runs
    /// `snapshot` there and delivers a new `.snapshot`; a reset of another
    /// table is not this subscriber's business. If a snapshot read throws, the subscription ends
    /// and `onError` runs (on the writer); the caller decides whether to
    /// subscribe again.
    func observeChanges<Snapshot>(
        tables: StoreFeedTables,
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
            let inner = feed.subscribe(tables: tables) { db, set in
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
        tables: StoreFeedTables,
        snapshot: @escaping @Sendable (Database) throws -> Snapshot
    ) -> AsyncStream<StoreFeedEvent<Snapshot>> {
        AsyncStream { continuation in
            let holder = FeedSubscriptionHolder()
            func subscribe() {
                let subscription = observeChanges(tables: tables, snapshot: snapshot, onEvent: { event in
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
