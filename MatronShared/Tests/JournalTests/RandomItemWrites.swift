import Foundation
import GRDB
import MatronModels
@testable import MatronJournal

/// Drives a `JournalStore`'s `item` table through a random sequence of its
/// real write APIs: the sync engine's upsert pages (one item, a few, or a
/// large catch-up page), the outbox drain's `commitOutboxResult`, and the
/// occasional `wipeItems()` or `wipe()`; plus deletions by SQL (no store
/// API deletes one item), including a delete and insert in one
/// transaction, which can hand a rowid to another item. Conversation
/// writes and outbox rows come along so a subscriber to the items alone
/// can be seen to hear nothing of them.
///
/// The values are drawn from small pools (a couple of dozen ids, four
/// ranks, a handful of timestamps a second apart) so ties in every section
/// order, and items moving between sections, happen often. `num` is fixed
/// per id, as the journal's numbers are unique.
struct RandomItemWrites {
    let store: JournalStore
    var rng: SeededGenerator

    static let itemIDs = (1...24).map { "i\($0)" }
    static let origins = ["c1", "c2", "c3", "c4"]
    static let missions = ["m1", "m2", "m3"]

    /// The latest `updated_at` each id was given, so most upserts move an
    /// item forward (and some go back, which `upsertItems` skips).
    private var clock: Int64 = 1_900_000_000

    init(store: JournalStore, seed: UInt64) {
        self.store = store
        self.rng = SeededGenerator(seed: seed)
    }

    /// Runs one random write and returns a short description of it, for
    /// the failure message. Every call commits at most one transaction.
    @discardableResult
    mutating func step() throws -> String {
        clock += Int64(Int.random(in: 0...2, using: &rng))
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<40:
            let item = item()
            try store.upsertItems([item])
            return "upsertItems \(item.id) \(item.kind) \(item.state)"
        case 40..<55:
            let items = (0..<Int.random(in: 2...5, using: &rng)).map { _ in item() }
            try store.upsertItems(items)
            return "upsertItems \(items.count)"
        case 55..<59:
            // A catch-up page touching most of the items.
            let ids = Self.itemIDs.shuffled(using: &rng).prefix(Int.random(in: 12...24, using: &rng))
            let items = ids.map { item(id: $0) }
            try store.upsertItems(items)
            return "upsertItems page \(items.count)"
        case 59..<68:
            let item = item()
            let localID = UUID().uuidString
            try store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: item.id, op: "comment",
                                                        payloadJSON: "{}", createdAt: clock, attempts: 0, lastError: nil))
            try store.commitOutboxResult(item: item, deletingLocalID: localID)
            return "commitOutboxResult \(item.id)"
        case 68..<76:
            let id = Self.itemIDs.randomElement(using: &rng)!
            try store.db.write { db in try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id]) }
            return "delete \(id)"
        case 76..<80:
            // Delete the newest row and insert another item: SQLite hands
            // the new row the freed rowid.
            let replacement = item()
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [replacement.id])
                try db.execute(sql: "DELETE FROM item WHERE rowid = (SELECT MAX(rowid) FROM item)")
                try ItemRecord(replacement).insert(db)
            }
            return "delete and insert \(replacement.id)"
        case 80..<88:
            try store.ensureConversation(id: Self.origins.randomElement(using: &rng)!, title: "Title")
            return "ensureConversation"
        case 88..<93:
            try store.itemOutboxInsert(ItemOutboxRecord(localID: UUID().uuidString, itemID: nil, op: "create",
                                                        payloadJSON: "{}", createdAt: clock, attempts: 0, lastError: nil))
            return "itemOutboxInsert"
        case 93..<96:
            try store.wipeItems()
            return "wipeItems"
        case 96..<97:
            try store.wipe()
            return "wipe"
        default:
            let id = Self.itemIDs.randomElement(using: &rng)!
            try store.db.write { db in
                try db.execute(sql: "UPDATE item SET state = 'closed', closed_at = ? WHERE id = ?", arguments: [clock * 1000, id])
            }
            return "close by SQL \(id)"
        }
    }

    // MARK: Values

    private mutating func item() -> TrackerItem {
        item(id: Self.itemIDs.randomElement(using: &rng)!)
    }

    private mutating func item(id: String) -> TrackerItem {
        func pick<T>(_ values: [T]) -> T { values.randomElement(using: &rng)! }
        func seconds(_ s: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }
        let num = Self.itemIDs.firstIndex(of: id)! + 1
        let kind = pick(ItemKind.allCases)
        let state: ItemState = Int.random(in: 0..<3, using: &rng) == 0 ? .closed : .open
        let awaiting: ItemAwaiting? = pick([.user, .user, .agent, nil])
        let updated = clock - Int64(Int.random(in: 0...3, using: &rng))
        let closedAt: Date? = state == .closed && Int.random(in: 0..<5, using: &rng) != 0
            ? seconds(updated - Int64(Int.random(in: 0...2, using: &rng))) : nil
        let input: Date? = Bool.random(using: &rng) ? seconds(updated - Int64(Int.random(in: 0...4, using: &rng))) : nil
        return TrackerItem(
            id: id, num: num, kind: kind, state: state,
            resolution: state == .closed ? pick(ItemResolution.allCases) : nil,
            awaiting: awaiting, rank: Double(pick([0, 1024, 1024, 2048, 4096])),
            title: "Item \(num) \(Int.random(in: 0...2, using: &rng))", originConvoID: pick(Self.origins),
            createdBy: pick([.agent, .agent, .user]),
            createdAt: seconds(1_900_000_000 + Int64(Int.random(in: 0...6, using: &rng))),
            updatedAt: seconds(updated), closedAt: closedAt,
            missionID: Bool.random(using: &rng) ? pick(Self.missions) : nil,
            lastUserInputAt: input)
    }
}
