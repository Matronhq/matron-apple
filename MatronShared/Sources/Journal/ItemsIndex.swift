import Foundation
import GRDB
import MatronModels
import os

/// The tracker sections the items panel shows, as one value: the panel's
/// `Sections` rule applied to every item in the store (the For you list),
/// or to one origin conversation's items (a chat's items pane).
///
/// - `needsYou`: open and awaiting the user (`TrackerItem.needsUser`),
///   newest `updatedAt` first.
/// - `tasks`: open tasks, by `rank` then `num`.
/// - `decisions`: open decisions, newest `createdAt` first.
/// - `done`: closed items, newest `closedAt` first (none last), at most
///   `ItemsIndexState.doneLimit`.
/// - `decided`: what For you's Done tab lists (`TrackerItem.isDoneForUser`),
///   newest `closedSortDate` first, then `num` descending.
///
/// Ties fall back to the order the store's item read returns
/// (`rank`, then `num`), which is what makes these equal to
/// `ItemsPanelViewModel.sections(from:)` over that read.
public struct ItemsIndexSections: Equatable, Sendable {
    public var needsYou: [TrackerItem] = []
    public var tasks: [TrackerItem] = []
    public var decisions: [TrackerItem] = []
    public var done: [TrackerItem] = []
    public var decided: [TrackerItem] = []

    public init(needsYou: [TrackerItem] = [], tasks: [TrackerItem] = [], decisions: [TrackerItem] = [],
                done: [TrackerItem] = [], decided: [TrackerItem] = []) {
        self.needsYou = needsYou
        self.tasks = tasks
        self.decisions = decisions
        self.done = done
        self.decided = decided
    }
}

/// Every item row by id, kept current from `StoreChangeFeed` change sets,
/// with the lists the tracker surfaces read kept in order as rows change:
///
/// - the app-wide sections (`ItemsIndexSections`, the For you list), and
///   the same five sections for each origin conversation (a chat's pane);
/// - the needs-you count per conversation (`JournalStore.needsUserCounts()`);
/// - per mission: its needs-you items (`needsYouItemsByMission()`), its
///   open items (`items(missionID:)`, the mission page) and its closed
///   items (`closedItemsStream(missionID:limit:)`). A project's item lists
///   are its missions' lists merged.
///
/// Each list is a sorted array. A changed item leaves the lists its old
/// value was in and joins the ones its new value belongs to, by binary
/// search, so one item write touches only those lists, and only in its own
/// conversation and mission: `apply` says which were touched, and the
/// published `sections` and `slices` values replace only those, so every
/// other section keeps the storage it had. A commit that changes more than
/// an eighth of the items (a first sync, a catch-up page) sorts every list
/// once instead.
///
/// A value type with no clock and no queue, so the equivalence tests can
/// drive it synchronously; `ItemsIndex` is the live host.
struct ItemsIndexState {
    /// The five section lists (`closed` backs `done`).
    struct Lists: OptionSet, Hashable {
        let rawValue: Int
        static let needsYou = Lists(rawValue: 1 << 0)
        static let tasks = Lists(rawValue: 1 << 1)
        static let decisions = Lists(rawValue: 1 << 2)
        static let closed = Lists(rawValue: 1 << 3)
        static let decided = Lists(rawValue: 1 << 4)
        static let all: Lists = [.needsYou, .tasks, .decisions, .closed, .decided]
    }

    /// What one change set changed: the app-wide lists; per origin
    /// conversation, its lists; whether the needs-you counts changed; the
    /// missions whose needs-you items changed; and the missions any of
    /// whose lists (open, closed, needs-you) changed.
    struct Touched: Equatable {
        var lists: Lists = []
        var origins: [String: Lists] = [:]
        var needsUserCounts = false
        var missions: Set<String> = []
        var missionItems: Set<String> = []

        var isEmpty: Bool {
            lists.isEmpty && origins.isEmpty && !needsUserCounts && missions.isEmpty && missionItems.isEmpty
        }
    }

    /// The `done` section's cap, as `ItemsPanelViewModel.sections(from:)`
    /// has it.
    static let doneLimit = 200

    /// One list's order. Every order ends on the item id, so it is total
    /// and an item's place in a list is found by binary search.
    enum Order {
        case needsYou, tasks, decisions, closed, decided
        /// `ORDER BY updated_at DESC, num DESC`: the mission and project
        /// queries' order.
        case recency
        /// `ORDER BY COALESCE(closed_at, updated_at) DESC, num DESC`: a
        /// mission's closed items.
        case missionClosed

        func precedes(_ a: TrackerItem, _ b: TrackerItem) -> Bool {
            switch self {
            case .needsYou:
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            case .tasks:
                break
            case .decisions:
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .closed:
                let l = a.closedAt ?? .distantPast, r = b.closedAt ?? .distantPast
                if l != r { return l > r }
            case .decided:
                let l = a.closedSortDate, r = b.closedSortDate
                if l != r { return l > r }
                if a.num != b.num { return a.num > b.num }
            case .recency:
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                if a.num != b.num { return a.num > b.num }
                return a.id < b.id
            case .missionClosed:
                let l = a.closedAt ?? a.updatedAt, r = b.closedAt ?? b.updatedAt
                if l != r { return l > r }
                if a.num != b.num { return a.num > b.num }
                return a.id < b.id
            }
            // The store's read order: `ORDER BY rank, num`.
            if a.rank != b.rank { return a.rank < b.rank }
            if a.num != b.num { return a.num < b.num }
            return a.id < b.id
        }
    }

