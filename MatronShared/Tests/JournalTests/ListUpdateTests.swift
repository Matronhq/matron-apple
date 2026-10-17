import MatronModels
import XCTest

/// `ListUpdate`: the update between two states of a sectioned, keyed
/// list, computed from the ids touched between them, and `apply(to:)`,
/// the reference a list host follows.
final class ListUpdateTests: XCTestCase {
    private typealias Update = ListUpdate<String>
    private typealias Section = ListSection<String>

    private func one(_ ids: [String]) -> [Section] { [Section(key: "s", ids: ids)] }
    private func path(_ section: Int, _ row: Int) -> ListPath { ListPath(section: section, row: row) }
    private let letters = (0..<10).map { String(UnicodeScalar(UInt8(97 + $0))) }

    /// What `ListUpdate` should publish for a state with duplicates: each
    /// id at its first place only.
    private func deduplicated(_ sections: [Section]) -> [Section] {
        var seen = Set<String>()
        return sections.map { section in
            Section(key: section.key, ids: section.ids.filter { seen.insert($0).inserted })
        }
    }

    // MARK: Edge cases

    func testEmptyToFullIsAResetAndInsertsEveryRowWithoutTheThreshold() {
        let new = one(["a", "b", "c"])
        let update = Update(from: one([]), to: new, touched: ["a", "b", "c"])
        XCTAssertTrue(update.isReset)
        XCTAssertEqual(update.sections, new)
        XCTAssertEqual(update.apply(to: one([])), new)

        let edits = Update(from: one([]), to: new, touched: ["a", "b", "c"], resetFraction: .infinity)
        XCTAssertFalse(edits.isReset)
        XCTAssertEqual(edits.inserted, [path(0, 0), path(0, 1), path(0, 2)])
        XCTAssertEqual(edits.removed, [])
        XCTAssertEqual(edits.moved, [])
        XCTAssertEqual(edits.apply(to: one([])), new)
    }

    func testFullToEmptyIsAResetAndRemovesEveryRowWithoutTheThreshold() {
        let old = one(["a", "b", "c"])
        let update = Update(from: old, to: one([]), touched: ["a", "b", "c"])
        XCTAssertTrue(update.isReset)
        XCTAssertEqual(update.apply(to: old), one([]))

        let edits = Update(from: old, to: one([]), touched: ["a", "b", "c"], resetFraction: .infinity)
        XCTAssertFalse(edits.isReset)
        XCTAssertEqual(edits.removed, [path(0, 0), path(0, 1), path(0, 2)])
        XCTAssertEqual(edits.inserted, [])
        XCTAssertEqual(edits.apply(to: old), one([]))
    }

    func testNothingTouchedIsNoChange() {
        let state = one(letters)
        let update = Update(from: state, to: state, touched: [])
        XCTAssertFalse(update.hasChanges)
        XCTAssertEqual(update.apply(to: state), state)
    }

    /// A row going to the top on activity: one move, nothing else.
    func testPureReorderIsOneMove() {
        let old = one(letters)
        let new = one(["j"] + letters.dropLast())
        let update = Update(from: old, to: new, touched: ["j"])
        XCTAssertFalse(update.isReset)
        XCTAssertEqual(update.moved, [ListMove(from: path(0, 9), to: path(0, 0))])
        XCTAssertEqual(update.removed, [])
        XCTAssertEqual(update.inserted, [])
        XCTAssertEqual(update.reconfigured, [])
        XCTAssertEqual(update.apply(to: old), new)
    }

    /// Two touched neighbours that swap: one of them moves, the other
    /// stays and is reconfigured.
    func testTwoTouchedNeighboursSwappingMoveOnlyOne() {
        let old = one(letters)
        var swapped = letters
        swapped.swapAt(3, 4)
        let new = one(swapped)
        let update = Update(from: old, to: new, touched: ["d", "e"])
        XCTAssertEqual(update.moved.count, 1)
        XCTAssertEqual(update.reconfigured.count, 1)
        XCTAssertEqual(update.apply(to: old), new)
    }

    func testContentOnlyChangeIsReconfiguredWithNoMove() {
        let state = one(letters)
        let update = Update(from: state, to: state, touched: ["c", "h"])
        XCTAssertFalse(update.isReset)
        XCTAssertEqual(update.reconfigured, ["c", "h"])
        XCTAssertEqual(update.moved, [])
        XCTAssertEqual(update.removed, [])
        XCTAssertEqual(update.inserted, [])
        XCTAssertEqual(update.apply(to: state), state)
    }

