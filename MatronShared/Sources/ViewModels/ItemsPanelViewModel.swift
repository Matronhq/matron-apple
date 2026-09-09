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
    /// Synchronous snapshot of `commentsStream`'s current value — read by
    /// `ItemDetailViewModel` right after its opening refetch returns, so
    /// `hasLoadedThread` never flips ahead of the thread it vouches for.
    func comments(itemID: String) throws -> [TrackerComment]
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]>
    /// Every queued "create" outbox row, feeding `ItemsPanelViewModel.pendingCreates`.
    func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]>
    /// Every conversation's items regardless of the panel's scope — the
    /// source of `ItemsPanelViewModel.awaitingYou` (app shell, spec §1).
    /// Defaulted to `itemsStream(scope: .all)` below so `JournalStore`
    /// needs no new query; fakes override it to drive it separately.
    func needsUserStream() -> AsyncStream<[TrackerItem]>
}
extension JournalStore: ItemsStoreReading {}
public extension ItemsStoreReading {
    func needsUserStream() -> AsyncStream<[TrackerItem]> { itemsStream(scope: .all) }
}

public protocol ItemsSyncing: Sendable {
    func refresh(scope: ItemsScope) async
    func refreshItem(id: String) async
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async
    /// Returns whether the outbox insert itself succeeded (fix wave, item
    /// I3) — `false` when the sync engine is stopped or the local write
    /// throws. Callers use this to tell "your item is queued" apart from
    /// "nothing happened"; delivery to the server is a separate, unawaited
    /// background drain (fix wave, item I2), so a `true` here means only
    /// that the row is durably queued, not that it has reached the
    /// journal yet. `@discardableResult` — most other call sites (outbox
    /// replay, tests that don't care) still don't need the value.
    @discardableResult
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool
    // `async` (rather than a plain nonisolated requirement) because
    // `ItemsSync` is an actor and its `supportedStream()` is
    // actor-isolated — an async requirement lets that isolated method
    // satisfy the protocol with no unsafe conformance, and a synchronous
    // fake still satisfies an async requirement trivially.
    func supportedStream() async -> AsyncStream<Bool>
}
extension ItemsSync: ItemsSyncing {}