    /// The five section lists over some set of items, each kept sorted.
    struct SectionLists {
        private(set) var needsYou: [TrackerItem] = []
        private(set) var tasks: [TrackerItem] = []
        private(set) var decisions: [TrackerItem] = []
        private(set) var closed: [TrackerItem] = []
        private(set) var decided: [TrackerItem] = []

        var isEmpty: Bool {
            needsYou.isEmpty && tasks.isEmpty && decisions.isEmpty && closed.isEmpty && decided.isEmpty
        }

        init() {}

        /// Every list sorted from scratch.
        init(_ items: [TrackerItem]) {
            func sorted(_ list: Lists, _ order: Order) -> [TrackerItem] {
                items.filter { ItemsIndexState.lists(of: $0).contains(list) }.sorted(by: order.precedes)
            }
            needsYou = sorted(.needsYou, .needsYou)
            tasks = sorted(.tasks, .tasks)
            decisions = sorted(.decisions, .decisions)
            closed = sorted(.closed, .closed)
            decided = sorted(.decided, .decided)
        }

        mutating func insert(_ item: TrackerItem, into lists: Lists) {
            if lists.contains(.needsYou) { ItemsIndexState.insert(item, into: &needsYou, .needsYou) }
            if lists.contains(.tasks) { ItemsIndexState.insert(item, into: &tasks, .tasks) }
            if lists.contains(.decisions) { ItemsIndexState.insert(item, into: &decisions, .decisions) }
            if lists.contains(.closed) { ItemsIndexState.insert(item, into: &closed, .closed) }
            if lists.contains(.decided) { ItemsIndexState.insert(item, into: &decided, .decided) }
        }

        mutating func remove(_ item: TrackerItem, from lists: Lists) {
            if lists.contains(.needsYou) { ItemsIndexState.remove(item, from: &needsYou, .needsYou) }
            if lists.contains(.tasks) { ItemsIndexState.remove(item, from: &tasks, .tasks) }
            if lists.contains(.decisions) { ItemsIndexState.remove(item, from: &decisions, .decisions) }
            if lists.contains(.closed) { ItemsIndexState.remove(item, from: &closed, .closed) }
            if lists.contains(.decided) { ItemsIndexState.remove(item, from: &decided, .decided) }
        }

        /// Copies `lists` into `sections`, leaving the rest alone.
        func copy(_ lists: Lists, into sections: inout ItemsIndexSections) {
            if lists.contains(.needsYou) { sections.needsYou = needsYou }
            if lists.contains(.tasks) { sections.tasks = tasks }
            if lists.contains(.decisions) { sections.decisions = decisions }
            if lists.contains(.closed) { sections.done = Array(closed.prefix(ItemsIndexState.doneLimit)) }
            if lists.contains(.decided) { sections.decided = decided }
        }
    }

    private struct Entry: Equatable {
        var rowid: Int64
        var item: TrackerItem
        /// The stored row's own `state` and `awaiting` columns, which the
        /// count, mission and project queries filter and sort on, rather
        /// than the decoded item's (which reads an unknown value as a
        /// default).
        var isOpenRow: Bool
        var isClosedRow: Bool
        /// `(awaiting = 'user')` under `DESC`: 2 for `'user'`, 1 for any
        /// other value, 0 for NULL, which SQLite sorts last.
        var awaitingTier: Int

        init(rowid: Int64, record: ItemRecord) {
            self.rowid = rowid
            item = record.item
            isOpenRow = record.state == "open"
            isClosedRow = record.state == "closed"
            awaitingTier = record.awaiting.map { $0 == "user" ? 2 : 1 } ?? 0
        }

        /// `state = 'open' AND awaiting = 'user'`.
        var awaitsUser: Bool { isOpenRow && awaitingTier == 2 }
        var missionAwaitingUser: String? { awaitsUser ? item.missionID : nil }
        var missionOpen: String? { isOpenRow ? item.missionID : nil }
        var missionClosed: String? { isClosedRow ? item.missionID : nil }
    }

    private var entries: [String: Entry] = [:]
    private var idByRowid: [Int64: String] = [:]
    private var all = SectionLists()
    private var byOrigin: [String: SectionLists] = [:]
    /// `JournalStore.needsUserCounts()`.
    private(set) var needsUserCounts: [String: Int] = [:]
    /// `JournalStore.needsYouItemsByMission()`.
    private(set) var needsYouByMission: [String: [TrackerItem]] = [:]
    /// Each mission's open items, in `recency` order.
    private var openByMission: [String: [TrackerItem]] = [:]
    /// Each mission's closed items, in `missionClosed` order.
    private var closedByMission: [String: [TrackerItem]] = [:]
    /// The app-wide sections. Only the touched lists are replaced by a
    /// change, so an untouched section keeps the storage it had, and a
    /// consumer comparing it with the one it holds pays nothing for it.
    private(set) var sections = ItemsIndexSections()
    /// Each origin conversation's sections, kept the same way. A
    /// conversation with no item in any section has no entry.
    private(set) var slices: [String: ItemsIndexSections] = [:]
    /// How many times the lists have been sorted from scratch since the
    /// last load (the load included). How the tests tell the two paths
    /// apart.
    private(set) var rebuilds = 0