    /// A row answered on one tab lands on the other: a move between
    /// sections, in old and new coordinates.
    func testMoveBetweenSections() {
        let old = [Section(key: "open", ids: ["a", "b", "c", "d"]), Section(key: "done", ids: ["e", "f", "g", "h"])]
        let new = [Section(key: "open", ids: ["a", "c", "d"]), Section(key: "done", ids: ["b", "e", "f", "g", "h"])]
        let update = Update(from: old, to: new, touched: ["b"])
        XCTAssertEqual(update.moved, [ListMove(from: path(0, 1), to: path(1, 0))])
        XCTAssertEqual(update.apply(to: old), new)
    }

    func testMixedEditsInOneUpdate() {
        let old = one(letters)
        // "b" removed, "x" inserted at the top, "g" moved to the end,
        // "e" changed in place.
        let new = one(["x", "a", "c", "d", "e", "f", "h", "i", "j", "g"])
        let update = Update(from: old, to: new, touched: ["b", "x", "g", "e"])
        XCTAssertFalse(update.isReset)
        XCTAssertEqual(update.removed, [path(0, 1)])
        XCTAssertEqual(update.inserted, [path(0, 0)])
        XCTAssertEqual(update.moved, [ListMove(from: path(0, 6), to: path(0, 9))])
        XCTAssertEqual(update.reconfigured, ["e"])
        XCTAssertEqual(update.apply(to: old), new)
    }

    func testMoreThanHalfTheRowsChangedIsAReset() {
        let old = one(letters)
        let new = one(Array(letters.reversed()))
        let update = Update(from: old, to: new, touched: Set(letters))
        XCTAssertTrue(update.isReset)
        XCTAssertEqual(update.removed + update.inserted, [])
        XCTAssertEqual(update.apply(to: old), new)

        // Exactly half is not more than half.
        let half = Update(from: old, to: old, touched: Set(letters.prefix(5)))
        XCTAssertFalse(half.isReset)
        XCTAssertEqual(half.reconfigured.count, 5)
    }

    func testChangedSectionKeysAreAReset() {
        let old = [Section(key: "a", ids: ["1"]), Section(key: "b", ids: ["2"])]
        let new = [Section(key: "a", ids: ["1"])]
        let update = Update(from: old, to: new, touched: [], resetFraction: .infinity)
        XCTAssertTrue(update.isReset)
        XCTAssertEqual(update.apply(to: old), new)
    }

    /// An untouched row that changed place breaks the contract: a reset
    /// rather than a wrong edit.
    func testAnUntouchedRowOutOfPlaceIsAReset() {
        let old = one(letters)
        let new = one(["j"] + letters.dropLast())
        let update = Update(from: old, to: new, touched: [], resetFraction: .infinity)
        XCTAssertTrue(update.isReset)
        XCTAssertEqual(update.apply(to: old), new)
    }

    /// Duplicates are dropped after the first, in both states, and the
    /// old coordinates are those of the old state without its duplicates.
    func testDuplicatesAreDroppedAfterTheFirst() {
        let old = [Section(key: "s", ids: ["a", "b", "a", "c", "d", "e", "f", "g"]), Section(key: "t", ids: ["b", "h"])]
        let new = [Section(key: "s", ids: ["a", "b", "c", "d", "e", "f", "g", "c"]), Section(key: "t", ids: ["h", "a"])]
        let update = Update(from: old, to: new, touched: ["d"])
        XCTAssertFalse(update.isReset)
        XCTAssertEqual(update.sections, deduplicated(new))
        XCTAssertEqual(update.reconfigured, ["d"])
        XCTAssertEqual(update.apply(to: deduplicated(old)), deduplicated(new))

        XCTAssertEqual(Update.reset(new).sections, deduplicated(new))
    }

    func testAnUpdateThatDoesNotFitTheOldStateAppliesToNothing() {
        let update = Update(from: one(letters), to: one(["j"] + letters.dropLast()), touched: ["j"])
        XCTAssertNil(update.apply(to: one([])), "a move from a row that is not there")
        XCTAssertNil(update.apply(to: one(letters) + one([])), "a different number of sections")
    }

    // MARK: The property

