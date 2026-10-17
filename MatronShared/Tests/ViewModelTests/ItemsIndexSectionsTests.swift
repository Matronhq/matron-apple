import XCTest
@testable import MatronJournal
import MatronModels
@testable import MatronViewModels

/// The store's items index keeps the For you sections in order as items
/// change. Its sections must be exactly `ItemsPanelViewModel.sections(from:)`
/// over the same items in the store's read order (`rank`, then `num`):
/// that is what the app-wide items panel computes with the
/// `store.changeFeed` flag off.
final class ItemsIndexSectionsTests: XCTestCase {
    private static let ids = (1...40).map { "i\($0)" }
    private static let origins = ["c1", "c2", "c3"]

    /// SplitMix64, so a failing sequence replays from its seed.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A random item from small pools, so the section orders tie often on
    /// every key before the last. `num` is fixed per id, as the journal's
    /// numbers are unique.
    private func randomItem(_ id: String, using rng: inout Generator) -> TrackerItem {
        func pick<T>(_ values: [T]) -> T { values.randomElement(using: &rng)! }
        func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: 1_900_000_000 + TimeInterval(seconds)) }
        let state: ItemState = pick([.open, .open, .closed])
        let updated = Int.random(in: 0...6, using: &rng)
        return TrackerItem(
            id: id, num: Self.ids.firstIndex(of: id)! + 1, kind: pick(ItemKind.allCases), state: state,
            resolution: state == .closed ? pick(ItemResolution.allCases) : nil,
            awaiting: pick([.user, .user, .agent, nil]), rank: pick([0, 1024, 1024, 2048]),
            title: "Item \(Int.random(in: 0...3, using: &rng))", originConvoID: pick(Self.origins),
            createdBy: pick([.agent, .agent, .user]), createdAt: at(Int.random(in: 0...4, using: &rng)),
            updatedAt: at(updated),
            closedAt: state == .closed && Bool.random(using: &rng) ? at(updated - Int.random(in: 0...2, using: &rng)) : nil,
            missionID: Bool.random(using: &rng) ? pick(["m1", "m2"]) : nil,
            lastUserInputAt: Int.random(in: 0..<3, using: &rng) == 0 ? at(Int.random(in: 0...6, using: &rng)) : nil)
    }

    private static func indexed(_ s: ItemsPanelViewModel.Sections) -> ItemsIndexSections {
        ItemsIndexSections(needsYou: s.needsYou, tasks: s.tasks, decisions: s.decisions, done: s.done, decided: s.decided)
    }

    /// The property: after every change set of a seeded random sequence
    /// (inserts, updates, closes, answers, deletions, a rowid handed to
    /// another item, an item moving to a new rowid or to another
    /// conversation, and large batches that take the rebuild path), the
    /// index's sections equal `ItemsPanelViewModel.sections(from:)` over the
    /// same items in the store's order, and each conversation's sections
    /// equal the same rule over that conversation's items.
    func testIndexSectionsEqualSectionsFromTheSameItemsAfterEveryChange() throws {
        for seed in UInt64(1)...8 {
            var rng = Generator(state: seed)
            var state = ItemsIndexState()
            var table: [Int64: ItemRecord] = [:]
            var nextRowid: Int64 = 1
            func rowid(of id: String) -> Int64? { table.first { $0.value.id == id }?.key }

            let initial = Self.ids.prefix(10).map { id -> (Int64, ItemRecord) in
                defer { nextRowid += 1 }
                return (nextRowid, ItemRecord(randomItem(id, using: &rng)))
            }
            for (rowid, record) in initial { table[rowid] = record }
            state.load(initial)
            var sawTies = false, sawDecided = false, sawLongDone = false

            for step in 0..<600 {
                var changes = RowChanges<ItemRecord>()
                let what: String
                switch Int.random(in: 0..<100, using: &rng) {
                case 0..<55:
                    // An upsert: an update in place, or a new item.
                    let id = Self.ids.randomElement(using: &rng)!
                    let record = ItemRecord(randomItem(id, using: &rng))
                    let at = rowid(of: id) ?? { defer { nextRowid += 1 }; return nextRowid }()
                    changes.upserted[at] = record
                    what = "upsert \(id)"
                case 55..<70:
                    guard let (at, record) = table.randomElement(using: &rng) else { continue }
                    changes.deleted = [at]
                    what = "delete \(record.id)"
                case 70..<78:
                    // Another item takes a deleted item's rowid.
                    guard let (at, old) = table.randomElement(using: &rng) else { continue }
                    let id = Self.ids.randomElement(using: &rng)!
                    if let held = rowid(of: id), held != at { changes.deleted.insert(held) }
                    changes.upserted[at] = ItemRecord(randomItem(id, using: &rng))
                    what = "rowid \(at) from \(old.id) to \(id)"
                case 78..<85:
                    // An item moves to a new rowid, unchanged or not.
                    guard let (at, record) = table.randomElement(using: &rng) else { continue }
                    changes.deleted = [at]
                    changes.upserted[nextRowid] = Bool.random(using: &rng)
                        ? record : ItemRecord(randomItem(record.id, using: &rng))
                    nextRowid += 1
                    what = "move \(record.id)"
                default:
                    // A catch-up page: most of the items at once.
                    for id in Self.ids.shuffled(using: &rng).prefix(Int.random(in: 10...40, using: &rng)) {
                        let at = rowid(of: id) ?? { defer { nextRowid += 1 }; return nextRowid }()
                        changes.upserted[at] = ItemRecord(randomItem(id, using: &rng))
                    }
                    what = "page \(changes.upserted.count)"
                }
                for at in changes.deleted { table[at] = nil }
                for (at, record) in changes.upserted { table[at] = record }
                state.apply(changes)

                // The store's read order: `ORDER BY rank, num`.
                let items = table.values.map(\.item).sorted { ($0.rank, $0.num) < ($1.rank, $1.num) }
                let expected = ItemsPanelViewModel.sections(from: items)
                let context = "seed \(seed) step \(step) (\(what))"
                let actual = state.sections
                XCTAssertEqual(actual.needsYou, expected.needsYou, context)
                XCTAssertEqual(actual.tasks, expected.tasks, context)
                XCTAssertEqual(actual.decisions, expected.decisions, context)
                XCTAssertEqual(actual.done, expected.done, context)
                XCTAssertEqual(actual.decided, expected.decided, context)
                for origin in Self.origins {
                    // What a chat's pane computes with the flag off: the
                    // rule over `itemsStream(scope: .convo(origin))`.
                    let own = ItemsPanelViewModel.sections(from: items.filter { $0.originConvoID == origin })
                    XCTAssertEqual(state.slice(origin: origin), Self.indexed(own), "\(context): sections of \(origin)")
                }
                if actual != Self.indexed(expected) { return }
                sawTies = sawTies || zip(actual.needsYou, actual.needsYou.dropFirst()).contains { $0.updatedAt == $1.updatedAt }
                sawDecided = sawDecided || actual.decided.contains { $0.state == .open }
                sawLongDone = sawLongDone || actual.done.count > 5
            }
            XCTAssertTrue(sawTies, "seed \(seed): ties on activity")
            XCTAssertTrue(sawDecided, "seed \(seed): an open item the user has answered")
            XCTAssertTrue(sawLongDone, "seed \(seed): a long done list")
            XCTAssertGreaterThan(state.rebuilds, 1, "seed \(seed): the rebuild path")
        }
    }

    /// The `done` cap: at most 200, the newest closes, as `sections(from:)`.
    func testDoneIsTheNewest200Closes() {
        var state = ItemsIndexState()
        let rows = (1...260).map { n -> (Int64, ItemRecord) in
            (Int64(n), ItemRecord(TrackerItem(id: "x\(n)", num: n, kind: .task, state: .closed, resolution: .done,
                                              title: "X", originConvoID: "c1",
                                              updatedAt: Date(timeIntervalSince1970: TimeInterval(n)),
                                              closedAt: Date(timeIntervalSince1970: TimeInterval(n)))))
        }
        state.load(rows)
        let items = rows.map(\.1.item)
        XCTAssertEqual(state.sections.done, ItemsPanelViewModel.sections(from: items).done)
        XCTAssertEqual(state.sections.done.count, 200)
        XCTAssertEqual(state.sections.done.first?.id, "x260")
    }
}