/// `TrackerItem.rank` is `let` (the model has no mutation API) — this is
/// the VM-local way to stage an optimistic rank for a drag reorder ahead
/// of the server's own recompute, without adding a public setter to the
/// model just for this one call site.
private extension TrackerItem {
    func with(rank: Double) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: resolution, awaiting: awaiting,
                    rank: rank, title: title, body: body, labels: labels, links: links, attachments: attachments,
                    supersedes: supersedes, originConvoID: originConvoID, createdBy: createdBy, createdAt: createdAt,
                    updatedAt: updatedAt, closedAt: closedAt, commentCount: commentCount, lastCommentAt: lastCommentAt,
                    hasImage: hasImage)
    }
}

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

    /// A local "create" outbox row that hasn't landed on the server yet
    /// (fix wave, item C) — without this, an offline/in-flight create is
    /// invisible: the create sheet dismisses and the row lives only in
    /// `item_outbox` until the drain succeeds, with no on-screen trace in
    /// the meantime.
    public struct PendingItem: Equatable, Identifiable, Sendable {
        public let id: String
        public let kind: ItemKind
        public let title: String
        public let attempts: Int
        public let lastError: String?
        public init(id: String, kind: ItemKind, title: String, attempts: Int, lastError: String?) {
            self.id = id; self.kind = kind; self.title = title; self.attempts = attempts; self.lastError = lastError
        }
    }

    /// Matches `ItemsSync.CreatePayload`'s JSON shape (kind/title/body/
    /// convoID/attachments) — a private type there, so this decodes the
    /// same wire shape independently rather than reaching across files for
    /// a `private` type. Only the fields this VM actually surfaces are
    /// declared; unknown/absent extra keys are ignored by `Decodable`.
    private struct PendingCreatePayload: Decodable { var kind: String; var title: String; var convoID: String }

    /// The home conversation, or `nil` for the app-wide Decisions instance
    /// (spec §1): `nil` starts `scope` at `.all`, disables `create` (no
    /// conversation to file into) and leaves `needsYouCount` at zero.
    public let convoID: String?
    public var scope: ItemsScope { didSet { if scope != oldValue { resubscribe() } } }
    public private(set) var sections = Sections()
    /// Items in THIS conversation awaiting the user — the toolbar badge.
    /// Scoped to `convoID` regardless of the panel's current `scope`, so
    /// switching the list to "All" doesn't inflate the chat's badge.
    public private(set) var needsYouCount = 0
    /// Every open item awaiting the user across ALL conversations, newest
    /// `updatedAt` first — independent of `scope`, fed by its own
    /// `needsUserStream()` subscription. Backs the Decisions list and the
    /// tab / nav badge (spec §1, §2).
    public private(set) var awaitingYou: [TrackerItem] = []
    public var awaitingYouCount: Int { awaitingYou.count }
    public private(set) var isSupported = true
    public private(set) var isRefreshing = false
    /// Creates still sitting in the local outbox, not yet confirmed by the
    /// server — filtered to `convoID` when `scope` is `.convo`, unfiltered
    /// when `scope` is `.all` (`scope` is always either `.convo(convoID)`
    /// or `.all` — see `ItemsListView`'s scope picker).
    public private(set) var pendingCreates: [PendingItem] = []
    public var error: String?

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    private var itemsTask: Task<Void, Never>?
    private var pendingCreatesTask: Task<Void, Never>?
    private var supportedTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var awaitingTask: Task<Void, Never>?

    public init(convoID: String?, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing) {
        self.convoID = convoID
        self.scope = convoID.map { .convo($0) } ?? .all
        self.store = store; self.api = api; self.sync = sync
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

    /// Monotonic token identifying the current observation run; bumped by
    /// every `start()`. This VM is shared per-room across surfaces (e.g.
    /// the Mac pane VM survives while the pane is closed, per this file's
    /// own doc comments), and SwiftUI can run a successor view's
    /// `.task`/`start()` before a predecessor's `onDisappear` — the same
    /// remount hazard `ChatViewModel`/`SubChatStripViewModel` guard
    /// against. Hosts record the generation after their `start()` and pass
    /// it to `stop(ifGeneration:)` so a stale surface's teardown can never
    /// cancel a successor's fresh stream.
    public private(set) var observationGeneration: Int = 0

    public func start() {
        observationGeneration += 1
        stop()
        resubscribe()
        awaitingTask = Task { [weak self] in
            guard let stream = self?.store.needsUserStream() else { return }
            for await items in stream {
                guard let self, !Task.isCancelled else { return }
                self.awaitingYou = items.filter(\.needsUser).sorted { $0.updatedAt > $1.updatedAt }
            }
        }
        supportedTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.sync.supportedStream()
            for await v in stream {
                guard !Task.isCancelled else { return }
                self.isSupported = v
            }
        }
    }

    /// Stops the observation only if `generation` still identifies the
    /// current run — a stale host's `onDisappear` (which can fire AFTER
    /// its successor's `start()`) becomes a no-op instead of killing the
    /// shared stream. Mirrors `SubChatStripViewModel.stop(ifGeneration:)`.
    public func stop(ifGeneration generation: Int) {
        guard generation == observationGeneration else { return }
        stop()
    }

    public func stop() {
        awaitingTask?.cancel(); awaitingTask = nil
        itemsTask?.cancel(); itemsTask = nil
        pendingCreatesTask?.cancel(); pendingCreatesTask = nil
        supportedTask?.cancel(); supportedTask = nil
        refreshTask?.cancel(); refreshTask = nil
    }

    private func resubscribe() {
        itemsTask?.cancel()
        let scope = scope
        itemsTask = Task { [weak self] in
            guard let stream = self?.store.itemsStream(scope: scope) else { return }
            for await items in stream {
                guard let self, !Task.isCancelled else { return }
                self.sections = Self.sections(from: items)
                self.needsYouCount = self.convoID.map { home in self.sections.needsYou.filter { $0.originConvoID == home }.count } ?? 0
            }
        }
        pendingCreatesTask?.cancel()
        pendingCreatesTask = Task { [weak self] in
            guard let stream = self?.store.itemOutboxCreatesStream() else { return }
            for await rows in stream {
                guard let self, !Task.isCancelled else { return }
                self.pendingCreates = rows.compactMap { row in
                    guard let data = row.payloadJSON.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(PendingCreatePayload.self, from: data),
                          let kind = ItemKind(rawValue: payload.kind) else { return nil }
                    if case .convo(let home) = scope, payload.convoID != home { return nil }
                    return PendingItem(id: row.localID, kind: kind, title: payload.title, attempts: row.attempts, lastError: row.lastError)
                }
            }
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
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
        // Stage a real, ordered `rank` on the moved item — not just a
        // reordered array — so a store emission that lands while
        // `rankItem` is still in flight (an unrelated row changing status,
        // say) recomputes sections from ranks that already agree with the
        // optimistic order, instead of snapping back to the pre-move rank.
        let optimisticRank: Double
        if reordered.isEmpty { optimisticRank = moved.rank }
        else if target == 0 { optimisticRank = reordered[0].rank - 1024 }
        else if target == reordered.count { optimisticRank = reordered[reordered.count - 1].rank + 1024 }
        else { optimisticRank = (reordered[target - 1].rank + reordered[target].rank) / 2 }
        let patchedMoved = moved.with(rank: optimisticRank)
        reordered.insert(patchedMoved, at: target)
        guard reordered.map(\.id) != before.map(\.id) else { return }
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
        guard let convoID else { error = "Open a chat's tracker to file a new item."; return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200 else { error = "Give the item a title (up to 200 characters)."; return }
        let queued = await sync.enqueueCreate(localID: UUID().uuidString, NewItem(kind: kind, title: t, body: body, convoID: convoID))
        if !queued { error = "Couldn't file the item — try again." }
    }
}