    /// For random edit sequences over one to three sections (inserts,
    /// removes, moves within and between sections, content changes, ids
    /// touched with no change, duplicate ids in either state, and resets
    /// both by the threshold and by an untouched row out of place),
    /// applying each update to the state the one before it published gives
    /// the new state without its duplicates, and an update names only
    /// touched rows.
    func testApplyingTheUpdateToTheOldStateGivesTheNewState() {
        var counts = (resets: 0, edits: 0, moves: 0, crossSection: 0, inserts: 0, removes: 0, reconfigures: 0,
                      duplicates: 0)
        for seed in UInt64(1)...200 {
            var rng = SeededGenerator(seed: seed)
            let keys = Array(["first", "second", "third"].prefix(Int.random(in: 1...3, using: &rng)))
            var nextID = 0
            func freshID() -> String {
                nextID += 1
                return "r\(nextID)"
            }
            var current = keys.map { key in
                Section(key: key, ids: (0..<Int.random(in: 0...12, using: &rng)).map { _ in freshID() })
            }
            let resetFraction = Bool.random(using: &rng) ? ListUpdate<String>.defaultResetFraction : .infinity
            for step in 0..<40 {
                var next = current
                var touched = Set<String>()
                for _ in 0..<Int.random(in: 0...4, using: &rng) {
                    let s = Int.random(in: 0..<next.count, using: &rng)
                    switch Int.random(in: 0..<6, using: &rng) {
                    case 0:
                        let id = freshID()
                        next[s].ids.insert(id, at: Int.random(in: 0...next[s].ids.count, using: &rng))
                        touched.insert(id)
                    case 1 where !next[s].ids.isEmpty:
                        touched.insert(next[s].ids.remove(at: Int.random(in: 0..<next[s].ids.count, using: &rng)))
                    case 2 where !next[s].ids.isEmpty:
                        let id = next[s].ids.remove(at: Int.random(in: 0..<next[s].ids.count, using: &rng))
                        let to = Int.random(in: 0..<next.count, using: &rng)
                        next[to].ids.insert(id, at: Int.random(in: 0...next[to].ids.count, using: &rng))
                        touched.insert(id)
                    case 3 where !next[s].ids.isEmpty:
                        touched.insert(next[s].ids.randomElement(using: &rng)!)
                    case 4:
                        // A touched id that is in neither state.
                        touched.insert(freshID())
                    default:
                        break
                    }
                }
                // Duplicates in the new state: mostly after the first copy,
                // which the touched set still describes; sometimes before
                // it, which moves an untouched row and must reset.
                var raw = next
                if Int.random(in: 0..<4, using: &rng) == 0, let id = next.flatMap(\.ids).randomElement(using: &rng) {
                    let s = Int.random(in: 0..<raw.count, using: &rng)
                    if Int.random(in: 0..<4, using: &rng) == 0 {
                        raw[s].ids.insert(id, at: Int.random(in: 0...raw[s].ids.count, using: &rng))
                    } else {
                        raw[raw.count - 1].ids.append(id)
                    }
                    counts.duplicates += 1
                }
                // Sometimes the old state handed in carries duplicates too,
                // after the first copy, as a source that repeats a row would.
                var rawOld = current
                if Int.random(in: 0..<6, using: &rng) == 0, let id = current.flatMap(\.ids).randomElement(using: &rng) {
                    rawOld[rawOld.count - 1].ids.append(id)
                }

                let context = "seed \(seed) step \(step)"
                let update = ListUpdate(from: rawOld, to: raw, touched: touched, resetFraction: resetFraction)
                let expected = deduplicated(raw)
                XCTAssertEqual(update.sections, expected, context)
                guard update.apply(to: current) == expected else {
                    return XCTFail("\(context): \(current) + \(update) gave \(String(describing: update.apply(to: current))), not \(expected)")
                }
                if update.isReset {
                    counts.resets += 1
                } else {
                    counts.edits += 1
                    let named = update.removed.map { current[$0.section].ids[$0.row] }
                        + update.inserted.map { expected[$0.section].ids[$0.row] }
                        + update.moved.map { current[$0.from.section].ids[$0.from.row] } + update.reconfigured
                    XCTAssertTrue(Set(named).isSubset(of: touched), "\(context): names an untouched row")
                    XCTAssertEqual(Set(named).count, named.count, "\(context): names a row twice")
                    counts.moves += update.moved.count
                    counts.crossSection += update.moved.filter { $0.from.section != $0.to.section }.count
                    counts.inserts += update.inserted.count
                    counts.removes += update.removed.count
                    counts.reconfigures += update.reconfigured.count
                }
                current = expected
            }
        }
        // The sequences reach every kind of change.
        XCTAssertGreaterThan(counts.resets, 100)
        XCTAssertGreaterThan(counts.edits, 1_000)
        XCTAssertGreaterThan(counts.moves, 100)
        XCTAssertGreaterThan(counts.crossSection, 50)
        XCTAssertGreaterThan(counts.inserts, 100)
        XCTAssertGreaterThan(counts.removes, 100)
        XCTAssertGreaterThan(counts.reconfigures, 100)
        XCTAssertGreaterThan(counts.duplicates, 100)
    }
}
