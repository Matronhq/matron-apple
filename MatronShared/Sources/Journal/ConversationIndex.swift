import Foundation
import GRDB
import os

/// Every conversation row by id, kept current from `StoreChangeFeed`
/// change sets, and the four projections the store's conversation streams
/// serve: the chat list, the session-state map, the rooms, and a parent's
/// children.
///
/// Each projection is the value today's fetch for it returns
/// (`JournalStore.chatList`, `sessionStateMap`, `missionRoomRows`,
/// `childRecords`), byte for byte, which `ConversationIndexTests` holds it
/// to after every commit of a random write sequence. That includes the
/// parts SQLite decides without being asked: NULL activity times sort
/// last under `DESC`, rows equal on both sort keys come out in rowid
/// order, and the rooms query has no `ORDER BY` and returns rowid order.
///
/// A value type with no clock and no queue, so the equivalence test can
/// drive it synchronously; `ConversationIndex` is the live host.
struct ConversationIndexState {
    private struct Entry {
        var rowid: Int64
        var record: ConversationRecord
    }

    /// A chat-list row's place: `last_activity_ts DESC` (NULL last),
    /// `last_seq DESC`, then rowid. Unique, because rowids are.
    private struct ChatKey {
        var activity: Int64?
        var lastSeq: Int64
        var rowid: Int64
        var id: String

        init(_ entry: Entry) {
            activity = entry.record.lastActivityTS
            lastSeq = entry.record.lastSeq
            rowid = entry.rowid
            id = entry.record.id
        }

        func precedes(_ other: ChatKey) -> Bool {
            switch (activity, other.activity) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if lastSeq != other.lastSeq { return lastSeq > other.lastSeq }
            return rowid < other.rowid
        }
    }

    /// One conversation a change set actually changed: its value before
    /// the set and after it (`nil` when absent).
    struct Change {
        var old: ConversationRecord?
        var new: ConversationRecord?
    }

    private var entries: [String: Entry] = [:]
    private var idByRowid: [Int64: String] = [:]
    /// Chat-list rows, in chat-list order.
    private var chatOrder: [ChatKey] = []
    private var roomIDs: Set<String> = []
    private var childIDsByParent: [String: Set<String>] = [:]
    /// id → `session_state` for every conversation.
    private(set) var sessionStates: [String: String] = [:]
    /// How many times `chatOrder` has been sorted from scratch since the
    /// last load (the load included), rather than kept in order row by
    /// row. Cheap to keep, and how the tests tell the two paths apart.
    private(set) var chatOrderRebuilds = 0

    var count: Int { entries.count }

    // MARK: Membership

    /// `archived_at IS NULL AND parent_convo_id IS NULL`.
    static func isInChatList(_ record: ConversationRecord?) -> Bool {
        guard let record else { return false }
        return !record.isArchived && record.parentConvoID == nil
    }

    /// `archived_at IS NOT NULL AND parent_convo_id IS NULL`: the Archived
    /// list's filter.
    static func isInArchivedList(_ record: ConversationRecord?) -> Bool {
        guard let record else { return false }
        return record.isArchived && record.parentConvoID == nil
    }

    /// The rooms query's filter.
    static func isRoom(_ record: ConversationRecord?) -> Bool {
        guard let record, isInChatList(record), let convos = record.participantConvos else { return false }
        return convos != "[]"
    }

    // MARK: Applying the feed

    /// Applies one feed event and returns the conversations it changed,
    /// or `nil` for a snapshot, which replaces everything.
    @discardableResult
    mutating func apply(_ event: StoreFeedEvent<[(Int64, ConversationRecord)]>) -> [Change]? {
        switch event {
        case .snapshot(let rows):
            load(rows)
            return nil
        case .changes(let set):
            // `observeChanges` turns a reset into a new snapshot, so a
            // change set here is never one.
            return apply(set.conversations)
        }
    }

    /// Replaces everything with `rows`. The chat order is sorted once at
    /// the end rather than kept sorted row by row.
    mutating func load(_ rows: [(Int64, ConversationRecord)]) {
        self = ConversationIndexState()
        for (rowid, record) in rows { insert(Entry(rowid: rowid, record: record), placingInChatOrder: false) }
        rebuildChatOrder()
    }

