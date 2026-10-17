import AppKit

/// The structural edit engine of a manually driven, single-column
/// `NSTableView`, extracted from the AppKit timeline's `applyRows` so the
/// timeline, the item thread and the list host share it.
///
/// It owns what the table believes: `ids`, the model rows in table order,
/// changed one step at a time through every structural edit, so a data
/// source that answers from `ids` is consistent even mid-edit. A client
/// that keeps storage parallel to the rows (heights, say) follows along
/// through `onEdit`, which runs right before each matching table call.
///
/// `apply(_:reconfigure:reload:)` brings the table to a new order:
/// - survivors (ids in both orders) keep their row views: removed rows go,
///   reordered survivors move with `moveRow(at:to:)`, new rows are inserted,
///   all inside one `beginUpdates`/`endUpdates`;
/// - `reconfigure` rows re-render in place when they have a view on screen
///   (the client's `configure` says whether the mounted view can take the
///   new content, or the row must reload);
/// - `reload` rows reload through `reloadData(forRowIndexes:)`;
/// - `reloadData` is used only when nothing survives (a room switch, a far
///   jump), or when `reorder` is `.reload` and survivors changed order.
///
/// Heights are the client's: `noteHeightOfRows(_:)` notes the table rows
/// whose height it changed, without animation and outside any delegate call.
///
/// Model rows can sit after `leadingRows` fixed table rows (the timeline's
/// top spacer); rows after the model rows (its footer) need nothing here.
@MainActor
final class TableRowsApplier<ID: Hashable> {
    /// What one step of an `apply` did to `ids`, in model coordinates (table
    /// row = model index + `leadingRows`), each reported before the table
    /// hears of it.
    enum Edit {
        case remove(at: Int)
        case insert(ID, at: Int)
        /// `to` is the row's index once moved, as in `moveRow(at:to:)`.
        case move(from: Int, to: Int)
        /// `ids` was replaced wholesale and `reloadData` follows.
        case reset
    }

    /// What survivors changing order does.
    enum ReorderPolicy {
        /// Move the reordered survivors: every survivor keeps its view.
        case move
        /// `reloadData`, as the AppKit timeline always has (a reorder never
        /// happens there in practice).
        case reload
    }

    /// What an `apply` did to the table structurally.
    enum Outcome: Equatable {
        /// The order was unchanged.
        case unchanged
        /// Survivors were edited in place (removes, moves, inserts).
        case edited
        /// `reloadData`.
        case reloaded
    }

    weak var tableView: NSTableView?
    let leadingRows: Int
    var reorder: ReorderPolicy
    /// The reentrancy breadcrumb's prefix (`"<label> REENTRANT-GUARD …"`).
    let label: String

    /// Called with each structural step right before the table call.
    var onEdit: ((Edit) -> Void)?

    /// The model rows the table holds, in table order.
    private(set) var ids: [ID] = []
    /// `ids`' index by id, rebuilt on demand after a structural change.
    private var indexByID: [ID: Int]?

    // MARK: Test seams

    private(set) var reloadDataCountForTesting = 0
    private(set) var moveCountForTesting = 0
    private(set) var insertCountForTesting = 0
    private(set) var removeCountForTesting = 0

    init(leadingRows: Int = 0, reorder: ReorderPolicy = .move, label: String = "TableRowsApplier") {
        self.leadingRows = leadingRows
        self.reorder = reorder
        self.label = label
    }

    /// The model index of `id`, if the table holds it.
    func index(of id: ID) -> Int? {
        if let indexByID { return indexByID[id] }
        var map: [ID: Int] = [:]
        map.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() where map[id] == nil { map[id] = index }
        indexByID = map
        return map[id]
    }

    /// The table row of `id`, if the table holds it.
    func tableRow(of id: ID) -> Int? { index(of: id).map { $0 + leadingRows } }

    /// The id at a table row, if that row is a model row.
    func id(atTableRow row: Int) -> ID? {
        let index = row - leadingRows
        return ids.indices.contains(index) ? ids[index] : nil
    }

