import Foundation
import GRDB
import MatronModels
import os

/// The app-wide tracker sections the For you list (the Decisions view
/// model) reads, as one value: the items panel's `Sections` rule applied
/// to every item in the store.
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
/// the app-wide sections (`ItemsIndexSections`), the open tasks and
/// decisions of each origin conversation, the needs-you count per
/// conversation (`JournalStore.needsUserCounts()`) and the needs-you items
/// per mission (`JournalStore.needsYouItemsByMission()`).
///
/// Each list is a sorted array. A changed item leaves the lists its old
/// value was in and joins the ones its new value belongs to, by binary
/// search, so one item write touches only those lists and every other
/// array keeps its storage: `apply` says which were touched, and the
/// published `sections` value replaces only those. A commit that changes
/// more than an eighth of the items (a first sync, a catch-up page) sorts
/// every list once instead.
///
/// A value type with no clock and no queue, so the equivalence tests can
/// drive it synchronously; `ItemsIndex` is the live host.
struct ItemsIndexState {
    /// The app-wide lists, one per section (`closed` backs `done`).
    struct Lists: OptionSet, Hashable {
        let rawValue: Int
        static let needsYou = Lists(rawValue: 1 << 0)
        static let tasks = Lists(rawValue: 1 << 1)
        static let decisions = Lists(rawValue: 1 << 2)
        static let closed = Lists(rawValue: 1 << 3)
        static let decided = Lists(rawValue: 1 << 4)
        static let all: Lists = [.needsYou, .tasks, .decisions, .closed, .decided]
    }

    /// What one change set changed: the app-wide lists, the origin
    /// conversations whose open tasks or decisions changed, whether the
    /// needs-you counts changed, and the missions whose needs-you items
    /// changed.
    struct Touched: Equatable {
        var lists: Lists = []
        var origins: Set<String> = []
        var needsUserCounts = false
        var missions: Set<String> = []

        var isEmpty: Bool { lists.isEmpty && origins.isEmpty && !needsUserCounts && missions.isEmpty }
    }

    /// The `done` section's cap, as `ItemsPanelViewModel.sections(from:)`
    /// has it.
    static let doneLimit = 200

