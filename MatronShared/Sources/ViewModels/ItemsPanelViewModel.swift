import Foundation
import Observation
import MatronModels
import MatronJournal

/// The store reads the items panel and detail views need, as a protocol so
/// tests fake the store (mirrors `MediaBrowserStoreReading`'s pattern:
/// conformance for the real store is declared here since `MatronJournal`
/// cannot import this module).
public protocol ItemsStoreReading: Sendable {
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]>
    func itemStream(id: String) -> AsyncStream<TrackerItem?>
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]>
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]>
}
extension JournalStore: ItemsStoreReading {}

public protocol ItemsSyncing: Sendable {
    func refresh(scope: ItemsScope) async
    func refreshItem(id: String) async
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async
    func enqueueCreate(localID: String, _ new: NewItem) async
    func supportedStream() -> AsyncStream<Bool>
}
// `ItemsSync` is an actor; its (isolated) `supportedStream()` cannot
// satisfy `ItemsSyncing`'s nonisolated requirement under strict
// concurrency checking. `@preconcurrency` defers that check to runtime —
// safe here because `supportedStream()`'s body only touches actor state
// through the stream's `onTermination`, which itself hops back onto the
// actor with `Task { await self.dropSupported(id) }`.
extension ItemsSync: @preconcurrency ItemsSyncing {}

/// Backs the per-chat / cross-chat items panel (spec: Apps → Panel content).
/// Reads flow from the local store (`ItemsStoreReading`'s streams); writes
/// go through `ItemsSyncing`, which owns the outbox and refetch coalescing
/// — this view model never coalesces refetches itself.
@MainActor @Observable
public final class ItemsPanelViewModel {
    public struct Sections: Equatable, Sendable {
        public var needsYou: [TrackerItem] = []
        public var tasks: [TrackerItem] = []
        public var decisions: [TrackerItem] = []
        public var done: [TrackerItem] = []
        public init() {}
        public var isEmpty: Bool { needsYou.isEmpty && tasks.isEmpty && decisions.isEmpty && done.isEmpty }
    }

    public let convoID: String
    public var scope: ItemsScope { didSet { if scope != oldValue { resubscribe() } } }
    public private(set) var sections = Sections()
    public private(set) var needsYouCount = 0
    public private(set) var isSupported = true
    public private(set) var isRefreshing = false
    public var error: String?

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    private var itemsTask: Task<Void, Never>?
    private var supportedTask: Task<Void, Never>?

    public init(convoID: String, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing) {
        self.convoID = convoID; self.scope = .convo(convoID); self.store = store; self.api = api; self.sync = sync
    }

    /// Sections rule (spec *Panel content*): `needsYou` = `needsUser` (any
    /// kind) sorted `updatedAt` desc — an item can appear here AND in
    /// `tasks`. `tasks` = kind task, open, sorted rank/num. `decisions` =
    /// kind decision, open, `createdAt` desc. `done` = closed, `closedAt`
    /// desc, capped 200.
    public static func sections(from items: [TrackerItem]) -> Sections {
        var s = Sections()
        s.needsYou = items.filter(\.needsUser).sorted { $0.updatedAt > $1.updatedAt }
        s.tasks = items.filter { $0.kind == .task && $0.state == .open }.sorted { ($0.rank, $0.num) < ($1.rank, $1.num) }
        s.decisions = items.filter { $0.kind == .decision && $0.state == .open }.sorted { $0.createdAt > $1.createdAt }
        s.done = Array(items.filter { $0.state == .closed }.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }.prefix(200))
        return s
    }

    public func start() {
        resubscribe()
        supportedTask?.cancel()
        supportedTask = Task { [weak self] in
            guard let stream = self?.sync.supportedStream() else { return }
            for await v in stream {
                guard let self, !Task.isCancelled else { return }
                self.isSupported = v
            }
        }
    }

    public func stop() {
        itemsTask?.cancel(); itemsTask = nil
        supportedTask?.cancel(); supportedTask = nil
    }

    private func resubscribe() {
        itemsTask?.cancel()
        let scope = scope
        itemsTask = Task { [weak self] in
            guard let stream = self?.store.itemsStream(scope: scope) else { return }
            for await items in stream {
                guard let self, !Task.isCancelled else { return }
                self.sections = Self.sections(from: items)
                self.needsYouCount = self.sections.needsYou.count
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await sync.refresh(scope: scope)
    }

    /// Drag reorder inside the Tasks section. Optimistic: the local list is
    /// reordered first, the journal is told second, and a failure restores
    /// the previous order and surfaces the error. `after`/`before` are the
    /// moved item's new neighbours (computed post-removal); a move to
    /// either end sends a `position` instead.
    public func move(itemID: String, toIndex: Int) async {
        let before = sections.tasks
        guard let from = before.firstIndex(where: { $0.id == itemID }) else { return }
        var reordered = before
        let moved = reordered.remove(at: from)
        let target = min(max(toIndex, 0), reordered.count)
        reordered.insert(moved, at: target)
        let change: ItemRankChange
        if target == 0 { change = ItemRankChange(position: "top") }
        else if target == reordered.count - 1 { change = ItemRankChange(position: "bottom") }
        else { change = ItemRankChange(after: reordered[target - 1].id, before: reordered[target + 1].id) }
        sections.tasks = reordered
        do {
            _ = try await api.rankItem(id: itemID, change)
            await sync.refreshItem(id: itemID)
        } catch {
            sections.tasks = before
            self.error = error.localizedDescription
        }
    }

    public func create(kind: ItemKind, title: String, body: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200 else { error = "Give the item a title (up to 200 characters)."; return }
        await sync.enqueueCreate(localID: UUID().uuidString, NewItem(kind: kind, title: t, body: body, convoID: convoID))
    }
}