    var count: Int { entries.count }

    // MARK: Projections

    /// One origin conversation's sections: `sections(from:)` over its
    /// items.
    func slice(origin convoID: String) -> ItemsIndexSections { slices[convoID] ?? ItemsIndexSections() }

    /// `JournalStore.items(missionID:)`: the mission's open items, those
    /// awaiting the user first, then newest activity.
    func openItems(missionID: String) -> [TrackerItem] {
        let open = openByMission[missionID] ?? []
        // A stable partition of the `recency` order by the awaiting tier.
        var tiers: [[TrackerItem]] = [[], [], []]
        for item in open { tiers[2 - (entries[item.id]?.awaitingTier ?? 0)].append(item) }
        return tiers[0] + tiers[1] + tiers[2]
    }

    /// `JournalStore.closedItemsStream(missionID:limit:)`'s value.
    func closedItems(missionID: String, limit: Int) -> [TrackerItem] {
        Array((closedByMission[missionID] ?? []).prefix(max(0, limit)))
    }

    /// `JournalStore.closedItemsCountStream(missionID:)`'s value.
    func closedItemsCount(missionID: String) -> Int { closedByMission[missionID]?.count ?? 0 }

    /// The open items awaiting the user across `missionIDs` (a project's
    /// missions), newest activity first: `needsYouItemsStream(projectID:)`.
    func needsYouItems(missionIDs: Set<String>) -> [TrackerItem] {
        Self.merged(missionIDs.compactMap { needsYouByMission[$0] })
    }

    /// Every open item across `missionIDs`, newest activity first:
    /// `openItemsStream(projectID:)`.
    func openItems(missionIDs: Set<String>) -> [TrackerItem] {
        Self.merged(missionIDs.compactMap { openByMission[$0] })
    }

    /// Lists already in `recency` order, merged into one.
    private static func merged(_ lists: [[TrackerItem]]) -> [TrackerItem] {
        lists.count == 1 ? lists[0] : lists.flatMap { $0 }.sorted(by: Order.recency.precedes)
    }

    /// The section lists an item belongs to.
    static func lists(of item: TrackerItem) -> Lists {
        var lists: Lists = []
        if item.needsUser { lists.insert(.needsYou) }
        if item.state == .open, item.kind == .task { lists.insert(.tasks) }
        if item.state == .open, item.kind == .decision { lists.insert(.decisions) }
        if item.state == .closed { lists.insert(.closed) }
        if item.isDoneForUser { lists.insert(.decided) }
        return lists
    }

    // MARK: Applying the feed

    /// Applies one feed event and returns what it changed, or `nil` for a
    /// snapshot, which replaces everything.
    @discardableResult
    mutating func apply(_ event: StoreFeedEvent<[(Int64, ItemRecord)]>) -> Touched? {
        switch event {
        case .snapshot(let rows):
            load(rows)
            return nil
        case .changes(let set):
            // `observeChanges` turns a reset into a new snapshot.
            return apply(set.items)
        }
    }

    /// Replaces everything with `rows`, sorting each list once.
    mutating func load(_ rows: [(Int64, ItemRecord)]) {
        self = ItemsIndexState()
        for (rowid, record) in rows { insert(Entry(rowid: rowid, record: record), placing: false) }
        rebuildLists()
        all.copy(.all, into: &sections)
        for origin in byOrigin.keys { publish(.all, origin: origin) }
    }

    /// Deletions first, then upserts: a rowid that was deleted and handed
    /// to a new row in the same commit drops the item it held, and an item
    /// that moved to a new rowid drops its old one.
    @discardableResult
    mutating func apply(_ changes: RowChanges<ItemRecord>) -> Touched {
        let rebuild = changes.upserted.count + changes.deleted.count > entries.count / 8
        var originals: [String: Entry?] = [:]
        func remember(_ id: String) {
            if originals[id] == nil { originals[id] = .some(entries[id]) }
        }
        for rowid in changes.deleted.sorted() {
            guard let id = idByRowid[rowid] else { continue }
            remember(id)
            remove(id, placing: !rebuild)
        }
        for (rowid, record) in changes.upserted.sorted(by: { $0.key < $1.key }) {
            if let held = idByRowid[rowid], held != record.id {
                remember(held)
                remove(held, placing: !rebuild)
            }
            remember(record.id)
            let entry = Entry(rowid: rowid, record: record)
            guard entries[record.id] != entry else { continue }
            remove(record.id, placing: !rebuild)
            insert(entry, placing: !rebuild)
        }
        if rebuild { rebuildLists() }

        var touched = Touched()
        for (id, old) in originals {
            let new = entries[id]
            guard old?.item != new?.item || old?.isOpenRow != new?.isOpenRow || old?.isClosedRow != new?.isClosedRow
                    || old?.awaitingTier != new?.awaitingTier else { continue }
            for entry in [old, new].compactMap({ $0 }) {
                let lists = Self.lists(of: entry.item)
                touched.lists.formUnion(lists)
                if !lists.isEmpty { touched.origins[entry.item.originConvoID, default: []].formUnion(lists) }
                if entry.awaitsUser { touched.needsUserCounts = true }
                if let mission = entry.missionAwaitingUser { touched.missions.insert(mission) }
                if let mission = entry.missionOpen ?? entry.missionClosed { touched.missionItems.insert(mission) }
            }
        }
        all.copy(touched.lists, into: &sections)
        for (origin, lists) in touched.origins { publish(lists, origin: origin) }
        return touched
    }

