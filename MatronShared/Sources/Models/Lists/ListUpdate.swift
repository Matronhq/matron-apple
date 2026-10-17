import Foundation
import os

/// A row's place in a sectioned list: its section's index and its row
/// within that section.
public struct ListPath: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var section: Int
    public var row: Int

    public init(section: Int, row: Int) {
        self.section = section
        self.row = row
    }

    public static func < (lhs: ListPath, rhs: ListPath) -> Bool {
        lhs.section != rhs.section ? lhs.section < rhs.section : lhs.row < rhs.row
    }

    public var description: String { "\(section).\(row)" }
}

/// One section of a list: its key (which a host maps to a header, or to
/// nothing) and its row ids in order.
public struct ListSection<ID: Hashable & Sendable>: Hashable, Sendable {
    public var key: String
    public var ids: [ID]

    public init(key: String, ids: [ID]) {
        self.key = key
        self.ids = ids
    }
}

/// A row that changed place: `from` in the old state's coordinates, `to`
/// in the new state's.
public struct ListMove: Hashable, Sendable, CustomStringConvertible {
    public var from: ListPath
    public var to: ListPath

    public init(from: ListPath, to: ListPath) {
        self.from = from
        self.to = to
    }

    public var description: String { "\(from)->\(to)" }
}

/// What changed between two published states of an ordered, sectioned,
/// keyed list. Computed off the main actor by the index that owns the
/// list, and applied as it is by a list host (an `NSTableView` host on the
/// Mac, later a collection view host on iOS), which then touches only the
/// rows named here.
///
/// The coordinates follow the batch-update convention: `removed` and each
/// move's `from` are paths in the OLD state (the `sections` of the update
/// before this one), `inserted` and each move's `to` are paths in the NEW
/// state (`sections`). Applying it means removing every `removed` row and
/// every moved row from the old state, then placing every inserted and
/// moved row at its new path, in ascending order (`apply(to:)`).
/// `reconfigured` rows stay where they are; their content changed.
///
/// `isReset` says the host should reload everything from `sections`: the
/// first state, a reload of the source, or an update that changed more
/// than half the rows. A reset carries no row changes.
public struct ListUpdate<ID: Hashable & Sendable>: Sendable, Equatable {
    /// The new state: every section's key and ordered ids, with no id
    /// twice anywhere in it.
    public var sections: [ListSection<ID>]
    /// Rows gone, in old coordinates, ascending.
    public var removed: [ListPath]
    /// Rows new, in new coordinates, ascending.
    public var inserted: [ListPath]
    /// Rows that changed place, possibly across sections, ascending by `to`.
    public var moved: [ListMove]
    /// Rows that kept their place but whose content changed, in new order.
    public var reconfigured: [ID]
    public var isReset: Bool

    public init(sections: [ListSection<ID>], removed: [ListPath] = [], inserted: [ListPath] = [],
                moved: [ListMove] = [], reconfigured: [ID] = [], isReset: Bool = false) {
        self.sections = sections
        self.removed = removed
        self.inserted = inserted
        self.moved = moved
        self.reconfigured = reconfigured
        self.isReset = isReset
    }

    /// Whether a host has anything to do for this update.
    public var hasChanges: Bool {
        isReset || !removed.isEmpty || !inserted.isEmpty || !moved.isEmpty || !reconfigured.isEmpty
    }

    /// The rows the new state holds.
    public var rowCount: Int { sections.reduce(0) { $0 + $1.ids.count } }

    /// A reload of `sections`, with any duplicate id after its first
    /// dropped (and a breadcrumb logged).
    public static func reset(_ sections: [ListSection<ID>]) -> ListUpdate {
        ListUpdate(sections: ListDiff.unique(sections, side: "new").sections, isReset: true)
    }

    /// The share of the rows past which `init(from:to:touched:)` resets
    /// rather than listing changes: past it, a reload is cheaper for a
    /// host than the edits.
    public static var defaultResetFraction: Double { 0.5 }