    /// Sorts the chat order from scratch: O(n log n), against the O(n) a
    /// single sorted insert or removal costs in array moves. Worth it once
    /// a commit changes more than about an eighth of the list.
    private mutating func rebuildChatOrder() {
        chatOrder = entries.values.filter { Self.isInChatList($0.record) }.map(ChatKey.init).sorted { $0.precedes($1) }
        chatOrderRebuilds += 1
    }

    /// Whether a commit changing `rows` rows re-sorts the chat order
    /// instead of moving each row's key: past an eighth of the list. No
    /// floor: on a short list either way is trivial, and without one the
    /// random equivalence tests, whose lists are short, exercise both.
    private func rebuildsChatOrder(forChanging rows: Int) -> Bool {
        rows > chatOrder.count / 8
    }

    /// Deletions first, then upserts: a rowid that was deleted and handed
    /// to a new row in the same commit drops the key it held, and a key
    /// that moved to a new rowid drops its old one.
    ///
    /// A large commit (a catch-up batch, a snapshot refresh) re-sorts the
    /// chat order once at the end rather than moving each row's key.
    @discardableResult
    mutating func apply(_ changes: RowChanges<ConversationRecord>) -> [Change] {
        let rebuild = rebuildsChatOrder(forChanging: changes.upserted.count + changes.deleted.count)
        var originals: [String: ConversationRecord?] = [:]
        func remember(_ id: String) {
            if originals[id] == nil { originals[id] = .some(entries[id]?.record) }
        }
        for rowid in changes.deleted.sorted() {
            guard let id = idByRowid[rowid] else { continue }
            remember(id)
            remove(id, placingInChatOrder: !rebuild)
        }
        for (rowid, record) in changes.upserted.sorted(by: { $0.key < $1.key }) {
            if let held = idByRowid[rowid], held != record.id {
                remember(held)
                remove(held, placingInChatOrder: !rebuild)
            }
            remember(record.id)
            remove(record.id, placingInChatOrder: !rebuild)
            insert(Entry(rowid: rowid, record: record), placingInChatOrder: !rebuild)
        }
        if rebuild { rebuildChatOrder() }
        return originals.compactMap { id, old in
            let new = entries[id]?.record
            return old == new ? nil : Change(old: old, new: new)
        }
    }

    private mutating func insert(_ entry: Entry, placingInChatOrder: Bool = true) {
        let record = entry.record
        entries[record.id] = entry
        idByRowid[entry.rowid] = record.id
        sessionStates[record.id] = record.sessionState
        if placingInChatOrder, Self.isInChatList(record) {
            let key = ChatKey(entry)
            chatOrder.insert(key, at: chatPosition(of: key))
        }
        if Self.isRoom(record) { roomIDs.insert(record.id) }
        if let parent = record.parentConvoID { childIDsByParent[parent, default: []].insert(record.id) }
    }