    // MARK: Reentrancy guard

    #if DEBUG
    /// How many table delegate / data-source callbacks are on the stack.
    /// Structural edits made while it is non-zero are the "reentrant
    /// operation in its NSTableView delegate" AppKit warns about.
    private(set) var delegateDepth = 0
    /// How often the guard has fired (test seam).
    private(set) var reentrancyCountForTesting = 0
    /// Tests that provoke the guard on purpose turn the `assert` off.
    var assertsOnReentrancy = true
    #endif

    /// Wraps a delegate or data-source callback, so a structural edit made
    /// from inside it trips the guard.
    @inline(__always)
    func delegateCall<T>(_ body: () -> T) -> T {
        #if DEBUG
        delegateDepth += 1
        defer { delegateDepth -= 1 }
        #endif
        return body()
    }

    /// Logs (so an `-O -DDEBUG` build, where `assert` compiles out, still
    /// reports it) and asserts that no table delegate callback is on the
    /// stack. A no-op in Release.
    func assertOutsideDelegate(_ site: StaticString) {
        #if DEBUG
        guard delegateDepth > 0 else { return }
        reentrancyCountForTesting += 1
        NSLog("%@ REENTRANT-GUARD %@ inside a table delegate call (depth %d)\n%@",
              label, "\(site)", delegateDepth, Thread.callStackSymbols.prefix(40).joined(separator: "\n"))
        if assertsOnReentrancy {
            assert(delegateDepth == 0, "\(site) ran inside an NSTableView delegate callback")
        }
        #endif
    }

    // MARK: Applying

    /// Brings the table to `newIDs`, then re-renders `reconfigure` in place
    /// (where mounted) and reloads `reload`.
    ///
    /// `configure(view, id)` reconfigures a mounted view in place and
    /// returns `true`, or returns `false` when that view can't take the
    /// row's new content (another cell kind): the row reloads instead.
    /// Ids not in the table are skipped. Duplicate ids in `newIDs` are not
    /// supported (the caller dedupes).
    @discardableResult
    func apply(_ newIDs: [ID], reconfigure: [ID] = [], reload: [ID] = [],
               configure: (NSView, ID) -> Bool = { _, _ in false }) -> Outcome {
        assertOutsideDelegate("applyRows")
        guard let tableView else { return .unchanged }
        let outcome = applyStructure(newIDs, in: tableView)

        var reloadRows = IndexSet()
        for id in reload {
            if let row = tableRow(of: id) { reloadRows.insert(row) }
        }
        for id in reconfigure {
            guard let row = tableRow(of: id),
                  let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            if !configure(view, id) { reloadRows.insert(row) }
        }
        if !reloadRows.isEmpty {
            tableView.reloadData(forRowIndexes: reloadRows, columnIndexes: IndexSet(integer: 0))
        }
        return outcome
    }

    /// Replaces `ids` and reloads the whole table.
    func reloadData(_ newIDs: [ID]) {
        assertOutsideDelegate("reloadData")
        setIDs(newIDs)
        onEdit?(.reset)
        reloadDataCountForTesting += 1
        tableView?.reloadData()
    }