    /// The update from `old` to `new`, given every id `touched` since
    /// `old` was published: inserted, removed, moved or changed in content.
    ///
    /// Every id NOT in `touched` must be unchanged: in the same section, in
    /// the same order relative to the other untouched ids, with the same
    /// content. That is what a sorted index gives for free (a row whose
    /// sort key did not change keeps its order among the others), and what
    /// lets the diff look only at the touched rows. If the inputs break it,
    /// the update is a reset, with a breadcrumb, rather than a wrong edit.
    /// So is any change to the section keys.
    ///
    /// Duplicate ids, in either state, are dropped after their first
    /// appearance (across all sections), with a breadcrumb; `old`'s
    /// coordinates are those of `old` without its duplicates, which is the
    /// `sections` the previous update published.
    ///
    /// When more than `resetFraction` of the rows (of the larger state)
    /// changed, the update is a reset.
    ///
    /// Cost: one pass over both states, a set lookup per row, to drop
    /// duplicates, find the touched rows and check the untouched order;
    /// then O(k log k) for the k touched rows. The pass is linear because
    /// the states are plain id arrays with no sort key to search by; the
    /// indexes that call this already spend a linear pass building the
    /// value they publish alongside it.
    public init(from old: [ListSection<ID>], to new: [ListSection<ID>], touched: Set<ID>,
                resetFraction: Double = ListUpdate.defaultResetFraction) {
        self = ListDiff.update(from: old, to: new, touched: touched, resetFraction: resetFraction)
    }

    /// `old` with this update applied, or `nil` when the update does not
    /// fit `old` (a path out of range, or a different number of sections).
    /// The reference for hosts, and what the tests check updates with:
    /// removes (removed and moved-from) in old coordinates, from the
    /// bottom up, then inserts (inserted and moved-to) in new coordinates,
    /// from the top down. A reset returns `sections`.
    public func apply(to old: [ListSection<ID>]) -> [ListSection<ID>]? {
        if isReset { return sections }
        guard old.count == sections.count else { return nil }
        var rows = old.map(\.ids)
        func id(at path: ListPath, in state: [[ID]]) -> ID? {
            guard state.indices.contains(path.section), state[path.section].indices.contains(path.row) else { return nil }
            return state[path.section][path.row]
        }
        var placements: [(path: ListPath, id: ID)] = []
        placements.reserveCapacity(inserted.count + moved.count)
        for path in inserted {
            guard let id = id(at: path, in: sections.map(\.ids)) else { return nil }
            placements.append((path, id))
        }
        for move in moved {
            guard let id = id(at: move.from, in: rows) else { return nil }
            placements.append((move.to, id))
        }
        let removals = (removed + moved.map(\.from)).sorted(by: >)
        guard Set(removals).count == removals.count else { return nil }
        for path in removals {
            guard rows.indices.contains(path.section), rows[path.section].indices.contains(path.row) else { return nil }
            rows[path.section].remove(at: path.row)
        }
        for placement in placements.sorted(by: { $0.path < $1.path }) {
            let path = placement.path
            guard rows.indices.contains(path.section), path.row >= 0, path.row <= rows[path.section].count else {
                return nil
            }
            rows[path.section].insert(placement.id, at: path.row)
        }
        return zip(sections, rows).map { ListSection(key: $0.key, ids: $1) }
    }
}

/// An update and the rows it describes, delivered together so a host that
/// applies the update reads every row from the same publish: `rows` holds
/// the new state's rows in `update.sections` order, section after section.
public struct ListPublication<Row, ID: Hashable & Sendable> {
    public var update: ListUpdate<ID>
    public var rows: [Row]

    public init(update: ListUpdate<ID>, rows: [Row]) {
        self.update = update
        self.rows = rows
    }
}

extension ListPublication: Sendable where Row: Sendable {}
extension ListPublication: Equatable where Row: Equatable {}

private let listUpdateLogger = Logger(subsystem: "chat.matron", category: "list-update")

/// The computation behind `ListUpdate.init(from:to:touched:)`.
enum ListDiff {
    /// Where a touched row is in one state: its path, and its gap, the
    /// number of untouched rows before it in its section. Two states agree
    /// on the untouched rows, so a touched row whose section and gap are
    /// the same in both sits between the same untouched neighbours.
    struct Located {
        var path: ListPath
        var gap: Int
    }

    struct Scan<ID: Hashable & Sendable> {
        var sections: [ListSection<ID>]
        var touched: [ID: Located] = [:]
        var dropped = 0
    }

    /// `sections` without any id after its first, and the place of every
    /// `touched` id in the result.
    static func unique<ID>(_ sections: [ListSection<ID>], touched: Set<ID> = [], side: String) -> Scan<ID> {
        var seen = Set<ID>(minimumCapacity: sections.reduce(0) { $0 + $1.ids.count })
        var scan = Scan<ID>(sections: sections)
        for (s, section) in sections.enumerated() {
            var kept: [ID]?
            var touchedBefore = 0
            for (r, id) in section.ids.enumerated() {
                guard seen.insert(id).inserted else {
                    if kept == nil { kept = Array(section.ids[..<r]) }
                    scan.dropped += 1
                    continue
                }
                let row = kept?.count ?? r
                kept?.append(id)
                if touched.contains(id) {
                    scan.touched[id] = Located(path: ListPath(section: s, row: row), gap: row - touchedBefore)
                    touchedBefore += 1
                }
            }
            if let kept { scan.sections[s].ids = kept }
        }
        if scan.dropped > 0 {
            listUpdateLogger.breadcrumb("list update: dropped \(scan.dropped) duplicate id(s) from the \(side) state")
        }
        return scan
    }