    /// One list's order. Every order ends on the item id, so it is total
    /// and an item's place in a list is found by binary search.
    enum Order {
        case needsYou, tasks, decisions, closed, decided
        /// `ORDER BY updated_at DESC, num DESC`: the mission query's.
        case missionNeedsYou

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
            case .missionNeedsYou:
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                if a.num != b.num { return a.num > b.num }
                return a.id < b.id
            }
            // The store's read order: `ORDER BY rank, num`.
            if a.rank != b.rank { return a.rank < b.rank }
            if a.num != b.num { return a.num < b.num }
            return a.id < b.id
        }
    }

    private struct Entry: Equatable {
        var rowid: Int64
        var item: TrackerItem
        /// `state = 'open' AND awaiting = 'user'` on the stored row: the
        /// count and mission queries' filter, which reads the columns
        /// rather than the decoded item.
        var awaitsUser: Bool

        init(rowid: Int64, record: ItemRecord) {
            self.rowid = rowid
            item = record.item
            awaitsUser = record.state == "open" && record.awaiting == "user"
        }

        var missionAwaitingUser: String? { awaitsUser ? item.missionID : nil }
    }

    private var entries: [String: Entry] = [:]
    private var idByRowid: [Int64: String] = [:]
    private var needsYou: [TrackerItem] = []
    private var tasks: [TrackerItem] = []
    private var decisions: [TrackerItem] = []
    private var closed: [TrackerItem] = []
    private var decided: [TrackerItem] = []
    /// Open tasks per origin conversation, in `tasks` order.
    private(set) var tasksByOrigin: [String: [TrackerItem]] = [:]
    /// Open decisions per origin conversation, in `decisions` order.
    private(set) var decisionsByOrigin: [String: [TrackerItem]] = [:]
    /// `JournalStore.needsUserCounts()`.
    private(set) var needsUserCounts: [String: Int] = [:]
    /// `JournalStore.needsYouItemsByMission()`.
    private(set) var needsYouByMission: [String: [TrackerItem]] = [:]
    /// The app-wide sections. Only the touched lists are replaced by a
    /// change, so an untouched section keeps the storage it had, and a
    /// consumer comparing it with the one it holds pays nothing for it.
    private(set) var sections = ItemsIndexSections()
    /// How many times the lists have been sorted from scratch since the
    /// last load (the load included). How the tests tell the two paths
    /// apart.
    private(set) var rebuilds = 0

    var count: Int { entries.count }

    func tasks(origin convoID: String) -> [TrackerItem] { tasksByOrigin[convoID] ?? [] }
    func decisions(origin convoID: String) -> [TrackerItem] { decisionsByOrigin[convoID] ?? [] }

    /// The lists an item belongs to.
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
        publish(.all)
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
            guard old?.item != new?.item || old?.awaitsUser != new?.awaitsUser else { continue }
            for entry in [old, new].compactMap({ $0 }) {
                let lists = Self.lists(of: entry.item)
                touched.lists.formUnion(lists)
                if !lists.isDisjoint(with: [.tasks, .decisions]) { touched.origins.insert(entry.item.originConvoID) }
                if entry.awaitsUser { touched.needsUserCounts = true }
                if let mission = entry.missionAwaitingUser { touched.missions.insert(mission) }
            }
        }
        publish(touched.lists)
        return touched
    }

    private mutating func insert(_ entry: Entry, placing: Bool) {
        let item = entry.item
        entries[item.id] = entry
        idByRowid[entry.rowid] = item.id
        guard placing else { return }
        let lists = Self.lists(of: item)
        if lists.contains(.needsYou) { Self.insert(item, into: &needsYou, .needsYou) }
        if lists.contains(.tasks) {
            Self.insert(item, into: &tasks, .tasks)
            Self.insert(item, into: &tasksByOrigin[item.originConvoID, default: []], .tasks)
        }
        if lists.contains(.decisions) {
            Self.insert(item, into: &decisions, .decisions)
            Self.insert(item, into: &decisionsByOrigin[item.originConvoID, default: []], .decisions)
        }
        if lists.contains(.closed) { Self.insert(item, into: &closed, .closed) }
        if lists.contains(.decided) { Self.insert(item, into: &decided, .decided) }
        if entry.awaitsUser { needsUserCounts[item.originConvoID, default: 0] += 1 }
        if let mission = entry.missionAwaitingUser {
            Self.insert(item, into: &needsYouByMission[mission, default: []], .missionNeedsYou)
        }
    }

    private mutating func remove(_ id: String, placing: Bool) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if idByRowid[entry.rowid] == id { idByRowid[entry.rowid] = nil }
        guard placing else { return }
        let item = entry.item
        let origin = item.originConvoID
        let lists = Self.lists(of: item)
        if lists.contains(.needsYou) { Self.remove(item, from: &needsYou, .needsYou) }
        if lists.contains(.tasks) {
            Self.remove(item, from: &tasks, .tasks)
            Self.remove(item, from: &tasksByOrigin[origin, default: []], .tasks)
            if tasksByOrigin[origin]?.isEmpty == true { tasksByOrigin[origin] = nil }
        }
        if lists.contains(.decisions) {
            Self.remove(item, from: &decisions, .decisions)
            Self.remove(item, from: &decisionsByOrigin[origin, default: []], .decisions)
            if decisionsByOrigin[origin]?.isEmpty == true { decisionsByOrigin[origin] = nil }
        }
        if lists.contains(.closed) { Self.remove(item, from: &closed, .closed) }
        if lists.contains(.decided) { Self.remove(item, from: &decided, .decided) }
        if entry.awaitsUser {
            let left = (needsUserCounts[origin] ?? 0) - 1
            needsUserCounts[origin] = left > 0 ? left : nil
        }
        if let mission = entry.missionAwaitingUser {
            Self.remove(item, from: &needsYouByMission[mission, default: []], .missionNeedsYou)
            if needsYouByMission[mission]?.isEmpty == true { needsYouByMission[mission] = nil }
        }
    }

    /// Sorts every list from scratch: O(n log n), against the O(n) one
    /// sorted insert or removal costs in array moves.
    private mutating func rebuildLists() {
        let items = entries.values.map(\.item)
        func sorted(_ order: Order, _ isIn: (TrackerItem) -> Bool) -> [TrackerItem] {
            items.filter(isIn).sorted(by: order.precedes)
        }
        needsYou = sorted(.needsYou) { Self.lists(of: $0).contains(.needsYou) }
        tasks = sorted(.tasks) { Self.lists(of: $0).contains(.tasks) }
        decisions = sorted(.decisions) { Self.lists(of: $0).contains(.decisions) }
        closed = sorted(.closed) { Self.lists(of: $0).contains(.closed) }
        decided = sorted(.decided) { Self.lists(of: $0).contains(.decided) }
        // Already in order, so grouping keeps it.
        tasksByOrigin = Dictionary(grouping: tasks, by: \.originConvoID)
        decisionsByOrigin = Dictionary(grouping: decisions, by: \.originConvoID)
        needsUserCounts = [:]
        var byMission: [String: [TrackerItem]] = [:]
        for entry in entries.values where entry.awaitsUser {
            needsUserCounts[entry.item.originConvoID, default: 0] += 1
            if let mission = entry.missionAwaitingUser { byMission[mission, default: []].append(entry.item) }
        }
        needsYouByMission = byMission.mapValues { $0.sorted(by: Order.missionNeedsYou.precedes) }
        rebuilds += 1
    }

    /// Copies the touched lists into `sections`, leaving the rest alone.
    private mutating func publish(_ lists: Lists) {
        if lists.contains(.needsYou) { sections.needsYou = needsYou }
        if lists.contains(.tasks) { sections.tasks = tasks }
        if lists.contains(.decisions) { sections.decisions = decisions }
        if lists.contains(.closed) { sections.done = Array(closed.prefix(Self.doneLimit)) }
        if lists.contains(.decided) { sections.decided = decided }
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

    private static func insert(_ item: TrackerItem, into list: inout [TrackerItem], _ order: Order) {
        list.insert(item, at: position(of: item, in: list, order))
    }

    /// Removes `item`, which must be the value the list holds for it.
    private static func remove(_ item: TrackerItem, from list: inout [TrackerItem], _ order: Order) {
        let at = position(of: item, in: list, order)
        if at < list.count, list[at].id == item.id { list.remove(at: at) }
    }
}