    /// `noteHeightOfRows` for `tableRows`, without animation.
    func noteHeightOfRows(_ tableRows: IndexSet) {
        assertOutsideDelegate("noteHeightOfRows")
        guard !tableRows.isEmpty, let tableView else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: tableRows)
        NSAnimationContext.endGrouping()
    }

    private func setIDs(_ newIDs: [ID]) {
        ids = newIDs
        indexByID = nil
    }

    private func applyStructure(_ newIDs: [ID], in tableView: NSTableView) -> Outcome {
        let old = ids
        guard old != newIDs else { return .unchanged }
        let newSet = Set(newIDs)
        let oldSet = Set(old)
        let survivorsOld = old.filter(newSet.contains)
        let survivorsNew = newIDs.filter(oldSet.contains)
        let reordered = survivorsOld != survivorsNew
        // However many rows leave and arrive (a capped window slide swaps
        // 120 of 360), survivors are edited in place, so every surviving
        // view stays mounted as is.
        if survivorsNew.isEmpty || (reordered && reorder == .reload) {
            reloadData(newIDs)
            return .reloaded
        }
        indexByID = nil
        tableView.beginUpdates()
        defer { tableView.endUpdates() }

        // 1. Removals, from the bottom up (old coordinates stay valid).
        let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0]) })
        if !removed.isEmpty {
            for index in removed.reversed() {
                ids.remove(at: index)
                onEdit?(.remove(at: index))
            }
            removeCountForTesting += removed.count
            tableView.removeRows(at: IndexSet(removed.map { $0 + leadingRows }), withAnimation: [])
        }

        // 2. Moves: `ids` is `survivorsOld` now; bring it to `survivorsNew`.
        if reordered {
            for (from, to) in Self.moves(from: survivorsOld, to: survivorsNew) {
                let id = ids.remove(at: from)
                ids.insert(id, at: to)
                onEdit?(.move(from: from, to: to))
                moveCountForTesting += 1
                tableView.moveRow(at: from + leadingRows, to: to + leadingRows)
            }
        }

        // 3. Insertions, top down, at their final indexes.
        let inserted = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
        if !inserted.isEmpty {
            for index in inserted {
                ids.insert(newIDs[index], at: index)
                onEdit?(.insert(newIDs[index], at: index))
            }
            insertCountForTesting += inserted.count
            tableView.insertRows(at: IndexSet(inserted.map { $0 + leadingRows }), withAnimation: [])
        }
        indexByID = nil
        return .edited
    }

    /// The `moveRow(at:to:)` steps, applied in order, that turn `current`
    /// into `target` (the same ids in another order).
    ///
    /// The rows on a longest increasing subsequence of target positions stay
    /// put; every other row moves once, so a row jumping to the top is one
    /// move however long the list. The movers are placed in target order,
    /// each right after its target predecessor, which is already in place
    /// (on the subsequence, or moved earlier): placed rows are always in
    /// target order relative to each other, and once all are placed the
    /// order is `target`. O(n log n) for the subsequence plus O(n) per move.
    static func moves(from current: [ID], to target: [ID]) -> [(from: Int, to: Int)] {
        precondition(current.count == target.count, "moves(from:to:) needs the same ids in both orders")
        guard current != target else { return [] }
        var targetIndex: [ID: Int] = [:]
        targetIndex.reserveCapacity(target.count)
        for (index, id) in target.enumerated() { targetIndex[id] = index }
        let ranks = current.map { targetIndex[$0]! }
        let stays = longestIncreasingSubsequence(ranks)   // target indexes that stay

        var order = current
        var steps: [(from: Int, to: Int)] = []
        for (rank, id) in target.enumerated() where !stays.contains(rank) {
            guard let from = order.firstIndex(of: id) else { continue }
            let to: Int
            if rank == 0 {
                to = 0
            } else {
                let predecessor = order.firstIndex(of: target[rank - 1])!
                to = from > predecessor ? predecessor + 1 : predecessor
            }
            guard from != to else { continue }
            order.remove(at: from)
            order.insert(id, at: to)
            steps.append((from, to))
        }
        assert(order == target, "moves(from:to:) left the rows out of order")
        return steps
    }

    /// The values of one longest strictly increasing subsequence of
    /// `values` (patience sorting with back-pointers).
    static func longestIncreasingSubsequence(_ values: [Int]) -> Set<Int> {
        var tailIndexes: [Int] = []          // index into `values` of each pile's top
        var previous = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0, high = tailIndexes.count
            while low < high {
                let mid = (low + high) / 2
                if values[tailIndexes[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[index] = tailIndexes[low - 1] }
            if low == tailIndexes.count { tailIndexes.append(index) } else { tailIndexes[low] = index }
        }
        var result = Set<Int>()
        var cursor = tailIndexes.last ?? -1
        while cursor >= 0 {
            result.insert(values[cursor])
            cursor = previous[cursor]
        }
        return result
    }
}