    /// Whether every section holds its untouched ids in the same order on
    /// both sides.
    static func untouchedAgree<ID>(_ old: [ListSection<ID>], _ new: [ListSection<ID>], touched: Set<ID>) -> Bool {
        for (a, b) in zip(old, new) {
            var i = a.ids.startIndex, j = b.ids.startIndex
            while true {
                while i < a.ids.endIndex, touched.contains(a.ids[i]) { i += 1 }
                while j < b.ids.endIndex, touched.contains(b.ids[j]) { j += 1 }
                let aDone = i == a.ids.endIndex, bDone = j == b.ids.endIndex
                if aDone || bDone {
                    if aDone != bDone { return false }
                    break
                }
                if a.ids[i] != b.ids[j] { return false }
                i += 1
                j += 1
            }
        }
        return true
    }

    static func update<ID>(from rawOld: [ListSection<ID>], to rawNew: [ListSection<ID>], touched: Set<ID>,
                           resetFraction: Double) -> ListUpdate<ID> {
        let old = unique(rawOld, touched: touched, side: "old")
        let new = unique(rawNew, touched: touched, side: "new")
        guard old.sections.map(\.key) == new.sections.map(\.key) else {
            return ListUpdate(sections: new.sections, isReset: true)
        }
        guard untouchedAgree(old.sections, new.sections, touched: touched) else {
            listUpdateLogger.breadcrumb("list update: an untouched row changed place; resetting")
            return ListUpdate(sections: new.sections, isReset: true)
        }

        var removed: [ListPath] = []
        var inserted: [ListPath] = []
        var moved: [ListMove] = []
        var kept: [(path: ListPath, id: ID)] = []
        /// Touched rows on both sides with the same section and gap, per
        /// (section, gap): (old row, new row, id).
        var groups: [[Int]: [(old: ListPath, new: ListPath, id: ID)]] = [:]
        for (id, was) in old.touched {
            guard let now = new.touched[id] else {
                removed.append(was.path)
                continue
            }
            if was.path.section == now.path.section, was.gap == now.gap {
                groups[[now.path.section, now.gap], default: []].append((was.path, now.path, id))
            } else {
                moved.append(ListMove(from: was.path, to: now.path))
            }
        }
        for (id, now) in new.touched where old.touched[id] == nil { inserted.append(now.path) }

        // Within one gap, the touched rows that keep their order relative
        // to each other stay put: the longest run increasing in both
        // states. The rest move.
        for group in groups.values {
            let byOld = group.sorted { $0.old < $1.old }
            let stay = longestIncreasing(byOld.map(\.new.row))
            for (index, row) in byOld.enumerated() {
                if stay.contains(index) {
                    kept.append((row.new, row.id))
                } else {
                    moved.append(ListMove(from: row.old, to: row.new))
                }
            }
        }

        let changed = removed.count + inserted.count + moved.count + kept.count
        let rows = max(old.sections.reduce(0) { $0 + $1.ids.count }, new.sections.reduce(0) { $0 + $1.ids.count })
        if Double(changed) > Double(rows) * resetFraction {
            return ListUpdate(sections: new.sections, isReset: true)
        }
        return ListUpdate(sections: new.sections, removed: removed.sorted(), inserted: inserted.sorted(),
                          moved: moved.sorted { $0.to < $1.to },
                          reconfigured: kept.sorted { $0.path < $1.path }.map(\.id))
    }

    /// The indexes of one longest strictly increasing subsequence of
    /// `values`: O(m log m).
    static func longestIncreasing(_ values: [Int]) -> Set<Int> {
        guard !values.isEmpty else { return [] }
        // tails[l]: the index of the smallest value ending an increasing
        // run of length l + 1; parent links rebuild the run.
        var tails: [Int] = []
        var parent = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { parent[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run = Set<Int>()
        var index = tails.last ?? -1
        while index >= 0 {
            run.insert(index)
            index = parent[index]
        }
        return run
    }
}