/// The live `ItemsIndexState` for one store, fed by the change feed,
/// serving the For you list's sections (`itemSectionsStream()`),
/// `needsUserCountsStream()` and `needsYouItemsByMissionStream()` when the
/// store's `usesChangeFeed` flag is on.
///
/// Today each of those is a `ValueObservation` that re-reads the `item`
/// table on the writer after every item write, and the For you list then
/// filters and sorts every item ever synced (thousands, most of them
/// closed) to find the few that changed. Here the writer reads back only
/// the rows a commit changed (`StoreChangeFeed`), and the index moves
/// them in and out of its sorted lists on its own serial queue.
///
/// Started by the first subscriber, and then kept for the life of the
/// store. A projection is delivered only when a change touched it, and
/// only when its value differs from the last one delivered. Every delivery
/// is made on the main queue, like the value observations'.
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

    private static let logger = os.Logger(subsystem: "chat.matron", category: "items-index")

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
    private var resubscribeBackoff = ResubscribeBackoff()

    init(store: JournalStore) {
        self.store = store
        self.metrics = store.metrics
    }

    /// The index goes when its store does. Every subscriber is told, after
    /// any delivery already on its way, so a stream's `for await` ends.
    deinit {
        subscription?.cancel()
        let finishes = sections.handlers.values.map(\.finish) + needsUserCounts.handlers.values.map(\.finish)
            + needsYouByMission.handlers.values.map(\.finish)
        guard !finishes.isEmpty else { return }
        DispatchQueue.main.async {
            for finish in finishes { finish() }
        }
    }

    // MARK: Subscribing

    /// `handler` gets the sections now (once the index has loaded) and
    /// again on the main queue each time they change.
    func observeSections(onFinish: @escaping () -> Void = {},
                         _ handler: @escaping (ItemsIndexSections) -> Void) -> Token {
        observe(\.sections, value: { $0.sections }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeNeedsUserCounts(onFinish: @escaping () -> Void = {},
                                _ handler: @escaping ([String: Int]) -> Void) -> Token {
        observe(\.needsUserCounts, value: { $0.needsUserCounts }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeNeedsYouByMission(onFinish: @escaping () -> Void = {},
                                  _ handler: @escaping ([String: [TrackerItem]]) -> Void) -> Token {
        observe(\.needsYouByMission, value: { $0.needsYouByMission }, Subscriber(deliver: handler, finish: onFinish))
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

    func needsUserCountsStream() -> AsyncStream<[String: Int]> {
        stream { self.observeNeedsUserCounts(onFinish: $0, $1) }
    }

    func needsYouByMissionStream() -> AsyncStream<[String: [TrackerItem]]> {
        stream { self.observeNeedsYouByMission(onFinish: $0, $1) }
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

    private func observe<Value: Equatable>(_ channel: ReferenceWritableKeyPath<ItemsIndex, Channel<Value>>,
                                           value: @escaping (ItemsIndexState) -> Value,
                                           _ subscriber: Subscriber<Value>) -> Token {
        let id = HandlerID()
        queue.async { [self] in
            nextHandlerID += 1
            id.value = nextHandlerID
            startIfNeeded()
            self[keyPath: channel].handlers[id.value] = subscriber
            publish(channel, value: value, newHandler: id.value)
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
            if !touched.lists.isEmpty { publish(\.sections, value: { $0.sections }) }
            if touched.needsUserCounts { publish(\.needsUserCounts, value: { $0.needsUserCounts }) }
            if !touched.missions.isEmpty { publish(\.needsYouByMission, value: { $0.needsYouByMission }) }
        }
    }

    // MARK: Publishing

    private func publishAll() {
        publish(\.sections, value: { $0.sections })
        publish(\.needsUserCounts, value: { $0.needsUserCounts })
        publish(\.needsYouByMission, value: { $0.needsYouByMission })
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

    private func deliver<Value>(_ value: Value, to handlers: [(Value) -> Void]) {
        DispatchQueue.main.async {
            for handler in handlers { handler(value) }
        }
    }
}
