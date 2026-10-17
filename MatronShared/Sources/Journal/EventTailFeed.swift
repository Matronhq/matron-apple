import Foundation
import GRDB
import os

/// One delivery of `JournalStore.eventTailStream(convoID:sinceSeq:)`.
public struct EventTail: Sendable, Equatable {
    /// Every event of the conversation with `seq >= sinceSeq`, ascending:
    /// the same rows `eventsStream(convoID:sinceSeq:)` delivers.
    public var events: [JournalEvent]
    /// Seqs that were in the previous delivery and whose row has changed
    /// since: a tombstone sweep or retention rewrote it in place. A reader
    /// that memoises per seq (the timeline's mapped rows) drops those.
    public var rewrittenSeqs: Set<Int64>

    public init(events: [JournalEvent], rewrittenSeqs: Set<Int64> = []) {
        self.events = events
        self.rewrittenSeqs = rewrittenSeqs
    }
}

extension JournalStore {
    /// `eventsStream(convoID:sinceSeq:)` from the change feed: the same
    /// tail, fetched only when a commit touched this conversation's events.
    ///
    /// The value observation re-runs its fetch after every commit that
    /// touches `event` anywhere, because a `convo_id` filter is no
    /// narrower region to SQLite, so a frame in any conversation cost the
    /// open chat a fetch of its whole tail. Here a commit reaches this
    /// stream as the conversation ids and seqs it wrote (`StoreChangeSet.
    /// events`); one in another conversation is dropped without a read.
    /// One in this conversation costs one indexed fetch of the rows with
    /// a seq above the newest held, plus the held seqs the commit rewrote.
    /// A deleted held seq is dropped without one.
    ///
    /// Gap-free like the feed: the stream registers first, then reads the
    /// whole tail, so every commit is in that read or in a later change
    /// set. A reset (`wipe()`) reads the whole tail again. Change sets that
    /// land while a fetch is running are applied after it, and a fetch
    /// reads the database as it is then, so a set already reflected in it
    /// costs at most one more fetch of rows that compare equal and are not
    /// delivered again.
    ///
    /// Delivers the first tail once read, empty or not, then again only
    /// when it changes. Reads run on a reader of a pool (beside the
    /// writer) and through the queue otherwise, never on the writer inside
    /// a commit. Timed as `eventTail` in `metrics`.
    public func eventTailStream(convoID: String, sinceSeq: Int64) -> AsyncStream<EventTail> {
        // The feed's snapshot is only the registration point: the tail is
        // read afterwards, off the writer.
        let feed = changes(tables: .event) { _ in }
        let pending = EventTailPending(convoID: convoID, sinceSeq: sinceSeq)
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
                var tail = EventTailState(convoID: convoID, sinceSeq: sinceSeq)
                for await _ in wakes {
                    let work = pending.take()
                    do {
                        let update = try tail.apply(work, db: db, metrics: metrics)
                        pending.finish(holding: tail.heldSeqs)
                        if let update { continuation.yield(update) }
                    } catch {
                        // The rows read nothing; read the whole tail again
                        // shortly, as a value observation restarts.
                        pending.finish(holding: tail.heldSeqs)
                        pending.requestReload()
                        Self.eventTailLogger.error("event tail fetch failed for \(convoID, privacy: .public) — reloading in 1s: \(error.localizedDescription, privacy: .public)")
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

    private static let eventTailLogger = os.Logger(subsystem: "chat.matron", category: "event-tail")
}

/// What the change sets have asked an event tail to read since its last
/// fetch, filtered to its conversation as each set arrives, so a set that
/// touches only other conversations never wakes the reader. Shared by the
/// feed listener, which notes, and the reader, which takes.
final class EventTailPending: @unchecked Sendable {
    struct Work: Equatable {
        /// Read the whole tail: the first read, or after a reset.
        var reload = false
        /// Seqs of this conversation, at or above the anchor, that a
        /// commit inserted or updated.
        var seqs: Set<Int64> = []
        /// Deleted event rowids, which are seqs, that the tail may hold.
        var deleted: Set<Int64> = []
    }

    private let convoID: String
    private let sinceSeq: Int64
    private let lock = NSLock()
    private var work = Work()
    /// The seqs the reader held after its last fetch.
    private var held: Set<Int64> = []
    /// Whether a fetch is running: its result can hold any seq, so every
    /// deletion meanwhile is kept for the next round.
    private var reading = false

    init(convoID: String, sinceSeq: Int64) {
        self.convoID = convoID
        self.sinceSeq = sinceSeq
    }

    /// Records what `event` asks of the tail. Returns whether the reader
    /// has something to do.
    func note(_ event: StoreFeedEvent<Void>) -> Bool {
        switch event {
        case .snapshot:
            lock.withLock { work = Work(reload: true) }
            return true
        case .changes(let set):
            let mine = set.events[convoID]?.filter { $0 >= sinceSeq } ?? []
            return lock.withLock {
                let deleted = set.deletedEventRowIDs.filter { reading || held.contains($0) }
                guard !mine.isEmpty || !deleted.isEmpty else { return false }
                work.seqs.formUnion(mine)
                work.deleted.formUnion(deleted)
                return true
            }
        }
    }

    /// Takes the work noted so far, and marks a fetch as running.
    func take() -> Work {
        lock.withLock {
            defer { work = Work() }
            reading = true
            return work
        }
    }

    /// The fetch is over and the tail holds `seqs`.
    func finish(holding seqs: Set<Int64>) {
        lock.withLock {
            held = seqs
            reading = false
        }
    }

    func requestReload() {
        lock.withLock { work.reload = true }
    }
}

/// The rows an event tail holds, and the fetches that keep them current.
/// Reader-confined.
struct EventTailState {
    let convoID: String
    let sinceSeq: Int64
    /// Ascending by seq.
    private(set) var events: [JournalEvent] = []
    private var delivered = false

    init(convoID: String, sinceSeq: Int64) {
        self.convoID = convoID
        self.sinceSeq = sinceSeq
    }

    var heldSeqs: Set<Int64> { Set(events.map(\.seq)) }

    /// Applies `work`, reading what it needs, and returns the delivery to
    /// make, if the tail changed or has never been delivered.
    mutating func apply(_ work: EventTailPending.Work, db: any DatabaseReader,
                        metrics: StoreMetrics) throws -> EventTail? {
        var rewritten: Set<Int64> = []
        var changed = false
        if work.reload {
            let fresh = try metrics.measureFetch("eventTail") {
                try db.read { db in try Self.request(convoID: convoID, sinceSeq: sinceSeq).fetchAll(db).map(\.journalEvent) }
            }
            let old = Dictionary(events.map { ($0.seq, $0) }, uniquingKeysWith: { a, _ in a })
            for event in fresh {
                if let was = old[event.seq], was != event { rewritten.insert(event.seq) }
            }
            changed = fresh != events
            events = fresh
        } else {
            if !work.deleted.isEmpty {
                let before = events.count
                events.removeAll { work.deleted.contains($0.seq) }
                changed = events.count != before
            }
            if !work.seqs.isEmpty {
                let lastSeen = events.last?.seq ?? (sinceSeq - 1)
                let recheck = work.seqs.filter { $0 <= lastSeen }
                let fetched = try metrics.measureFetch("eventTail") {
                    try db.read { db in
                        try Self.request(convoID: convoID, sinceSeq: sinceSeq)
                            .filter(Column("seq") > lastSeen || recheck.contains(Column("seq")))
                            .fetchAll(db).map(\.journalEvent)
                    }
                }
                // A rechecked seq the read did not return is gone.
                let found = Set(fetched.map(\.seq))
                let gone = recheck.subtracting(found)
                if !gone.isEmpty {
                    events.removeAll { gone.contains($0.seq) }
                    changed = true
                }
                for event in fetched {
                    if event.seq > (events.last?.seq ?? Int64.min) {
                        events.append(event)
                        changed = true
                    } else if let index = index(of: event.seq) {
                        if events[index] != event {
                            events[index] = event
                            rewritten.insert(event.seq)
                            changed = true
                        }
                    } else {
                        // Below the newest held but not held: a rechecked
                        // seq that a fetch running beside a deletion had
                        // dropped, now back.
                        events.insert(event, at: insertionIndex(of: event.seq))
                        changed = true
                    }
                }
            }
        }
        guard changed || !delivered else { return nil }
        delivered = true
        return EventTail(events: events, rewrittenSeqs: rewritten)
    }

    /// The tail's rows: this conversation from `sinceSeq` up, ascending.
    static func request(convoID: String, sinceSeq: Int64) -> QueryInterfaceRequest<EventRecord> {
        EventRecord
            .filter(Column("convo_id") == convoID && Column("seq") >= sinceSeq)
            .order(Column("seq"))
    }

    private func insertionIndex(of seq: Int64) -> Int {
        var low = 0, high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].seq < seq { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func index(of seq: Int64) -> Int? {
        let i = insertionIndex(of: seq)
        return i < events.count && events[i].seq == seq ? i : nil
    }
}