    /// Copies one origin's touched lists into its slice, or drops the slice
    /// once nothing of the conversation is in any section.
    private mutating func publish(_ lists: Lists, origin: String) {
        guard let own = byOrigin[origin] else {
            slices[origin] = nil
            return
        }
        own.copy(lists, into: &slices[origin, default: ItemsIndexSections()])
    }

    private mutating func insert(_ entry: Entry, placing: Bool) {
        let item = entry.item
        entries[item.id] = entry
        idByRowid[entry.rowid] = item.id
        guard placing else { return }
        let lists = Self.lists(of: item)
        all.insert(item, into: lists)
        if !lists.isEmpty { byOrigin[item.originConvoID, default: SectionLists()].insert(item, into: lists) }
        if entry.awaitsUser { needsUserCounts[item.originConvoID, default: 0] += 1 }
        if let mission = entry.missionAwaitingUser { Self.insert(item, into: &needsYouByMission[mission, default: []], .recency) }
        if let mission = entry.missionOpen { Self.insert(item, into: &openByMission[mission, default: []], .recency) }
        if let mission = entry.missionClosed {
            Self.insert(item, into: &closedByMission[mission, default: []], .missionClosed)
        }
    }

    private mutating func remove(_ id: String, placing: Bool) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if idByRowid[entry.rowid] == id { idByRowid[entry.rowid] = nil }
        guard placing else { return }
        let item = entry.item
        let origin = item.originConvoID
        let lists = Self.lists(of: item)
        all.remove(item, from: lists)
        if !lists.isEmpty {
            byOrigin[origin]?.remove(item, from: lists)
            if byOrigin[origin]?.isEmpty == true { byOrigin[origin] = nil }
        }
        if entry.awaitsUser {
            let left = (needsUserCounts[origin] ?? 0) - 1
            needsUserCounts[origin] = left > 0 ? left : nil
        }
        if let mission = entry.missionAwaitingUser { Self.remove(item, from: &needsYouByMission, mission, .recency) }
        if let mission = entry.missionOpen { Self.remove(item, from: &openByMission, mission, .recency) }
        if let mission = entry.missionClosed { Self.remove(item, from: &closedByMission, mission, .missionClosed) }
    }

    /// Sorts every list from scratch: O(n log n), against the O(n) one
    /// sorted insert or removal costs in array moves.
    private mutating func rebuildLists() {
        let values = Array(entries.values)
        all = SectionLists(values.map(\.item))
        byOrigin = Dictionary(grouping: values.map(\.item), by: \.originConvoID)
            .mapValues(SectionLists.init).filter { !$0.value.isEmpty }
        needsUserCounts = [:]
        var needsYou: [String: [TrackerItem]] = [:], open: [String: [TrackerItem]] = [:]
        var closed: [String: [TrackerItem]] = [:]
        for entry in values {
            if entry.awaitsUser { needsUserCounts[entry.item.originConvoID, default: 0] += 1 }
            if let mission = entry.missionAwaitingUser { needsYou[mission, default: []].append(entry.item) }
            if let mission = entry.missionOpen { open[mission, default: []].append(entry.item) }
            if let mission = entry.missionClosed { closed[mission, default: []].append(entry.item) }
        }
        needsYouByMission = needsYou.mapValues { $0.sorted(by: Order.recency.precedes) }
        openByMission = open.mapValues { $0.sorted(by: Order.recency.precedes) }
        closedByMission = closed.mapValues { $0.sorted(by: Order.missionClosed.precedes) }
        rebuilds += 1
    }

    // MARK: Checking

    /// Where this state's projections differ from `fresh`'s, a state loaded
    /// from a full read: empty when they agree. The Debug-only consistency
    /// check (`ItemsIndex`) logs what this returns.
    func mismatches(against fresh: ItemsIndexState) -> [String] {
        var found: [String] = []
        if count != fresh.count { found.append("count \(count) != \(fresh.count)") }
        if sections != fresh.sections { found.append("sections") }
        for origin in Set(slices.keys).union(fresh.slices.keys) where slice(origin: origin) != fresh.slice(origin: origin) {
            found.append("sections of conversation \(origin)")
        }
        if needsUserCounts != fresh.needsUserCounts { found.append("needs-you counts") }
        if needsYouByMission != fresh.needsYouByMission { found.append("needs-you by mission") }
        for mission in Set(openByMission.keys).union(fresh.openByMission.keys)
        where openItems(missionID: mission) != fresh.openItems(missionID: mission) {
            found.append("open items of mission \(mission)")
        }
        if closedByMission != fresh.closedByMission { found.append("closed items by mission") }
        return found
    }

    // MARK: Sorted lists

    /// The first position whose item does not precede `item`: where `item`
    /// is, or belongs.
    private static func position(of item: TrackerItem, in list: [TrackerItem], _ order: Order) -> Int {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if order.precedes(list[mid], item) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    fileprivate static func insert(_ item: TrackerItem, into list: inout [TrackerItem], _ order: Order) {
        list.insert(item, at: position(of: item, in: list, order))
    }

    /// Removes `item`, which must be the value the list holds for it.
    fileprivate static func remove(_ item: TrackerItem, from list: inout [TrackerItem], _ order: Order) {
        let at = position(of: item, in: list, order)
        if at < list.count, list[at].id == item.id { list.remove(at: at) }
    }

    /// Removes `item` from `key`'s list, dropping the list once empty.
    private static func remove(_ item: TrackerItem, from lists: inout [String: [TrackerItem]], _ key: String,
                               _ order: Order) {
        remove(item, from: &lists[key, default: []], order)
        if lists[key]?.isEmpty == true { lists[key] = nil }
    }
}

