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
    /// Synchronous snapshots of `itemStream` / `itemOutboxStream` — read by
    /// `ItemDetailViewModel.chooseAction` the moment its enqueue returns,
    /// so the tapped button never shows unselected in the gap before the
    /// streams catch up (review, PR #242).
    func item(id: String) throws -> TrackerItem?
    func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord]
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
    /// Returns what the pass actually did so a
    /// caller that re-reads the store afterwards can tell "fetched, and it
    /// really isn't there" from "the fetch failed". `@discardableResult` —
    /// the panel and the reconnect kick still only want the side effects.
    @discardableResult
    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome
    func refreshItem(id: String) async
    /// `action` marks the reply as a tap on that action (`nil` for a typed
    /// reply) and `replyTo` names the comment whose buttons it answers
    /// (`nil` for the item's own); both ride the outbox row to the POST.
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async
    /// Queues a typed reply and returns as soon as its outbox row is
    /// durable — `true` — or `false` when nothing was queued (stopped, or
    /// the local write failed). Delivery is a background drain, NOT awaited,
    /// unlike `enqueueComment`: the reply composer shows its "Sending…"
    /// row only until the reply is queued, and must not still be showing it
    /// when the drain has already posted the comment into the thread.
    @discardableResult
    func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool
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
    /// Try every queued outbox row now, skipping any backoff wait — the
    /// item thread's Send now on a reply that hasn't reached the journal.
    func drainOutbox() async
    /// Withdraws a reply still in the outbox before it is posted — the
    /// item thread's Cancel.
    func cancelQueuedComment(localID: String) async -> OutboxCancelResult
    // `async` (rather than a plain nonisolated requirement) because
    // `ItemsSync` is an actor and its `supportedStream()` is
    // actor-isolated — an async requirement lets that isolated method
    // satisfy the protocol with no unsafe conformance, and a synchronous
    // fake still satisfies an async requirement trivially.
    func supportedStream() async -> AsyncStream<Bool>
}
extension ItemsSync: ItemsSyncing {}

