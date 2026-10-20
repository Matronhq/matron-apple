import Foundation
import GRDB
import os

/// Some of one conversation's events, picked by an SQL condition, live:
/// what an open item follows of its origin conversation (its consent
/// cards, its queued replies).
///
/// As a value observation, such a stream re-reads every matching row
/// after every commit that touches `event` anywhere, because a `convo_id`
/// filter is no narrower region to SQLite: each frame streaming into any
/// conversation cost an open item a decode of every queue card its origin
/// conversation ever had, and a busy conversation holds hundreds. Here, as in `eventTailStream`, a commit reaches the stream as the
/// conversation ids and seqs it wrote (`StoreChangeSet.events`). A commit
/// in another conversation is dropped without a read. One in this
/// conversation reads only the seqs it wrote, by primary key, under the
/// same condition; a held seq that no longer matches is dropped, and a
/// deleted held seq is dropped without a read.
///
/// Gap-free like the feed: the stream registers first, then reads every
/// matching row. A reset (`wipe()`) reads them all again. Delivers the
/// first rows once read, empty or not, then again only when they change,
/// ascending by seq. Reads run on a reader of a pool, and through the
/// queue otherwise, never on the writer inside a commit.
struct ConvoEventsQuery: Sendable {
    /// The extra `WHERE` condition, beside `convo_id = ?`.
    let condition: String
    /// Timed under this name in `StoreMetrics`.
    let name: StaticString

    /// Every matching row of `convoID`, or, given `seqs`, those of them
    /// that match. Unordered: an `ORDER BY seq` makes SQLite prefer the
    /// `convo_id`-only index and walk the whole conversation.
    func fetch(_ db: Database, convoID: String, seqs: Set<Int64>? = nil) throws -> [JournalEvent] {
        guard let seqs else {
            return try EventRecord.fetchAll(db, sql: "SELECT * FROM event WHERE convo_id = ? AND (\(condition))",
                                            arguments: [convoID]).map(\.journalEvent)
        }
        var out: [JournalEvent] = []
        // SQLite's default limit is 999 bound variables.
        let sorted = seqs.sorted()
        for start in stride(from: 0, to: sorted.count, by: 500) {
            let chunk = Array(sorted[start..<min(start + 500, sorted.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var arguments: StatementArguments = [convoID]
            arguments += StatementArguments(chunk)
            out += try EventRecord.fetchAll(
                db, sql: "SELECT * FROM event WHERE convo_id = ? AND seq IN (\(marks)) AND (\(condition))",
                arguments: arguments).map(\.journalEvent)
        }
        return out
    }
}

extension JournalStore {
    func convoEventsFeedStream(convoID: String, query: ConvoEventsQuery) -> AsyncStream<[JournalEvent]> {
        // The feed's snapshot is only the registration point: the rows are
        // read afterwards, off the writer.
        let feed = changes(tables: .event) { _ in }
        let pending = EventTailPending(convoID: convoID, sinceSeq: 0)
        let db = self.db
        let metrics = self.metrics
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let listener = Task {
                for await event in feed where pending.note(event) {
                    wake.yield()
                }
                wake.finish()
            }
            let reader = Task {
                var state = ConvoEventsState(convoID: convoID, query: query)
                for await _ in wakes {
                    let work = pending.take()
                    do {
                        let update = try state.apply(work, db: db, metrics: metrics)
                        pending.finish(holding: state.heldSeqs)
                        if let update { continuation.yield(update) }
                    } catch {
                        // Read the rows again shortly, as a value
                        // observation restarts.
                        pending.finish(holding: state.heldSeqs)
                        pending.requestReload()
                        Self.convoEventsLogger.error("\(query.name.description, privacy: .public) fetch failed for \(convoID, privacy: .public) — reloading in 1s: \(error.localizedDescription, privacy: .public)")
                        try? await Task.sleep(for: .seconds(1))
                        wake.yield()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                listener.cancel()
                reader.cancel()
            }
        }
    }

    private static let convoEventsLogger = os.Logger(subsystem: "chat.matron", category: "convo-events")
}

/// The rows a `convoEventsFeedStream` holds. Reader-confined.
struct ConvoEventsState {
    let convoID: String
    let query: ConvoEventsQuery
    private var rows: [Int64: JournalEvent] = [:]
    private var delivered = false

    init(convoID: String, query: ConvoEventsQuery) {
        self.convoID = convoID
        self.query = query
    }

    var heldSeqs: Set<Int64> { Set(rows.keys) }

    /// Applies `work`, reading what it needs, and returns the rows to
    /// deliver, if they changed or have never been delivered.
    mutating func apply(_ work: EventTailPending.Work, db: any DatabaseReader,
                        metrics: StoreMetrics) throws -> [JournalEvent]? {
        var changed = false
        if work.reload {
            let fresh = try metrics.measureFetch(query.name) {
                try db.read { [query, convoID] db in try query.fetch(db, convoID: convoID) }
            }
            let next = Dictionary(fresh.map { ($0.seq, $0) }, uniquingKeysWith: { _, new in new })
            changed = next != rows
            rows = next
        } else {
            for seq in work.deleted where rows.removeValue(forKey: seq) != nil {
                changed = true
            }
            if !work.seqs.isEmpty {
                let fetched = try metrics.measureFetch(query.name) {
                    try db.read { [query, convoID] db in try query.fetch(db, convoID: convoID, seqs: work.seqs) }
                }
                let found = Dictionary(fetched.map { ($0.seq, $0) }, uniquingKeysWith: { _, new in new })
                // A written seq the read did not return no longer matches.
                for seq in work.seqs where found[seq] == nil && rows.removeValue(forKey: seq) != nil {
                    changed = true
                }
                for (seq, event) in found where rows[seq] != event {
                    rows[seq] = event
                    changed = true
                }
            }
        }
        guard changed || !delivered else { return nil }
        delivered = true
        return rows.values.sorted { $0.seq < $1.seq }
    }
}