/// The live `ItemsIndexState` for one store, fed by the change feed,
/// serving, when the store's `usesChangeFeed` flag is on:
///
/// - the items panel's sections, app-wide (the For you list) and for one
///   conversation (a chat's pane): `itemSectionsStream(scope:)`;
/// - `needsUserCountsStream()` and `needsYouItemsByMissionStream()`;
/// - a mission's open and closed items and its closed count
///   (`itemsStream(missionID:)`, `closedItemsStream`, `closedItemsCountStream`);
/// - a set of missions' needs-you and open items, which the store's
///   project item streams follow for the project's missions.
///
/// Each of those is otherwise a `ValueObservation` that re-reads the
/// `item` table on the writer after every item write, and the items panel
/// then filters and sorts what it read. Here the writer reads back only
/// the rows a commit changed (`StoreChangeFeed`), and the index moves them
/// in and out of its sorted lists on its own serial queue.
///
/// Started by the first subscriber, and then kept for the life of the
/// store. A projection is delivered only when a change touched it (an item
/// write in one conversation or mission touches no other's), and only when
/// its value differs from the last one delivered. Every delivery is made on
/// the main queue, like the value observations'.
///
/// In Debug builds the index also checks itself once a minute against a
/// full read (`checkConsistency`) and logs any difference.
final class ItemsIndex: @unchecked Sendable {
    /// A live projection subscription. Cancel from any thread.
    final class Token: @unchecked Sendable {
        private let onCancel: () -> Void
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        fileprivate init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }

