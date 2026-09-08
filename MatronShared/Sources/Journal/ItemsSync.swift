import Foundation
import os
import MatronModels
import MatronEvents

/// Keeps the local tracker cache fresh (spec: Apps → ItemsSync). Three
/// triggers refetch: a marker event for an item (refetch that item), a
/// panel open / explicit refresh (since-watermark list), and a reconnect
/// (same). An item outbox holds comments and creates written offline and
/// drains whenever the connection is running.
public actor ItemsSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "items-sync")
    /// Pagination safety valve (fix round 1, minor #5): a runaway or
    /// looping server pagination must not spin this actor forever.
    private static let maxPages = 50

    private let api: any ItemsProviding
    private let store: JournalStore
    private let markers: @Sendable () -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    /// Base delay for the outbox retry backoff (`min(60s, retryBase ×
    /// 2^attempts)`). Overridable so tests can bound the wait instead of
    /// waiting out a real multi-second backoff.
    private let retryBase: TimeInterval
    private var markerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    /// Scheduled after a retryable drain failure; cancelled by `stop()` and
    /// by any fresh drain trigger (`drainOutbox()`), since a fresh trigger
    /// supersedes whatever backoff was pending.
    private var retryTask: Task<Void, Never>?
    /// Drain re-entrancy: a `while` loop rather than a plain guard so an
    /// enqueue that lands mid-drain (e.g. `enqueueComment` firing while a
    /// reconnect drain is in flight) is never lost — it sets `drainRequested`
    /// and the running drain loops once more before releasing `draining`.
    /// Only honored when the just-finished pass was clean (see
    /// `drainOutbox`) — a same-cycle re-request during a FAILED pass does
    /// not immediately retry (that would hammer a dead network); the
    /// scheduled backoff `retryTask` (or the next external trigger) handles
    /// that instead.
    private var draining = false
    private var drainRequested = false
    /// Per-item refetch coalescing (fix round 1, minor #8): a marker event
    /// and the drain's own inline `refreshItem` after a successful comment
    /// can race for the same item id. Rather than let two concurrent GETs
    /// land their `replaceComments` out of order, a refetch already in
    /// flight for an id just notes that another pass is wanted and returns;
    /// the in-flight call runs once more after it finishes.
    private var inFlightRefetches: Set<String> = []
    private var refetchAgain: Set<String> = []
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(api: any ItemsProviding, store: JournalStore,
                markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>,
                retryBase: TimeInterval = 2) {
        self.api = api; self.store = store; self.markers = markers; self.connectionStates = connectionStates
        self.retryBase = retryBase
    }

    public func supportedStream() -> AsyncStream<Bool> {
        AsyncStream { c in
            let id = UUID()
            supportedContinuations[id] = c
            c.yield(isSupported)
            c.onTermination = { _ in Task { await self.dropSupported(id) } }
        }
    }
    private func dropSupported(_ id: UUID) { supportedContinuations.removeValue(forKey: id) }
    private func setSupported(_ v: Bool) {
        guard v != isSupported else { return }
        isSupported = v
        for c in supportedContinuations.values { c.yield(v) }
    }

    public func start() {
        guard markerTask == nil else { return }
        let markers = markers()
        markerTask = Task { [weak self] in
            for await (_, marker) in markers {
                guard let self else { return }
                await self.refreshItem(id: marker.itemID)
            }
        }
        let states = connectionStates()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                if case .running = state {
                    // No `setSupported(true)` here: publishing "supported"
                    // before the probe would flash true→false for an old
                    // journal that 404s on GET /items. `refresh` publishes
                    // the real result once it knows it.
                    await self.refresh(scope: .all)
                    await self.drainOutbox()
                }
            }
        }
        // No eager `Task { await drainOutbox() }` here (fix round 1, minor
        // #6): the connection state stream always replays `.running` once
        // caught up, even on a cold start, and that already drains — a
        // second, unordered kick here only invited a race with the first
        // `enqueueComment` (see the fix-round-1 report for the bug that
        // race caused).
    }

    public func stop() {
        markerTask?.cancel(); markerTask = nil
        stateTask?.cancel(); stateTask = nil
        retryTask?.cancel(); retryTask = nil
    }

    public func refresh(scope: ItemsScope) async {
        var query = ItemsListQuery()
        query.limit = 500
        query.sort = .updated
        if case .convo(let id) = scope { query.convoID = id }
        if let mark = try? store.itemsWatermark(scope: scope) { query.since = mark.addingTimeInterval(-1) }
        // Newest `updated_at` across every page actually fetched this run.
        // Persisted as the new watermark ONLY if the whole loop completes
        // without throwing (see the `catch` below) — advancing it on a
        // partial run would let a later refresh believe it already has
        // data it never actually fetched, permanently skipping the gap.
        var newestSeen: Date?
        var seenCursors: Set<String> = []
        var pageCount = 0
        do {
            repeat {
                let page = try await api.listItems(query)
                try store.upsertItems(page.items)
                for i in page.items where newestSeen == nil || i.updatedAt > newestSeen! { newestSeen = i.updatedAt }
                pageCount += 1
                if let cursor = page.nextCursor, seenCursors.contains(cursor) {
                    Self.logger.error("refresh(\(String(describing: scope), privacy: .public)): nextCursor repeated (\(cursor, privacy: .public)) — stopping pagination")
                    query.cursor = nil
                } else if pageCount >= Self.maxPages {
                    if page.nextCursor != nil {
                        Self.logger.error("refresh(\(String(describing: scope), privacy: .public)): hit \(Self.maxPages, privacy: .public)-page cap — stopping pagination")
                    }
                    query.cursor = nil
                } else {
                    if let cursor = page.nextCursor { seenCursors.insert(cursor) }
                    query.cursor = page.nextCursor
                }
            } while query.cursor != nil
            if let newestSeen {
                do {
                    try store.setItemsWatermark(newestSeen, scope: scope)
                } catch {
                    Self.logger.error("setItemsWatermark failed for \(String(describing: scope), privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            setSupported(true)
        } catch JournalAPIError.notFound {
            setSupported(false)
        } catch {
            Self.logger.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func refreshItem(id: String) async {
        guard !inFlightRefetches.contains(id) else { refetchAgain.insert(id); return }
        inFlightRefetches.insert(id)
        defer { inFlightRefetches.remove(id) }
        await refreshItemOnce(id: id)
        while refetchAgain.remove(id) != nil {
            await refreshItemOnce(id: id)
        }
    }

    private func refreshItemOnce(id: String) async {
        do {
            let r = try await api.item(id: id)
            try store.upsertItems([r.item])
            try store.replaceComments(itemID: id, r.comments)
            setSupported(true)
        } catch {
            Self.logger.warning("item refetch \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct CommentPayload: Codable { var body: String; var attachments: [TrackerAttachment] }
    /// Only the fields the apps-side create flow currently needs.
    /// `labels`/`links`/`awaiting`/`position`/`supersedes` are deliberately
    /// not round-tripped through the outbox — `enqueueCreate` never
    /// receives them from callers yet (controller-deferred, fix round 1
    /// minor #11). If a caller starts passing them, extend this payload
    /// (and the `NewItem(...)` reconstruction in `drainOnce`) to match.
    private struct CreatePayload: Codable { var kind: String; var title: String; var body: String; var convoID: String; var attachments: [TrackerAttachment] }

    public func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {
        let payload = (try? String(data: JSONEncoder().encode(CommentPayload(body: body, attachments: attachments)), encoding: .utf8)) ?? "{}"
        do {
            try store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: itemID, op: "comment", payloadJSON: payload,
                                                         createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        } catch {
            Self.logger.error("enqueueComment insert failed for \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await drainOutbox()
    }

    public func enqueueCreate(localID: String, _ new: NewItem) async {
        let payload = (try? String(data: JSONEncoder().encode(CreatePayload(kind: new.kind.rawValue, title: new.title, body: new.body, convoID: new.convoID, attachments: new.attachments)), encoding: .utf8)) ?? "{}"
        do {
            try store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: nil, op: "create", payloadJSON: payload,
                                                         createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        } catch {
            Self.logger.error("enqueueCreate insert failed for \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await drainOutbox()
    }

    public func drainOutbox() async {
        // A fresh trigger (an enqueue, a reconnect, `start()`) supersedes
        // any pending backoff retry.
        retryTask?.cancel(); retryTask = nil
        guard !draining else { drainRequested = true; return }
        draining = true
        defer { draining = false }
        repeat {
            drainRequested = false
            if let attempts = await drainOnce() {
                // Stopped early on a retryable failure: schedule the
                // backoff retry and stop, even if `drainRequested` got set
                // while we were mid-attempt (e.g. another caller kicked
                // `drainOutbox()` during the same failing network call) —
                // retrying instantly would just fail the same way again.
                scheduleRetry(afterAttempts: attempts)
                break
            }
        } while drainRequested
    }

    private func scheduleRetry(afterAttempts attempts: Int) {
        let delay = min(60, retryBase * pow(2, Double(attempts)))
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.drainOutbox()
        }
    }

    /// `JournalAPIError` cases that mean "this exact request can never
    /// succeed" (a poison row) vs. "try again later" (offline / transient
    /// server trouble). Any other `Error` (a decode failure, an unexpected
    /// throw) is treated as retryable — the safe default for something we
    /// don't recognize is to not silently drop a user's data.
    private func isRetryable(_ error: Error) -> Bool {
        guard let apiError = error as? JournalAPIError else { return true }
        switch apiError {
        case .notFound, .conflict, .forbidden, .unauthenticated, .badCredentials:
            return false
        case .http(let status, _):
            if status == 408 || status == 429 { return true }
            return !(400...499).contains(status)
        case .lockedOut, .rateLimited, .transport:
            return true
        }
    }

    /// Returns the failed row's post-mark attempt count if it stopped early
    /// on a retryable failure, or `nil` if every pending row was either
    /// applied or dropped as poison (a non-retryable rejection) — in both
    /// of the `nil` sub-cases the whole pass completed.
    private func drainOnce() async -> Int? {
        guard let rows = try? store.itemOutboxPending() else { return nil }
        for row in rows {
            do {
                switch row.op {
                case "comment":
                    guard let itemID = row.itemID, let data = row.payloadJSON.data(using: .utf8),
                          let p = try? JSONDecoder().decode(CommentPayload.self, from: data) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let r = try await api.commentItem(id: itemID, body: p.body, attachments: p.attachments, idempotencyKey: row.localID)
                    try store.itemOutboxDelete(localID: row.localID)
                    try store.upsertItems([r.item])
                    await refreshItem(id: itemID)
                case "create":
                    guard let data = row.payloadJSON.data(using: .utf8), let p = try? JSONDecoder().decode(CreatePayload.self, from: data),
                          let kind = ItemKind(rawValue: p.kind) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let item = try await api.createItem(NewItem(kind: kind, title: p.title, body: p.body, attachments: p.attachments, convoID: p.convoID), idempotencyKey: row.localID)
                    try store.itemOutboxDelete(localID: row.localID)
                    try store.upsertItems([item])
                default:
                    try store.itemOutboxDelete(localID: row.localID)
                }
            } catch {
                if isRetryable(error) {
                    do {
                        try store.itemOutboxMarkAttempt(localID: row.localID, error: error.localizedDescription)
                    } catch let markError {
                        Self.logger.error("itemOutboxMarkAttempt failed for \(row.localID, privacy: .public): \(markError.localizedDescription, privacy: .public)")
                    }
                    // Stop at the first retryable failure: the rest will
                    // fail the same way (offline) and order matters for
                    // comments on one item.
                    return row.attempts + 1
                }
                // Poison row: a non-retryable rejection (404, 409, 4xx)
                // will never succeed on retry — drop it and keep draining
                // the rest of the queue instead of blocking behind it.
                Self.logger.error("outbox row \(row.localID, privacy: .public) rejected non-retryably (\(error.localizedDescription, privacy: .public)) — dropping")
                do {
                    try store.itemOutboxDelete(localID: row.localID)
                } catch let delError {
                    Self.logger.error("itemOutboxDelete failed for poisoned row \(row.localID, privacy: .public): \(delError.localizedDescription, privacy: .public)")
                }
            }
        }
        return nil
    }
}
