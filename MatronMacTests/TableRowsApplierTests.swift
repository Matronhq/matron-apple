import XCTest
import AppKit
@testable import MatronMac

/// `TableRowsApplier` against a real `NSTableView` in a test window, driven
/// by seeded random edit sequences. Every row fits on screen, so every row
/// has a mounted view and a view's identity says whether it survived.
@MainActor final class TableRowsApplierTests: XCTestCase {
    // MARK: Fixture

    /// A cell that records which row it was last configured for.
    final class CountingCell: NSTableCellView {
        static let identifier = NSUserInterfaceItemIdentifier("applier.cell")
        private(set) var rowID: Int?
        func configure(_ id: Int, fixture: Fixture) {
            rowID = id
            fixture.configureCounts[id, default: 0] += 1
        }
    }

    @MainActor final class Fixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let rowHeight: CGFloat = 10
        let window: NSWindow
        let tableView = NSTableView()
        let applier: TableRowsApplier<Int>
        /// Storage kept parallel to the rows through `onEdit`.
        var parallel: [Int] = []
        /// `configure` calls per id, from `viewFor` and in-place reconfigures.
        var configureCounts: [Int: Int] = [:]
        /// A structural edit tried from inside a delegate callback.
        var editFromDelegate: (() -> Void)?

        init(leadingRows: Int, reorder: TableRowsApplier<Int>.ReorderPolicy = .move) {
            applier = TableRowsApplier<Int>(leadingRows: leadingRows, reorder: reorder, label: "ApplierTest")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 1000), styleMask: [.titled],
                              backing: .buffered, defer: false)
            super.init()
            let scrollView = NSScrollView(frame: window.contentView!.bounds)
            scrollView.autoresizingMask = [.width, .height]
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("only"))
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.intercellSpacing = .zero
            tableView.usesAutomaticRowHeights = false
            tableView.style = .plain
            tableView.dataSource = self
            tableView.delegate = self
            scrollView.documentView = tableView
            window.contentView?.addSubview(scrollView)
            applier.tableView = tableView
            applier.onEdit = { [unowned self] edit in
                switch edit {
                case .remove(let index): parallel.remove(at: index)
                case .insert(let id, let index): parallel.insert(id, at: index)
                case .move(let from, let to): parallel.insert(parallel.remove(at: from), at: to)
                case .reset: parallel = applier.ids
                }
            }
            tableView.reloadData()
            window.orderFront(nil)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { applier.ids.count + applier.leadingRows }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            applier.delegateCall {
                editFromDelegate?()
                return Self.rowHeight
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            applier.delegateCall {
                guard let id = applier.id(atTableRow: row) else { return nil }
                let cell = tableView.makeView(withIdentifier: CountingCell.identifier, owner: nil) as? CountingCell
                    ?? {
                        let cell = CountingCell(frame: .zero)
                        cell.identifier = CountingCell.identifier
                        return cell
                    }()
                cell.configure(id, fixture: self)
                return cell
            }
        }

        @discardableResult
        func apply(_ ids: [Int], reconfigure: [Int] = []) -> TableRowsApplier<Int>.Outcome {
            let outcome = applier.apply(ids, reconfigure: reconfigure) { [unowned self] view, id in
                guard let cell = view as? CountingCell else { return false }
                cell.configure(id, fixture: self)
                return true
            }
            settle()
            return outcome
        }

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            // A `reloadData` mounts the new rows' views on the next display.
            window.displayIfNeeded()
        }

        /// The mounted view of every model row, by id.
        func mountedViews(file: StaticString = #filePath, line: UInt = #line) -> [Int: CountingCell] {
            var views: [Int: CountingCell] = [:]
            for (index, id) in applier.ids.enumerated() {
                let row = index + applier.leadingRows
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? CountingCell else {
                    XCTFail("row \(row) (id \(id)) has no mounted view", file: file, line: line)
                    continue
                }
                XCTAssertEqual(cell.rowID, id, "row \(row) shows another id", file: file, line: line)
                views[id] = cell
            }
            return views
        }

        func close() {
            window.orderOut(nil)
            tableView.dataSource = nil
            tableView.delegate = nil
        }
    }

    /// A seeded generator: a failing sequence replays exactly.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// One random step: some removals, some moves, some insertions (fresh
    /// ids), and some untouched survivors to reconfigure.
    struct Step {
        var ids: [Int]
        var reconfigure: [Int]
    }

    static func randomStep(from old: [Int], nextID: inout Int, maxRows: Int, moves maxMoves: Int,
                           using rng: inout SeededGenerator) -> Step {
        var ids = old
        let removals = ids.isEmpty ? 0 : Int.random(in: 0...min(3, ids.count - 1), using: &rng)
        for _ in 0..<removals { ids.remove(at: Int.random(in: 0..<ids.count, using: &rng)) }
        let moves = ids.count < 2 ? 0 : Int.random(in: 0...maxMoves, using: &rng)
        for _ in 0..<moves {
            let from = Int.random(in: 0..<ids.count, using: &rng)
            let id = ids.remove(at: from)
            ids.insert(id, at: Int.random(in: 0...ids.count, using: &rng))
        }
        let room = maxRows - ids.count
        let insertions = room <= 0 ? 0 : Int.random(in: 0...min(3, room), using: &rng)
        for _ in 0..<insertions {
            ids.insert(nextID, at: Int.random(in: 0...ids.count, using: &rng))
            nextID += 1
        }
        let survivors = ids.filter(Set(old).contains)
        let reconfigure = survivors.filter { _ in Int.random(in: 0..<4, using: &rng) == 0 }
        return Step(ids: ids, reconfigure: reconfigure)
    }

    /// Runs `steps` random updates and checks every invariant after each.
    private func runRandomSequence(seed: UInt64, leadingRows: Int, steps: Int, maxMoves: Int,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let fixture = Fixture(leadingRows: leadingRows)
        defer { fixture.close() }
        var rng = SeededGenerator(state: seed)
        var nextID = 0
        var model = Array(0..<30)
        nextID = 30
        XCTAssertEqual(fixture.apply(model), .reloaded, file: file, line: line)   // from empty: a reload
        var views = fixture.mountedViews(file: file, line: line)
        let reloadsAfterFirst = fixture.applier.reloadDataCountForTesting

        for step in 0..<steps {
            let next = Self.randomStep(from: model, nextID: &nextID, maxRows: 50, moves: maxMoves, using: &rng)
            let before = fixture.configureCounts
            fixture.apply(next.ids, reconfigure: next.reconfigure)
            let context = "seed \(seed) step \(step)"

            // The table's ids are the model's, and so is the parallel storage.
            XCTAssertEqual(fixture.applier.ids, next.ids, context, file: file, line: line)
            XCTAssertEqual(fixture.parallel, next.ids, context, file: file, line: line)
            XCTAssertEqual(fixture.tableView.numberOfRows, next.ids.count + leadingRows, context, file: file, line: line)
            // Every row is mounted with its own id (checked by mountedViews).
            let now = fixture.mountedViews(file: file, line: line)

            // Survivors keep their views: nothing reloaded.
            let survivors = Set(model).intersection(next.ids)
            for id in survivors {
                XCTAssertTrue(now[id] === views[id], "\(context): survivor \(id) lost its view", file: file, line: line)
            }
            XCTAssertEqual(fixture.applier.reloadDataCountForTesting, reloadsAfterFirst, context, file: file, line: line)

            // Only touched rows were configured: each new row once (as it
            // was viewed), each reconfigured survivor once, the rest never.
            let reconfigured = Set(next.reconfigure)
            for id in next.ids {
                let delta = fixture.configureCounts[id, default: 0] - before[id, default: 0]
                let expected = (!survivors.contains(id) || reconfigured.contains(id)) ? 1 : 0
                XCTAssertEqual(delta, expected, "\(context): id \(id) configured \(delta)×", file: file, line: line)
            }

            #if DEBUG
            XCTAssertEqual(fixture.applier.reentrancyCountForTesting, 0, context, file: file, line: line)
            #endif
            model = next.ids
            views = now
        }
    }

    // MARK: Random sequences

    func test_randomInsertsRemovesAndMoves_keepTheTableInStepAndTouchOnlyChangedRows() {
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            runRandomSequence(seed: seed, leadingRows: 0, steps: 60, maxMoves: 2)
        }
    }

    func test_randomSequences_withALeadingSpacerRow() {
        for seed: UInt64 in [11, 12, 13] {
            runRandomSequence(seed: seed, leadingRows: 1, steps: 60, maxMoves: 2)
        }
    }

    /// Many moves per step (a busy sidebar re-sorting): still no reload.
    func test_randomSequencesWithManyMoves_neverReload() {
        for seed: UInt64 in [21, 22, 23] {
            runRandomSequence(seed: seed, leadingRows: 0, steps: 40, maxMoves: 25)
        }
        runRandomSequence(seed: 24, leadingRows: 1, steps: 40, maxMoves: 25)
    }

    /// A full shuffle of every row, repeatedly: every survivor keeps its
    /// view, nothing is reconfigured, nothing reloads.
    func test_fullShuffles_moveEveryRowWithoutReloading() {
        let fixture = Fixture(leadingRows: 0)
        defer { fixture.close() }
        var rng = SeededGenerator(state: 99)
        var model = Array(0..<50)
        fixture.apply(model)
        let views = fixture.mountedViews()
        let counts = fixture.configureCounts
        for _ in 0..<20 {
            model.shuffle(using: &rng)
            XCTAssertEqual(fixture.apply(model), .edited)
            XCTAssertEqual(fixture.applier.ids, model)
            let now = fixture.mountedViews()
            for id in model { XCTAssertTrue(now[id] === views[id]) }
        }
        XCTAssertEqual(fixture.configureCounts, counts)
        XCTAssertEqual(fixture.applier.reloadDataCountForTesting, 1)    // the first apply only
        XCTAssertGreaterThan(fixture.applier.moveCountForTesting, 0)
    }

    // MARK: Moves

    /// The sidebar case: a row with new activity jumps to the top. One
    /// move, whatever the list's length, and only that row reconfigures.
    func test_aRowMovingToTheTopIsOneMoveAndOneReconfigure() {
        let fixture = Fixture(leadingRows: 0)
        defer { fixture.close() }
        fixture.apply(Array(0..<40))
        let views = fixture.mountedViews()
        let before = fixture.configureCounts
        let next = [33] + Array(0..<40).filter { $0 != 33 }
        XCTAssertEqual(fixture.apply(next, reconfigure: [33]), .edited)
        XCTAssertEqual(fixture.applier.moveCountForTesting, 1)
        XCTAssertEqual(fixture.applier.ids, next)
        let now = fixture.mountedViews()
        for id in next { XCTAssertTrue(now[id] === views[id]) }
        XCTAssertEqual(fixture.configureCounts[33], before[33]! + 1)
        for id in next where id != 33 { XCTAssertEqual(fixture.configureCounts[id], before[id]) }
    }

    func test_movesPlan_movesOnlyRowsOffTheLongestIncreasingRun() {
        var rng = SeededGenerator(state: 7)
        for _ in 0..<500 {
            let count = Int.random(in: 0...40, using: &rng)
            let current = Array(0..<count).shuffled(using: &rng)
            let target = current.shuffled(using: &rng)
            let steps = TableRowsApplier<Int>.moves(from: current, to: target)
            var order = current
            for (from, to) in steps { order.insert(order.remove(at: from), at: to) }
            XCTAssertEqual(order, target)
            let ranks = current.map { target.firstIndex(of: $0)! }
            let run = TableRowsApplier<Int>.longestIncreasingSubsequence(ranks).count
            XCTAssertLessThanOrEqual(steps.count, count - run)
        }
        XCTAssertTrue(TableRowsApplier<Int>.moves(from: [1, 2, 3], to: [1, 2, 3]).isEmpty)
        XCTAssertEqual(TableRowsApplier<Int>.moves(from: [1, 2, 3, 4], to: [4, 1, 2, 3]).count, 1)
        XCTAssertEqual(TableRowsApplier<Int>.moves(from: [1, 2, 3, 4], to: [2, 3, 4, 1]).count, 1)
    }

    // MARK: Reloads and the reorder policy

    func test_noSurvivorsReloads() {
        let fixture = Fixture(leadingRows: 1)
        defer { fixture.close() }
        fixture.apply([1, 2, 3])
        XCTAssertEqual(fixture.apply([4, 5]), .reloaded)
        XCTAssertEqual(fixture.applier.ids, [4, 5])
        XCTAssertEqual(fixture.parallel, [4, 5])
        XCTAssertEqual(fixture.apply([4, 5]), .unchanged)
        XCTAssertEqual(fixture.applier.reloadDataCountForTesting, 2)
        _ = fixture.mountedViews()
    }

    /// The timeline's policy: a reorder reloads, and removals and
    /// insertions around survivors in order still edit in place.
    func test_reloadPolicyReloadsOnAReorderOnly() {
        let fixture = Fixture(leadingRows: 1, reorder: .reload)
        defer { fixture.close() }
        fixture.apply([1, 2, 3, 4])
        XCTAssertEqual(fixture.apply([0, 1, 3, 4, 5]), .edited)
        XCTAssertEqual(fixture.applier.reloadDataCountForTesting, 1)
        XCTAssertEqual(fixture.apply([3, 1, 4, 5]), .reloaded)
        XCTAssertEqual(fixture.applier.reloadDataCountForTesting, 2)
        XCTAssertEqual(fixture.applier.moveCountForTesting, 0)
        XCTAssertEqual(fixture.parallel, [3, 1, 4, 5])
        _ = fixture.mountedViews()
    }

    /// A reconfigure the mounted view can't take reloads that row only.
    func test_aViewThatCannotTakeTheContentReloadsItsRow() {
        let fixture = Fixture(leadingRows: 0)
        defer { fixture.close() }
        fixture.apply([1, 2, 3])
        let before = fixture.configureCounts
        fixture.applier.apply([1, 2, 3], reconfigure: [2]) { _, _ in false }
        fixture.settle()
        XCTAssertEqual(fixture.configureCounts[2], before[2]! + 1)     // viewed again after its reload
        XCTAssertEqual(fixture.configureCounts[1], before[1])
        XCTAssertEqual(fixture.configureCounts[3], before[3])
        XCTAssertEqual(fixture.applier.reloadDataCountForTesting, 1)
    }

    // MARK: Reentrancy guard

    #if DEBUG
    func test_reentrancyGuardFiresOnlyInsideADelegateCall() {
        let fixture = Fixture(leadingRows: 0)
        defer { fixture.close() }
        fixture.applier.assertsOnReentrancy = false
        fixture.apply([1, 2, 3])
        XCTAssertEqual(fixture.applier.reentrancyCountForTesting, 0)
        // A structural edit from inside a delegate callback (here: while the
        // table asks for a row height) trips it.
        fixture.editFromDelegate = { [unowned fixture] in
            fixture.editFromDelegate = nil
            fixture.applier.apply([1, 2, 3, 4])
        }
        _ = fixture.tableView(fixture.tableView, heightOfRow: 0)
        fixture.settle()
        XCTAssertEqual(fixture.applier.reentrancyCountForTesting, 1)
    }
    #endif
}