    private mutating func remove(_ id: String, placingInChatOrder: Bool = true) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        let record = entry.record
        if idByRowid[entry.rowid] == id { idByRowid[entry.rowid] = nil }
        sessionStates[id] = nil
        if placingInChatOrder, Self.isInChatList(record) {
            let key = ChatKey(entry)
            let position = chatPosition(of: key)
            if position < chatOrder.count, chatOrder[position].id == id { chatOrder.remove(at: position) }
        }
        roomIDs.remove(id)
        if let parent = record.parentConvoID {
            childIDsByParent[parent]?.remove(id)
            if childIDsByParent[parent]?.isEmpty == true { childIDsByParent[parent] = nil }
        }
    }

    /// The first position whose key does not precede `key`: where `key`
    /// is, or belongs.
    private func chatPosition(of key: ChatKey) -> Int {
        var low = 0, high = chatOrder.count
        while low < high {
            let mid = (low + high) / 2
            if chatOrder[mid].precedes(key) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Projections

    /// The chat list as `JournalStore.chatList(_:now:)` returns it, and the
    /// earliest instant after `now` at which a row's tool-output snippet
    /// expires (and the list changes with no write), if any.
    func chatList(now: Date) -> (records: [ConversationRecord], nextExpiry: Date?) {
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let ttlMS = Int64(EventTombstone.toolLogTTL * 1000)
        var nextExpiryMS: Int64?
        var records: [ConversationRecord] = []
        records.reserveCapacity(chatOrder.count)
        for key in chatOrder {
            guard let record = entries[key.id]?.record else { continue }
            records.append(JournalStore.applyReadTimeSnippetTTL(record, now: now))
            // `applyReadTimeSnippetTTL`'s condition, as a time: the row
            // switches to its expired snippet once `now` reaches
            // activity + TTL.
            if record.lastMessageType == JournalEventType.toolOutput, record.expiredSnippet != nil,
               let activity = record.lastActivityTS, activity + ttlMS > nowMS {
                nextExpiryMS = min(nextExpiryMS ?? .max, activity + ttlMS)
            }
        }
        return (records, nextExpiryMS.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }

    /// The Archived list as `JournalStore.archivedList(_:now:)` returns it.
    /// Sorted when asked for rather than kept in order: only the Archived
    /// screen subscribes, and only while it is open.
    func archivedList(now: Date) -> [ConversationRecord] {
        entries.values.filter { Self.isInArchivedList($0.record) }.map { ChatKey($0) }
            .sorted { $0.precedes($1) }
            .compactMap { entries[$0.id].map { JournalStore.applyReadTimeSnippetTTL($0.record, now: now) } }
    }

    /// The rooms as `JournalStore.missionRoomRows` returns them.
    func rooms() -> [JournalStore.RoomRow] {
        roomIDs.compactMap { entries[$0] }
            .sorted { $0.rowid < $1.rowid }
            .map { entry in
                let r = entry.record
                return JournalStore.RoomRow(
                    id: r.id, title: r.title, sessionState: r.sessionState,
                    lastActivityMS: r.lastActivityTS ?? (r.createdAt > 0 ? r.createdAt : nil),
                    participantConvos: r.participantConvos ?? "")
            }
    }

    /// A parent's children as `JournalStore.childRecords` returns them:
    /// `created_at`, then id in SQLite's binary collation (UTF-8 bytes).
    func children(of parentConvoID: String) -> [ConversationRecord] {
        (childIDsByParent[parentConvoID] ?? []).compactMap { entries[$0]?.record }.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
        }
    }
}

/// The live `ConversationIndexState` for one store, fed by the change
/// feed, serving `conversationsStream()`, `sessionStatesStream()`,
/// `missionRoomsStream()` and `childrenStream(of:)` when the store's
/// `usesChangeFeed` flag is on.
///
/// Today each of those is a `ValueObservation` that re-reads the whole
/// `conversation` table on the writer after every commit that touches it,
/// which is every journal frame: on a Mac with about 2,300 conversations
/// the chat list's fetch alone took about 180 ms a time. Here the writer
/// only reads back the rows a commit changed (`StoreChangeFeed`), and the
/// index applies them on its own serial queue.
///
/// Started by the first subscriber, and then kept for the life of the
/// store. Each projection is computed only when a change could have
/// touched it and someone is subscribed, and delivered only when its
/// value differs from the last one delivered (`removeDuplicates`). Every
/// delivery is made on the main queue, like the value observations'.
///
/// The chat list applies the tool-output TTL when it is computed, with
/// the current time, and a timer recomputes it when the earliest pending
/// snippet expires, so an expired snippet disappears without a write.
final class ConversationIndex: @unchecked Sendable {
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

    /// One subscriber: what to do with each value, and what to do when
    /// the index goes away (a stream finishes).
    private struct Subscriber<Value> {
        var deliver: (Value) -> Void
        var finish: () -> Void
    }

    /// One projection's subscribers and the value they last received.
    private struct Channel<Value: Equatable> {
        var handlers: [UInt64: Subscriber<Value>] = [:]
        var last: Value?
        var isDirty = true
    }

    private static let logger = os.Logger(subsystem: "chat.matron", category: "conversation-index")

    private weak var store: JournalStore?
    private let metrics: StoreMetrics
    private let queue = DispatchQueue(label: "chat.matron.conversation-index", qos: .userInitiated)

    // Queue-confined.
    private var state = ConversationIndexState()
    private var isLoaded = false
    private var subscription: StoreChangeFeed.Subscription?
    private var nextHandlerID: UInt64 = 0
    private var chatList = Channel<[ConversationRecord]>()
    private var archivedList = Channel<[ConversationRecord]>()
    private var sessionStates = Channel<[String: String]>()
    private var rooms = Channel<[JournalStore.RoomRow]>()
    private var children: [String: Channel<[ConversationRecord]>] = [:]
    private var resubscribeBackoff = ResubscribeBackoff()
    private var expiryTimer: DispatchSourceTimer?
    private var scheduledExpiry: Date?

    init(store: JournalStore) {
        self.store = store
        self.metrics = store.metrics
    }

    /// The index goes when its store does (sign-out, an account switch).
    /// Every subscriber is told, after any delivery already on its way, so
    /// a stream's `for await` ends rather than waiting for values that can
    /// no longer come. Nothing else holds the index by now, so its
    /// queue-confined state is safe to read here.
    deinit {
        subscription?.cancel()
        expiryTimer?.cancel()
        let finishes = chatList.handlers.values.map(\.finish) + archivedList.handlers.values.map(\.finish)
            + sessionStates.handlers.values.map(\.finish)
            + rooms.handlers.values.map(\.finish) + children.values.flatMap { $0.handlers.values.map(\.finish) }
        guard !finishes.isEmpty else { return }
        DispatchQueue.main.async {
            for finish in finishes { finish() }
        }
    }

    // MARK: Subscribing

    /// `handler` gets the chat list now (once the index has loaded) and
    /// again on the main queue each time it changes. `onFinish` runs on the
    /// main queue if the index goes away while subscribed.
    func observeChatList(onFinish: @escaping () -> Void = {},
                         _ handler: @escaping ([ConversationRecord]) -> Void) -> Token {
        observe(\.chatList, compute: { $0.computeChatList() }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeArchivedList(onFinish: @escaping () -> Void = {},
                             _ handler: @escaping ([ConversationRecord]) -> Void) -> Token {
        observe(\.archivedList, compute: { $0.state.archivedList(now: Date()) },
                Subscriber(deliver: handler, finish: onFinish))
    }

    func observeSessionStates(onFinish: @escaping () -> Void = {},
                              _ handler: @escaping ([String: String]) -> Void) -> Token {
        observe(\.sessionStates, compute: { $0.state.sessionStates }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeRooms(onFinish: @escaping () -> Void = {},
                      _ handler: @escaping ([JournalStore.RoomRow]) -> Void) -> Token {
        observe(\.rooms, compute: { $0.state.rooms() }, Subscriber(deliver: handler, finish: onFinish))
    }

    func observeChildren(of parentConvoID: String, onFinish: @escaping () -> Void = {},
                         _ handler: @escaping ([ConversationRecord]) -> Void) -> Token {
        let subscriber = Subscriber(deliver: handler, finish: onFinish)
        let id = register { index, id in
            index.children[parentConvoID, default: Channel()].handlers[id] = subscriber
            index.publish(childrenOf: parentConvoID, newHandler: id)
        }
        return Token { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.children[parentConvoID]?.handlers[id.value] = nil
                if self.children[parentConvoID]?.handlers.isEmpty == true { self.children[parentConvoID] = nil }
            }
        }
    }

    /// Returns once everything already queued on the index (change sets,
    /// subscriptions) has been applied and its deliveries handed to the
    /// main queue. For tests.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// The streams hold the index only weakly (through their tokens), as
    /// the store does not want its index kept alive by a forgotten
    /// consumer; when the index goes, `deinit` finishes them.
    func chatListStream() -> AsyncStream<[ConversationRecord]> {
        stream { self.observeChatList(onFinish: $0, $1) }
    }

    func archivedListStream() -> AsyncStream<[ConversationRecord]> {
        stream { self.observeArchivedList(onFinish: $0, $1) }
    }

    func sessionStatesStream() -> AsyncStream<[String: String]> {
        stream { self.observeSessionStates(onFinish: $0, $1) }
    }

    func roomsStream() -> AsyncStream<[JournalStore.RoomRow]> {
        stream { self.observeRooms(onFinish: $0, $1) }
    }

    func childrenStream(of parentConvoID: String) -> AsyncStream<[ConversationRecord]> {
        stream { self.observeChildren(of: parentConvoID, onFinish: $0, $1) }
    }

    private func stream<Value>(
        _ observe: (_ onFinish: @escaping () -> Void, _ handler: @escaping (Value) -> Void) -> Token
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let token = observe({ continuation.finish() }, { continuation.yield($0) })
            continuation.onTermination = { _ in token.cancel() }
        }
    }

    /// Boxes the handler id so `observeChildren`'s token can read the id
    /// assigned on the queue.
    private final class HandlerID: @unchecked Sendable { var value: UInt64 = 0 }

    @discardableResult
    private func register(_ body: @escaping (ConversationIndex, UInt64) -> Void) -> HandlerID {
        let box = HandlerID()
        queue.async { [self] in
            nextHandlerID += 1
            box.value = nextHandlerID
            startIfNeeded()
            body(self, nextHandlerID)
        }
        return box
    }

    private func observe<Value: Equatable>(_ channel: ReferenceWritableKeyPath<ConversationIndex, Channel<Value>>,
                                           compute: @escaping (ConversationIndex) -> Value,
                                           _ subscriber: Subscriber<Value>) -> Token {
        let id = register { index, id in
            index[keyPath: channel].handlers[id] = subscriber
            index.publish(channel, compute: compute, newHandler: id)
        }
        return Token { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self[keyPath: channel].handlers[id.value] = nil
                if self[keyPath: channel].handlers.isEmpty {
                    // Nobody holds the last value any more; the next
                    // subscriber gets a freshly computed one.
                    self[keyPath: channel].last = nil
                    self[keyPath: channel].isDirty = true
                }
            }
        }
    }

    // MARK: The feed

    private func startIfNeeded() {
        guard subscription == nil, let store else { return }
        subscription = store.observeChanges(
            tables: .conversation,
            snapshot: { db in try StoreChangeFeed.conversationRows(db) },
            onEvent: { [weak self] event in
                self?.queue.async { self?.handle(event) }
            },
            onError: { [weak self] error in
                // On the writer: hop to the index queue before touching state.
                let message = error.localizedDescription
                self?.queue.async { self?.feedFailed(message) }
            })
    }

    /// The subscription ended on a failed snapshot read. Resubscribe, after
    /// `ResubscribeBackoff`'s delay: 1 s, doubling while the failures
    /// repeat, capped at 30 s. Until then the index keeps serving what it
    /// last had. The count is shared with nothing else and starts over at
    /// the next delivered snapshot (`handle`).
    private func feedFailed(_ message: String) {
        let delay = resubscribeBackoff.recordFailure()
        let failures = resubscribeBackoff.consecutiveFailures
        Self.logger.error("conversation index lost the change feed (\(failures) in a row) — resubscribing in \(delay, format: .fixed(precision: 0))s: \(message, privacy: .public)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.subscription = nil
            self.startIfNeeded()
        }
    }

    private func handle(_ event: StoreFeedEvent<[(Int64, ConversationRecord)]>) {
        metrics.measureFetch("conversationIndex") {
            if let changes = state.apply(event) {
                markDirty(for: changes)
            } else {
                isLoaded = true
                resubscribeBackoff.recordSuccess()
                markAllDirty()
            }
            publishDirty()
        }
    }

    private func markAllDirty() {
        chatList.isDirty = true
        archivedList.isDirty = true
        sessionStates.isDirty = true
        rooms.isDirty = true
        for parent in children.keys { children[parent]?.isDirty = true }
    }

    /// Which projections a set of row changes can have touched. Equality
    /// against the last delivered value still decides whether anything
    /// goes out; this only skips the computing.
    private func markDirty(for changes: [ConversationIndexState.Change]) {
        for change in changes {
            if ConversationIndexState.isInChatList(change.old) || ConversationIndexState.isInChatList(change.new) {
                chatList.isDirty = true
            }
            if ConversationIndexState.isInArchivedList(change.old) || ConversationIndexState.isInArchivedList(change.new) {
                archivedList.isDirty = true
            }
            if change.old?.sessionState != change.new?.sessionState { sessionStates.isDirty = true }
            if ConversationIndexState.isRoom(change.old) || ConversationIndexState.isRoom(change.new) {
                rooms.isDirty = true
            }
            for parent in Set([change.old?.parentConvoID, change.new?.parentConvoID].compactMap { $0 }) {
                children[parent]?.isDirty = true
            }
        }
    }

    // MARK: Publishing

    private func publishDirty() {
        publish(\.chatList, compute: { $0.computeChatList() })
        publish(\.archivedList, compute: { $0.state.archivedList(now: Date()) })
        publish(\.sessionStates, compute: { $0.state.sessionStates })
        publish(\.rooms, compute: { $0.state.rooms() })
        for parent in Array(children.keys) { publish(childrenOf: parent) }
    }

    /// The chat list at the current time, re-aiming the expiry timer at
    /// the next snippet it will hide.
    private func computeChatList() -> [ConversationRecord] {
        let list = state.chatList(now: Date())
        scheduleExpiry(list.nextExpiry)
        return list.records
    }

    /// Computes the projection if it may have changed (or a subscriber is
    /// new) and delivers it to whoever has not seen this value: everyone
    /// when it changed, else only the new subscriber.
    private func publish<Value: Equatable>(_ channel: ReferenceWritableKeyPath<ConversationIndex, Channel<Value>>,
                                           compute: (ConversationIndex) -> Value,
                                           newHandler: UInt64? = nil) {
        guard isLoaded, !self[keyPath: channel].handlers.isEmpty,
              self[keyPath: channel].isDirty || newHandler != nil else { return }
        let value = compute(self)
        self[keyPath: channel].isDirty = false
        if value != self[keyPath: channel].last {
            self[keyPath: channel].last = value
            deliver(value, to: self[keyPath: channel].handlers.values.map(\.deliver))
        } else if let newHandler, let subscriber = self[keyPath: channel].handlers[newHandler] {
            deliver(value, to: [subscriber.deliver])
        }
    }

    private func publish(childrenOf parent: String, newHandler: UInt64? = nil) {
        guard isLoaded, let channel = children[parent], !channel.handlers.isEmpty,
              channel.isDirty || newHandler != nil else { return }
        let value = state.children(of: parent)
        children[parent]?.isDirty = false
        if value != channel.last {
            children[parent]?.last = value
            deliver(value, to: channel.handlers.values.map(\.deliver))
        } else if let newHandler, let subscriber = channel.handlers[newHandler] {
            deliver(value, to: [subscriber.deliver])
        }
    }

    private func deliver<Value>(_ value: Value, to handlers: [(Value) -> Void]) {
        DispatchQueue.main.async {
            for handler in handlers { handler(value) }
        }
    }

    // MARK: Snippet expiry

    /// Points the one timer at the earliest pending tool-output expiry, or
    /// parks it. Wall-clock, because the TTL is: a sleep or a clock change
    /// still fires it at the right moment.
    private func scheduleExpiry(_ expiry: Date?) {
        guard expiry != scheduledExpiry else { return }
        scheduledExpiry = expiry
        let timer: DispatchSourceTimer
        if let existing = expiryTimer {
            timer = existing
        } else {
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.expiryTimerFired() }
            timer.schedule(wallDeadline: .distantFuture)
            timer.resume()
            expiryTimer = timer
        }
        guard let expiry else {
            timer.schedule(wallDeadline: .distantFuture)
            return
        }
        // A millisecond past the expiry, so the TTL check, which works in
        // whole milliseconds, already sees the row as expired when it runs.
        let delay = max(0, expiry.timeIntervalSinceNow) + 0.001
        timer.schedule(wallDeadline: .now() + delay, leeway: .milliseconds(50))
    }

    private func expiryTimerFired() {
        scheduledExpiry = nil
        chatList.isDirty = true
        publish(\.chatList, compute: { $0.computeChatList() })
    }
}