        func cancel() {
            guard !cancelled.withLock({ value -> Bool in defer { value = true }; return value }) else { return }
            onCancel()
        }
    }

    private struct Subscriber<Value> {
        var deliver: (Value) -> Void
        var finish: () -> Void
    }

    private struct Channel<Value: Equatable> {
        var handlers: [UInt64: Subscriber<Value>] = [:]
        var last: Value?
    }

    /// A projection with a key (a conversation, a mission, a set of
    /// missions): one channel per key, made by its first subscriber and
    /// dropped with its last.
    private typealias Channels<Key: Hashable, Value: Equatable> = [Key: Channel<Value>]

    private struct ClosedKey: Hashable {
        var missionID: String
        var limit: Int
    }

    private static let logger = os.Logger(subsystem: "chat.matron", category: "items-index")
    private static let checkLogger = os.Logger(subsystem: "chat.matron", category: "store-observation")

    #if DEBUG
    /// How often the Debug consistency check runs.
    static let checkInterval: TimeInterval = 60
    #endif

    private weak var store: JournalStore?
    private let metrics: StoreMetrics
    private let queue = DispatchQueue(label: "chat.matron.items-index", qos: .userInitiated)

    // Queue-confined.
    private var state = ItemsIndexState()
    private var isLoaded = false
    private var subscription: StoreChangeFeed.Subscription?
    private var nextHandlerID: UInt64 = 0
    private var sections = Channel<ItemsIndexSections>()
    private var needsUserCounts = Channel<[String: Int]>()
    private var needsYouByMission = Channel<[String: [TrackerItem]]>()
    private var slices: Channels<String, ItemsIndexSections> = [:]
    private var missionOpen: Channels<String, [TrackerItem]> = [:]
    private var missionClosed: Channels<ClosedKey, [TrackerItem]> = [:]
    private var missionClosedCount: Channels<String, Int> = [:]
    private var missionsNeedsYou: Channels<Set<String>, [TrackerItem]> = [:]
    private var missionsOpen: Channels<Set<String>, [TrackerItem]> = [:]
    private var resubscribeBackoff = ResubscribeBackoff()
    private var checkTimer: DispatchSourceTimer?

    init(store: JournalStore) {
        self.store = store
        self.metrics = store.metrics
    }

    /// The index goes when its store does. Every subscriber is told, after
    /// any delivery already on its way, so a stream's `for await` ends.
    deinit {
        subscription?.cancel()
        checkTimer?.cancel()
        func finishes<K, V>(_ channels: Channels<K, V>) -> [() -> Void] {
            channels.values.flatMap { $0.handlers.values.map(\.finish) }
        }
        let all = sections.handlers.values.map(\.finish) + needsUserCounts.handlers.values.map(\.finish)
            + needsYouByMission.handlers.values.map(\.finish) + finishes(slices) + finishes(missionOpen)
            + finishes(missionClosed) + finishes(missionClosedCount) + finishes(missionsNeedsYou)
            + finishes(missionsOpen)
        guard !all.isEmpty else { return }
        DispatchQueue.main.async {
            for finish in all { finish() }
        }
    }

    // MARK: Subscribing

    /// `handler` gets the app-wide sections now (once the index has loaded)
    /// and again on the main queue each time they change.
    func observeSections(onFinish: @escaping () -> Void = {},
                         _ handler: @escaping (ItemsIndexSections) -> Void) -> Token {
        observe(\.sections, value: { $0.sections }, Subscriber(deliver: handler, finish: onFinish))
    }

    /// One origin conversation's sections, likewise.
    func observeSections(origin convoID: String, onFinish: @escaping () -> Void = {},
                         _ handler: @escaping (ItemsIndexSections) -> Void) -> Token {
        observe(\.slices, key: convoID, value: { $0.slice(origin: $1) }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeNeedsUserCounts(onFinish: @escaping () -> Void = {},
                                _ handler: @escaping ([String: Int]) -> Void) -> Token {
        observe(\.needsUserCounts, value: { $0.needsUserCounts }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeNeedsYouByMission(onFinish: @escaping () -> Void = {},
                                  _ handler: @escaping ([String: [TrackerItem]]) -> Void) -> Token {
        observe(\.needsYouByMission, value: { $0.needsYouByMission }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeOpenItems(missionID: String, onFinish: @escaping () -> Void = {},
                          _ handler: @escaping ([TrackerItem]) -> Void) -> Token {
        observe(\.missionOpen, key: missionID, value: { $0.openItems(missionID: $1) },
                Subscriber(deliver: handler, finish: onFinish))
    }

    func observeClosedItems(missionID: String, limit: Int, onFinish: @escaping () -> Void = {},
                            _ handler: @escaping ([TrackerItem]) -> Void) -> Token {
        observe(\.missionClosed, key: ClosedKey(missionID: missionID, limit: limit),
                value: { $0.closedItems(missionID: $1.missionID, limit: $1.limit) },
                Subscriber(deliver: handler, finish: onFinish))
    }

    func observeClosedItemsCount(missionID: String, onFinish: @escaping () -> Void = {},
                                 _ handler: @escaping (Int) -> Void) -> Token {
        observe(\.missionClosedCount, key: missionID, value: { $0.closedItemsCount(missionID: $1) },
                Subscriber(deliver: handler, finish: onFinish))
    }

    func observeNeedsYouItems(missionIDs: Set<String>, onFinish: @escaping () -> Void = {},
                              _ handler: @escaping ([TrackerItem]) -> Void) -> Token {
        observe(\.missionsNeedsYou, key: missionIDs, value: { $0.needsYouItems(missionIDs: $1) },
                Subscriber(deliver: handler, finish: onFinish))
    }

    func observeOpenItems(missionIDs: Set<String>, onFinish: @escaping () -> Void = {},
                          _ handler: @escaping ([TrackerItem]) -> Void) -> Token {
        observe(\.missionsOpen, key: missionIDs, value: { $0.openItems(missionIDs: $1) },
                Subscriber(deliver: handler, finish: onFinish))
    }

    /// Returns once everything already queued on the index has been
    /// applied and its deliveries handed to the main queue. For tests.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// The state as the index holds it now. For tests.
    var currentState: ItemsIndexState { queue.sync { state } }

    func sectionsStream() -> AsyncStream<ItemsIndexSections> {
        stream { self.observeSections(onFinish: $0, $1) }
    }

    func sectionsStream(origin convoID: String) -> AsyncStream<ItemsIndexSections> {
        stream { self.observeSections(origin: convoID, onFinish: $0, $1) }
    }

    func needsUserCountsStream() -> AsyncStream<[String: Int]> {
        stream { self.observeNeedsUserCounts(onFinish: $0, $1) }
    }

    func needsYouByMissionStream() -> AsyncStream<[String: [TrackerItem]]> {
        stream { self.observeNeedsYouByMission(onFinish: $0, $1) }
    }

    func openItemsStream(missionID: String) -> AsyncStream<[TrackerItem]> {
        stream { self.observeOpenItems(missionID: missionID, onFinish: $0, $1) }
    }

    func closedItemsStream(missionID: String, limit: Int) -> AsyncStream<[TrackerItem]> {
        stream { self.observeClosedItems(missionID: missionID, limit: limit, onFinish: $0, $1) }
    }

    func closedItemsCountStream(missionID: String) -> AsyncStream<Int> {
        stream { self.observeClosedItemsCount(missionID: missionID, onFinish: $0, $1) }
    }

    func needsYouItemsStream(missionIDs: Set<String>) -> AsyncStream<[TrackerItem]> {
        stream { self.observeNeedsYouItems(missionIDs: missionIDs, onFinish: $0, $1) }
    }

    func openItemsStream(missionIDs: Set<String>) -> AsyncStream<[TrackerItem]> {
        stream { self.observeOpenItems(missionIDs: missionIDs, onFinish: $0, $1) }
    }

    private func stream<Value>(
        _ observe: (_ onFinish: @escaping () -> Void, _ handler: @escaping (Value) -> Void) -> Token
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let token = observe({ continuation.finish() }, { continuation.yield($0) })
            continuation.onTermination = { _ in token.cancel() }
        }
    }

    /// Boxes the handler id so a token can read the id assigned on the queue.
    private final class HandlerID: @unchecked Sendable { var value: UInt64 = 0 }

    private func register(_ body: @escaping (ItemsIndex, UInt64) -> Void) -> HandlerID {
        let id = HandlerID()
        queue.async { [self] in
            nextHandlerID += 1
            id.value = nextHandlerID
            startIfNeeded()
            body(self, id.value)
        }
        return id
    }

    private func observe<Value: Equatable>(_ channel: ReferenceWritableKeyPath<ItemsIndex, Channel<Value>>,
                                           value: @escaping (ItemsIndexState) -> Value,
                                           _ subscriber: Subscriber<Value>) -> Token {
        let id = register { index, id in
            index[keyPath: channel].handlers[id] = subscriber
            index.publish(channel, value: value, newHandler: id)
        }
        return Token { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self[keyPath: channel].handlers[id.value] = nil
                // Nobody holds the last value any more.
                if self[keyPath: channel].handlers.isEmpty { self[keyPath: channel].last = nil }
            }
        }
    }

    private func observe<Key: Hashable, Value: Equatable>(
        _ channels: ReferenceWritableKeyPath<ItemsIndex, Channels<Key, Value>>, key: Key,
        value: @escaping (ItemsIndexState, Key) -> Value, _ subscriber: Subscriber<Value>
    ) -> Token {
        let id = register { index, id in
            index[keyPath: channels][key, default: Channel()].handlers[id] = subscriber
            index.publish(channels, key: key, value: value, newHandler: id)
        }
        return Token { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self[keyPath: channels][key]?.handlers[id.value] = nil
                if self[keyPath: channels][key]?.handlers.isEmpty == true { self[keyPath: channels][key] = nil }
            }
        }
    }

    // MARK: The feed

    private func startIfNeeded() {
        guard subscription == nil, let store else { return }
        subscription = store.observeChanges(
            tables: .item,
            snapshot: { db in try StoreChangeFeed.itemRows(db) },
            onEvent: { [weak self] event in
                self?.queue.async { self?.handle(event) }
            },
            onError: { [weak self] error in
                // On the writer: hop to the index queue before touching state.
                let message = error.localizedDescription
                self?.queue.async { self?.feedFailed(message) }
            })
        #if DEBUG
        startConsistencyCheck()
        #endif
    }

    /// The subscription ended on a failed snapshot read: resubscribe after
    /// `ResubscribeBackoff`'s delay, serving what the index last had until
    /// then.
    private func feedFailed(_ message: String) {
        let delay = resubscribeBackoff.recordFailure()
        let failures = resubscribeBackoff.consecutiveFailures
        Self.logger.error("items index lost the change feed (\(failures) in a row) — resubscribing in \(delay, format: .fixed(precision: 0))s: \(message, privacy: .public)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.subscription = nil
            self.startIfNeeded()
        }
    }

    private func handle(_ event: StoreFeedEvent<[(Int64, ItemRecord)]>) {
        metrics.measureFetch("itemsIndex") {
            guard let touched = state.apply(event) else {
                isLoaded = true
                resubscribeBackoff.recordSuccess()
                publishAll()
                return
            }
            publish(touched)
        }
    }

    // MARK: Publishing

    private func publishAll() {
        publish(\.sections, value: { $0.sections })
        publish(\.needsUserCounts, value: { $0.needsUserCounts })
        publish(\.needsYouByMission, value: { $0.needsYouByMission })
        for key in Array(slices.keys) { publish(\.slices, key: key, value: { $0.slice(origin: $1) }) }
        for key in Array(missionOpen.keys) { publish(\.missionOpen, key: key, value: { $0.openItems(missionID: $1) }) }
        for key in Array(missionClosed.keys) {
            publish(\.missionClosed, key: key, value: { $0.closedItems(missionID: $1.missionID, limit: $1.limit) })
        }
        for key in Array(missionClosedCount.keys) {
            publish(\.missionClosedCount, key: key, value: { $0.closedItemsCount(missionID: $1) })
        }
        for key in Array(missionsNeedsYou.keys) {
            publish(\.missionsNeedsYou, key: key, value: { $0.needsYouItems(missionIDs: $1) })
        }
        for key in Array(missionsOpen.keys) { publish(\.missionsOpen, key: key, value: { $0.openItems(missionIDs: $1) }) }
    }

    /// Publishes only what `touched` names: an item write in one
    /// conversation or mission computes nothing for any other.
    private func publish(_ touched: ItemsIndexState.Touched) {
        if !touched.lists.isEmpty { publish(\.sections, value: { $0.sections }) }
        if touched.needsUserCounts { publish(\.needsUserCounts, value: { $0.needsUserCounts }) }
        if !touched.missions.isEmpty { publish(\.needsYouByMission, value: { $0.needsYouByMission }) }
        for origin in touched.origins.keys where slices[origin] != nil {
            publish(\.slices, key: origin, value: { $0.slice(origin: $1) })
        }
        for mission in touched.missionItems {
            if missionOpen[mission] != nil {
                publish(\.missionOpen, key: mission, value: { $0.openItems(missionID: $1) })
            }
            if missionClosedCount[mission] != nil {
                publish(\.missionClosedCount, key: mission, value: { $0.closedItemsCount(missionID: $1) })
            }
        }
        for key in Array(missionClosed.keys) where touched.missionItems.contains(key.missionID) {
            publish(\.missionClosed, key: key, value: { $0.closedItems(missionID: $1.missionID, limit: $1.limit) })
        }
        for key in Array(missionsNeedsYou.keys) where !key.isDisjoint(with: touched.missions) {
            publish(\.missionsNeedsYou, key: key, value: { $0.needsYouItems(missionIDs: $1) })
        }
        for key in Array(missionsOpen.keys) where !key.isDisjoint(with: touched.missionItems) {
            publish(\.missionsOpen, key: key, value: { $0.openItems(missionIDs: $1) })
        }
    }

    /// Delivers the projection to whoever has not seen this value:
    /// everyone when it changed, else only the new subscriber.
    private func publish<Value: Equatable>(_ channel: ReferenceWritableKeyPath<ItemsIndex, Channel<Value>>,
                                           value: (ItemsIndexState) -> Value,
                                           newHandler: UInt64? = nil) {
        guard isLoaded, !self[keyPath: channel].handlers.isEmpty else { return }
        let current = value(state)
        if current != self[keyPath: channel].last {
            self[keyPath: channel].last = current
            deliver(current, to: self[keyPath: channel].handlers.values.map(\.deliver))
        } else if let newHandler, let subscriber = self[keyPath: channel].handlers[newHandler] {
            deliver(current, to: [subscriber.deliver])
        }
    }

    private func publish<Key: Hashable, Value: Equatable>(
        _ channels: ReferenceWritableKeyPath<ItemsIndex, Channels<Key, Value>>, key: Key,
        value: (ItemsIndexState, Key) -> Value, newHandler: UInt64? = nil
    ) {
        guard isLoaded, let channel = self[keyPath: channels][key], !channel.handlers.isEmpty else { return }
        let current = value(state, key)
        if current != channel.last {
            self[keyPath: channels][key]?.last = current
            deliver(current, to: channel.handlers.values.map(\.deliver))
        } else if let newHandler, let subscriber = channel.handlers[newHandler] {
            deliver(current, to: [subscriber.deliver])
        }
    }

    private func deliver<Value>(_ value: Value, to handlers: [(Value) -> Void]) {
        DispatchQueue.main.async {
            for handler in handlers { handler(value) }
        }
    }

    // MARK: Consistency check

    /// Compares the index with a full read of the `item` table and hands
    /// the differences (empty when there are none) to `completion`, on the
    /// index queue.
    ///
    /// The read runs in a writer turn, and the comparison on the index
    /// queue after it: every commit before that turn has already queued its
    /// change set on the index queue (the feed queues them inside each
    /// commit, in order), and no later one has, so the two sides describe
    /// the same database. A failed read reports nothing.
    func checkConsistency(_ completion: @escaping ([String]) -> Void) {
        guard let store else { return }
        store.db.asyncWriteWithoutTransaction { [weak self] db in
            guard let rows = try? StoreChangeFeed.itemRows(db) else { return }
            self?.queue.async {
                guard let self, self.isLoaded else { return }
                var fresh = ItemsIndexState()
                fresh.load(rows)
                completion(self.state.mismatches(against: fresh))
            }
        }
    }

    #if DEBUG
    /// While the change feed's indexes are still behind a flag, a Debug
    /// build checks this one against a full read every `checkInterval` and
    /// logs any difference under `store-observation`, so a change the feed
    /// missed shows up in the log rather than as a quietly stale list.
    private func startConsistencyCheck() {
        guard checkTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.checkConsistency { mismatches in
                guard !mismatches.isEmpty else { return }
                Self.checkLogger.fault("items index differs from a full read: \(mismatches.joined(separator: ", "), privacy: .public)")
            }
        }
        timer.resume()
        checkTimer = timer
    }
    #endif
}