public extension ItemsSyncing {
    /// No outbox to drain — test doubles and read-only hosts. `ItemsSync`
    /// has the real one.
    func drainOutbox() async {}
    /// No outbox to withdraw from.
    func cancelQueuedComment(localID: String) async -> OutboxCancelResult { .failed }
}

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
                    hasImage: hasImage, missionID: missionID, missionNum: missionNum)
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
        /// Closed questions and decisions — backs the Decisions view's
        /// Closed tab: once closed, an item stays findable here instead
        /// of vanishing. Ordered by `TrackerItem.closedSortDate`, newest
        /// first, `num` desc as the tie-break. See `isDecided(_:)` — ANY closed
        /// question/decision counts, whatever its resolution (the journal
        /// doesn't enforce kind/resolution pairing, so a question closed
        /// `.done` or `.cancelled` must still show up here). Deliberately a
        /// plain field here rather than something `isEmpty` accounts for
        /// below — the per-conversation items pane (`ItemsListView`/
        /// `MacItemsPane`) shares this same `Sections` type but never
        /// reads this field, and its own emptiness check must stay exactly
        /// as it was.
        public var decided: [TrackerItem] = []
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
    ///
    /// Notices the user has tapped "Seen" on (`markSeen`) drop out at once,
    /// ahead of the journal closing them, so the list and badge never
    /// wait on the network — or on reconnecting, when offline.
    public private(set) var awaitingYou: [TrackerItem] = []
    /// `awaitingYou.count` and `awaitingYou`'s distinct origin
    /// conversations (what the shells key their origin-label fetch on).
    /// Both are read in the shells' root body, so each is its own stored
    /// property, written only when its value changes: `awaitingYou`
    /// changes whenever any awaiting item is touched, these two far less
    /// often — so a touched item no longer re-evaluates the whole window.
    public private(set) var awaitingYouCount = 0
    public private(set) var awaitingOriginConvoIDs: Set<String> = []
    /// The store's latest awaiting list, before `seenInFlight` is hidden.
    private var awaitingSource: [TrackerItem] = []
    /// Notices whose "Seen" tap is queued or on its way. Each leaves as
    /// soon as the store stops reporting the notice as awaiting the user.
    private var seenInFlight: Set<String> = []
    /// Ranks staged by drag reorders the journal hasn't confirmed yet,
    /// laid over every store emission until it does — the store still
    /// holds the pre-move rank, so without this a write landing mid-flight
    /// (or a sort that started before the drag) snaps the task back.
    private var stagedRanks: [String: Double] = [:]
    public private(set) var isSupported = true
    public private(set) var isRefreshing = false
    /// Creates still sitting in the local outbox, not yet confirmed by the
    /// server — filtered to `convoID` when `scope` is `.convo`, unfiltered
    /// when `scope` is `.all` (`scope` is always either `.convo(convoID)`
    /// or `.all` — see `ItemsListView`'s scope picker).
    public private(set) var pendingCreates: [PendingItem] = []
    public var error: String?

    /// Every locally-known closed question/decision, ordered by the user's
    /// own last input on each, newest first (`TrackerItem.closedSortDate`)
    /// — the For you list's Closed tab. Deliberately
    /// a top-level property, not folded into `sections`: it tracks the
    /// `.all`-scope stream the app-wide Decisions instance subscribes to
    /// (like `awaitingYou`), while the per-conversation items pane's own
    /// `ItemsPanelViewModel` never populates it — see `resubscribe()`.
    ///
    /// This is ENTIRELY a local derivation: the general `.all`-scope sync
    /// (`ItemsSync.refresh`) already fetches with no `state` filter, so the
    /// local `item` table mirrors every closed item this device has ever
    /// seen, same as any other item. There is deliberately no separate
    /// server backfill for this section — one was tried and reverted
    /// (review, 2026-09-29): it mostly re-fetched rows already local (the
    /// journal has no `kind` filter for `state=closed` either, so most of
    /// a page was closed TASKS this section doesn't even show), left a
    /// "Show more" that could spin and reveal nothing once local data ran
    /// out, and surfaced a network-error alert under an otherwise-complete
    /// list when offline.
    public private(set) var decided: [TrackerItem] = []
    /// `decided`'s distinct origin conversation ids, recomputed once per
    /// store emission (not once per SwiftUI render) — feeds the host
    /// shells' `originConvoIDs` label-fetch `.task(id:)` without handing it
    /// every individual decided item (review, 2026-09-29): `decided` is
    /// unbounded (every closed item ever), while the number of DISTINCT
    /// conversations they came from grows far more slowly.
    public private(set) var decidedOriginConvoIDs: Set<String> = []
    /// How many of `decided`, from the front, the view currently shows —
    /// grows via `showMoreDecided()` and is otherwise re-derived from
    /// `desiredDecidedVisibleCount` on every store emission, so an
    /// unrelated item changing elsewhere never resets how far the user has
    /// already expanded the section.
    public private(set) var decidedVisibleCount = 0
    /// Whether there's more of `decided` beyond the current window — purely
    /// local (see `decided`'s doc comment): there is no server page beyond
    /// what's already synced to reach for.
    public var hasMoreDecided: Bool { decidedVisibleCount < decided.count }
    /// Which For you tab is showing. The hosts map `decided` into rows
    /// only while it is `.closed`, so the open list never pays for it.
    public var forYouTab: ForYouTab = .open

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    private var itemsTask: Task<Void, Never>?
    private var pendingCreatesTask: Task<Void, Never>?
    private var supportedTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var awaitingTask: Task<Void, Never>?
    /// The user's actual intent for how many `decided` rows to show —
    /// grown by `showMoreDecided()`; `decidedVisibleCount` is always
    /// `min(desiredDecidedVisibleCount, decided.count)`, recomputed
    /// whenever either changes.
    private var desiredDecidedVisibleCount = 0

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
    private nonisolated static func deriveSections(from items: [TrackerItem]) async -> Sections {
        sections(from: items)
    }

    private nonisolated static func applying(_ ranks: [String: Double], to tasks: [TrackerItem]) -> [TrackerItem] {
        tasks.map { task in ranks[task.id].map { task.with(rank: $0) } ?? task }
            .sorted { ($0.rank, $0.num) < ($1.rank, $1.num) }
    }

    public nonisolated static func sections(from items: [TrackerItem]) -> Sections {
        var s = Sections()
        s.needsYou = items.filter(\.needsUser).sorted { $0.updatedAt > $1.updatedAt }
        s.tasks = items.filter { $0.kind == .task && $0.state == .open }.sorted { ($0.rank, $0.num) < ($1.rank, $1.num) }
        s.decisions = items.filter { $0.kind == .decision && $0.state == .open }.sorted { $0.createdAt > $1.createdAt }
        s.done = Array(items.filter { $0.state == .closed }.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }.prefix(200))
        s.decided = items.filter(isDecided).sorted { a, b in
            let l = a.closedSortDate; let r = b.closedSortDate
            return l == r ? a.num > b.num : l > r
        }
        return s
    }

    /// Whether a closed item belongs in the For you list's Closed
    /// tab: any closed question or decision, WHATEVER its resolution.
    /// Never a task. Deliberately not filtered by resolution (review,
    /// 2026-09-29, reverting an earlier `.answered`/`.decided`/`.reversed`/
    /// `.cancelled` allowlist): the journal does not enforce kind/resolution
    /// pairing, so a question closed `.done` or `.cancelled` (an agent
    /// abandoning it rather than answering it) is still a real, closed
    /// question that must stay findable here — the section's job is "this
    /// question/decision is no longer open", not "and it resolved a
    /// particular way". `ItemGlyph.closedCaption` shows whatever
    /// resolution the item actually carries.
    ///
    /// Never a notice either: a notice is something to read, closed by its
    /// "Seen" tap, and nothing about it was decided.
    public nonisolated static func isDecided(_ item: TrackerItem) -> Bool {
        item.state == .closed && (item.kind == .question || item.kind == .decision)
    }

    /// The Decided section's default visible row count: the latest
    /// `latest` closed items. It was "the last 14 days or
    /// the latest 20" while the tracker was small; at about 300 closed
    /// items a day, 14 days was about 3,000 rows, each rebuilt and
    /// re-diffed on every item change. `decided` must already be in its
    /// display order.
    public static func defaultDecidedWindow(_ decided: [TrackerItem], latest: Int = 50) -> Int {
        min(latest, decided.count)
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
                let awaiting = items.filter(\.needsUser).sorted { $0.updatedAt > $1.updatedAt }
                // A Seen tap stops hiding its notice once the store no
                // longer has it awaiting the user (the journal closed it).
                self.seenInFlight.formIntersection(awaiting.map(\.id))
                self.awaitingSource = awaiting
                self.publishAwaitingYou()
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
                // Every item write re-fires the `.all` stream with every
                // item ever synced (5,088 on one real store); the
                // filter-and-sort runs off the main actor.
                var sections = await Self.deriveSections(from: items)
                guard let self, !Task.isCancelled else { return }
                if !self.stagedRanks.isEmpty {
                    sections.tasks = Self.applying(self.stagedRanks, to: sections.tasks)
                }
                self.sections = sections
                self.needsYouCount = self.convoID.map { home in self.sections.needsYou.filter { $0.originConvoID == home }.count } ?? 0
                // Only the app-wide Decisions instance (`convoID == nil`)
                // ever surfaces `decided` — a per-conversation items pane's
                // own VM would otherwise redo this filter/sort/window work
                // on every emission of ITS OWN stream for a field nothing
                // reads (review, 2026-09-29).
                if self.convoID == nil {
                    self.updateDecided(self.sections.decided)
                }
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

    private func publishAwaitingYou() {
        awaitingYou = seenInFlight.isEmpty ? awaitingSource : awaitingSource.filter { !seenInFlight.contains($0.id) }
        // Explicit: an `@Observable` setter only skips an equal write on
        // newer toolchains (Swift 6.3 here; CI's still notifies).
        if awaitingYouCount != awaitingYou.count { awaitingYouCount = awaitingYou.count }
        let origins = Set(awaitingYou.map(\.originConvoID))
        if awaitingOriginConvoIDs != origins { awaitingOriginConvoIDs = origins }
    }

    /// The For you row's "Seen" button and swipe action: answers the
    /// notice with its one action, the same offline-safe outbox write as
    /// tapping the button in the item's thread
    /// (`ItemDetailViewModel.chooseAction`) — the journal closes the
    /// notice as done when the tap lands. The row leaves `awaitingYou` at
    /// once. Ignored for anything that is not an open notice offering
    /// "Seen", and for a second tap while the first is on its way.
    public func markSeen(_ itemID: String) async {
        guard !seenInFlight.contains(itemID),
              let item = awaitingSource.first(where: { $0.id == itemID }), item.offersSeen else { return }
        seenInFlight.insert(itemID)
        publishAwaitingYou()
        let label = TrackerItem.seenAction
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: label, attachments: [], action: label, replyTo: nil)
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await sync.refresh(scope: scope)
    }

    /// Recomputes `decided`/`decidedOriginConvoIDs`/`decidedVisibleCount`
    /// from a fresh store emission. `desiredDecidedVisibleCount` only ever
    /// grows — it's `max`'d against a freshly-computed
    /// `defaultDecidedWindow` on every emission (not just seeded once), so
    /// a newly-closed item arriving after this VM started with zero
    /// decided items still grows the window to show it, while an unrelated
    /// item changing elsewhere (which re-fires this same stream) never
    /// shrinks a window the user has already expanded with
    /// `showMoreDecided()`.
    private func updateDecided(_ decided: [TrackerItem]) {
        if self.decided != decided { self.decided = decided }
        let origins = Set(decided.map(\.originConvoID))
        if decidedOriginConvoIDs != origins { decidedOriginConvoIDs = origins }
        desiredDecidedVisibleCount = max(desiredDecidedVisibleCount, Self.defaultDecidedWindow(decided))
        let visible = min(desiredDecidedVisibleCount, decided.count)
        if decidedVisibleCount != visible { decidedVisibleCount = visible }
    }

    /// The "Show more" action: grows the visible window — purely from
    /// local data (see `decided`'s doc comment for why there's no server
    /// reach beyond that).
    private static let decidedPageSize = 50
    public func showMoreDecided() {
        desiredDecidedVisibleCount += Self.decidedPageSize
        decidedVisibleCount = min(desiredDecidedVisibleCount, decided.count)
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
        // optimistic order (via `stagedRanks`), instead of snapping back
        // to the pre-move rank.
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
        stagedRanks[itemID] = optimisticRank
        // A later drag of the same item owns the entry from here on.
        defer { if stagedRanks[itemID] == optimisticRank { stagedRanks[itemID] = nil } }
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
