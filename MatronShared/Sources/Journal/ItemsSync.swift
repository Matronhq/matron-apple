import Foundation
import os
import MatronModels
import MatronEvents

/// Why a `refresh(scope:)` pass could not fetch, in a form that can leave
/// the actor.
///
/// It carries the message rather than the error because the outcome travels
/// out through a `Task` value (the refresh-coalescing joiners), and `Task`'s
/// success type must be `Sendable` — `any Error` is not. The concrete error
/// stays where it was caught: in the log line next to this. What callers
/// actually need is the sentence to show the user, and `localizedDescription`
/// is what they were showing anyway.
public struct ItemsRefreshFailure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ error: any Error) { self.message = error.localizedDescription }
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What a `refresh(scope:)` pass actually did (item #115, fix round 5).
///
/// The refresh has always swallowed its own failures — it drives a banner,
/// not a `throws` — which is right for a banner and wrong for anything that
/// reads the store afterwards and draws a conclusion from a MISS.
/// `TrackerItemLinkResolver` did exactly that, and told the user a tapped
/// `#65` "isn't on this device yet" when the truth was "you're offline".
public enum ItemsRefreshOutcome: Equatable, Sendable {
    /// The list was fetched (possibly truncated by the page cap) and the
    /// store is up to date as far as this pass got.
    case succeeded
    /// The journal has no tracker routes (404). Not a transport fault: the
    /// server answered, and `isSupported` is now false.
    case unsupported
    /// `stop()` landed mid-pass (sign-out / teardown), so the run was
    /// abandoned before writing. Nothing was fetched, but nothing failed
    /// either — and by definition nobody is left on screen to be told.
    case stopped
    /// The fetch (or a store write inside it) threw.
    case failed(ItemsRefreshFailure)
}

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
    /// flight for an id just notes that another pass is wanted and then
    /// AWAITS that run (Bugbot, PR #198: callers such as the detail view
    /// model take "refreshItem returned" to mean "the store now holds the
    /// server's thread", so an early return would let a stale cache pass
    /// as loaded); the in-flight run repeats once more after it finishes.
    private var inFlightRefetches: [String: Task<Void, Never>] = [:]
    private var refetchAgain: Set<String> = []
    /// Per-SCOPE list-refresh coalescing (fix round 3). `refreshItem` has
    /// always coalesced; `refresh(scope:)` did not, so a reconnect, a panel
    /// pull-to-refresh and a tracker-link miss retry
    /// (`TrackerItemLinkResolver`) landing together each ran their own full
    /// paginated GET over the same rows. Concurrent callers now await the
    /// run already in flight for that scope.
    ///
    /// Deliberately NOT `refetchAgain`-style repeat: a joiner wants "the
    /// list, freshly fetched", not "a fetch that started strictly after I
    /// asked". The cost is a narrow window — an item created after the
    /// running pass issued its request isn't guaranteed to be in it — which
    /// the link resolver reports honestly as "not on this device yet"
    /// rather than papering over with a second full fetch per tap.
    private var inFlightRefreshes: [ItemsScope: Task<ItemsRefreshOutcome, Never>] = [:]
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// Set by `stop()`, cleared by `start()`. Fix wave, item G: `stop()`
    /// used to just cancel the marker/state/retry `Task`s and return —
    /// anything already suspended mid-await inside `refresh`,
    /// `refreshItemOnce` or `drainOnce` (a network call in flight, most
    /// commonly) would resume once its `await` completed and go right on
    /// writing to the store, racing whatever `stop()`'s caller does next
    /// (a sign-out `wipe()`, most commonly). Every write site in those
    /// three methods re-checks this flag immediately after its await,
    /// before touching `store`.
    private var stopped = false

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
        stopped = false
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

    /// `async` (fix wave, item G): cancelling the marker/state/retry
    /// `Task`s alone let a suspended in-flight refresh/refetch/drain resume
    /// after this returned and write to the store — a race with whatever
    /// the caller does next (typically a sign-out wipe). Awaiting each
    /// task's `.value` after cancelling it means `stop()` genuinely doesn't
    /// return until nothing more will happen; combined with the `stopped`
    /// checks inside `refresh`/`refreshItemOnce`/`drainOnce`, a suspended
    /// await that resumes with cancellation still pending bails out before
    /// touching the store instead of completing the write. Both app hosts'
    /// `AppDependencies` teardowns already call this with `await`, and
    /// `ItemsSyncing` (the protocol VMs depend on) doesn't expose `stop` at
    /// all, so this is source-compatible.
    ///
    /// Item #115, fix round 7: this used to stop only the marker/state/
    /// retry tasks — any `refresh(scope:)` suspended inside `listItems`
    /// (an `inFlightRefreshes` entry) was left running. `stopped` alone
    /// didn't protect it: `refreshOnce`'s guard fires on RESUME, and if a
    /// caller called `start()` (which resets `stopped = false`) before that
    /// resume happened, the guard read `stopped` as false again and wrote
    /// pre-stop data into a session that had already moved on. Now `stop()`
    /// cancels every in-flight refresh AND awaits it before returning, so
    /// `start()` can never run until the old task has already taken its
    /// `Task.isCancelled` exit in `refreshOnce` — the map is empty (every
    /// task deregisters itself on the way out) by the time this returns.
    public func stop() async {
        stopped = true
        let mt = markerTask; let st = stateTask; let rt = retryTask
        markerTask = nil; stateTask = nil; retryTask = nil
        mt?.cancel(); st?.cancel(); rt?.cancel()
        let refreshes = Array(inFlightRefreshes.values)
        for task in refreshes { task.cancel() }
        await mt?.value; await st?.value; await rt?.value
        for task in refreshes { _ = await task.value }
        inFlightRefreshes = [:]
    }

    /// Runs a list refresh and REPORTS what happened (item #115, fix round
    /// 5). This used to swallow every outcome: it drives a banner and an
    /// `isSupported` flag, so nothing needed a return value — until
    /// `TrackerItemLinkResolver` started using "refreshed, still missing"
    /// to tell the user an item "isn't on this device yet". Offline, that
    /// sentence was a lie: the fetch never happened. Callers that only want
    /// the side effects can still ignore the result.
    ///
    /// Joiners of a coalesced run get the SAME outcome as the owner — the
    /// value comes out of the one shared `Task`, so two taps racing a
    /// single fetch can't disagree about whether it worked.
    @discardableResult
    public func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome {
        if let running = inFlightRefreshes[scope] {
            return await running.value
        }
        let run = Task { [self] in
            let outcome = await refreshOnce(scope: scope)
            // Deregistered here, with no suspension between the last line
            // of the run and the removal — same discipline as
            // `refreshItem`, so a joiner can never await a task that has
            // already finished AND deregistered.
            inFlightRefreshes[scope] = nil
            return outcome
        }
        inFlightRefreshes[scope] = run
        return await run.value
    }

    private func refreshOnce(scope: ItemsScope) async -> ItemsRefreshOutcome {
        var query = ItemsListQuery()
        query.limit = 500
        query.sort = .updated
        if case .convo(let id) = scope { query.convoID = id }
        if let mark = try? store.itemsWatermark(scope: scope) { query.since = mark.addingTimeInterval(-1) }
        // Newest `updated_at` across every page actually fetched this run.
        // Persisted as the new watermark ONLY if the whole loop completes
        // without throwing AND without truncating (see `truncated` below)
        // — advancing it on a partial run would let a later refresh
        // believe it already has data it never actually fetched,
        // permanently skipping the gap.
        var newestSeen: Date?
        var seenCursors: Set<String> = []
        var pageCount = 0
        // Set by either bail-out branch below (fix round 2, IMPORTANT #2):
        // both the repeated-cursor guard and the page cap fall out through
        // the ordinary "no more cursor" path, which — before this flag —
        // still looked like a complete run to the watermark-advance check
        // that follows the loop, silently reopening the DESC-ordered older
        // tail as permanently skipped.
        var truncated = false
        do {
            repeat {
                let page = try await api.listItems(query)
                // `Task.isCancelled` alongside `stopped` (fix round 7): a
                // task `stop()` cancelled is checked on its OWN
                // cancellation flag, which stays true forever for that
                // task even if a subsequent `start()` resets the shared
                // `stopped` var before this resumes.
                guard !stopped, !Task.isCancelled else { return .stopped }
                try store.upsertItems(page.items)
                for i in page.items where newestSeen == nil || i.updatedAt > newestSeen! { newestSeen = i.updatedAt }
                pageCount += 1
                if let cursor = page.nextCursor, seenCursors.contains(cursor) {
                    Self.logger.error("refresh(\(String(describing: scope), privacy: .public)): nextCursor repeated (\(cursor, privacy: .public)) — stopping pagination")
                    truncated = true
                    query.cursor = nil
                } else if pageCount >= Self.maxPages {
                    if page.nextCursor != nil {
                        Self.logger.error("refresh(\(String(describing: scope), privacy: .public)): hit \(Self.maxPages, privacy: .public)-page cap — stopping pagination")
                        truncated = true
                    }
                    query.cursor = nil
                } else {
                    if let cursor = page.nextCursor { seenCursors.insert(cursor) }
                    query.cursor = page.nextCursor
                }
            } while query.cursor != nil
            if let newestSeen, !truncated {
                do {
                    try store.setItemsWatermark(newestSeen, scope: scope)
                } catch {
                    Self.logger.error("setItemsWatermark failed for \(String(describing: scope), privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            setSupported(true)
            // A successful refresh is also what proves the tracker routes
            // exist, which is what unblocks a `.paused` drain (fix round 3,
            // Bugbot finding on PR #185 ~156): `drainOnce` gates on
            // `isSupported`, but until now nothing re-kicked the drain
            // after `isSupported` flipped true outside of `.running` or a
            // fresh enqueue — a 404-probe-then-recovery (or an
            // auth-pause-then-refresh) could leave rows queued
            // indefinitely, waiting for a reconnect or another enqueue that
            // might not come. `drainOutbox()` is re-entrancy-safe (the
            // `draining` guard), so calling it here unconditionally is
            // cheap when there's nothing to do.
            if let pending = try? store.itemOutboxPending(), !pending.isEmpty {
                await drainOutbox()
            }
            return .succeeded
        } catch JournalAPIError.notFound {
            setSupported(false)
            return .unsupported
        } catch {
            Self.logger.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed(ItemsRefreshFailure(error))
        }
    }

    public func refreshItem(id: String) async {
        if let running = inFlightRefetches[id] {
            refetchAgain.insert(id)
            await running.value
            return
        }
        let run = Task { [self] in
            await refreshItemOnce(id: id)
            while refetchAgain.remove(id) != nil {
                await refreshItemOnce(id: id)
            }
            // Deregister HERE, with no suspension between the final
            // `refetchAgain` check and the removal (Bugbot/CodeRabbit,
            // PR #198): if the owner cleared it after `await run.value`
            // instead, a joiner arriving in that window would flag
            // `refetchAgain`, await an already-finished task, and return
            // with its flag never consumed.
            inFlightRefetches[id] = nil
        }
        inFlightRefetches[id] = run
        await run.value
    }

    private func refreshItemOnce(id: String) async {
        do {
            let r = try await api.item(id: id)
            guard !stopped else { return }
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
        // An enqueue racing sign-out must not insert after `wipeOutbox()`
        // has already run (fix wave, item I3) — `stop()` is called before
        // the wipe, so this flag being set means the outbox is either
        // already cleared or about to be, and a fresh row landing after
        // that would survive into the next session's fresh sign-in.
        guard !stopped else { return }
        let payload = (try? String(data: JSONEncoder().encode(CommentPayload(body: body, attachments: attachments)), encoding: .utf8)) ?? "{}"
        do {
            try store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: itemID, op: "comment", payloadJSON: payload,
                                                         createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        } catch {
            Self.logger.error("enqueueComment insert failed for \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await drainOutbox()
    }

    /// Inserts the outbox row and returns whether that insert succeeded
    /// (fix wave, item I3) — `false` when stopped or the write throws.
    /// The drain itself is kicked in the background, NOT awaited (fix
    /// wave, item I2): the composer's "Make task" flow used to hold
    /// `isSending` across this whole call, including the drain's network
    /// round-trip, for a write that's already durable once the outbox row
    /// lands. `drainOutbox()`'s own retry/backoff loop owns delivery from
    /// here.
    @discardableResult
    public func enqueueCreate(localID: String, _ new: NewItem) async -> Bool {
        // Same race as `enqueueComment` above — see that guard's comment.
        guard !stopped else { return false }
        let payload = (try? String(data: JSONEncoder().encode(CreatePayload(kind: new.kind.rawValue, title: new.title, body: new.body, convoID: new.convoID, attachments: new.attachments)), encoding: .utf8)) ?? "{}"
        do {
            try store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: nil, op: "create", payloadJSON: payload,
                                                         createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        } catch {
            Self.logger.error("enqueueCreate insert failed for \(localID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        Task { [weak self] in await self?.drainOutbox() }
        return true
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
            switch await drainOnce() {
            case .clean:
                break // falls through to the `while drainRequested` check below
            case .retry(let attempts):
                // Stopped early on a retryable failure: schedule the
                // backoff retry and stop, even if `drainRequested` got set
                // while we were mid-attempt (e.g. another caller kicked
                // `drainOutbox()` during the same failing network call) —
                // retrying instantly would just fail the same way again.
                scheduleRetry(afterAttempts: attempts)
                return
            case .paused:
                // Auth lost, or the routes aren't proven to exist yet
                // (fix round 2, IMPORTANT #3): stop entirely. No backoff
                // timer — a successful `refresh` (proving support) or a
                // fresh sign-in is what unblocks this, not a clock. Also
                // deliberately does NOT honor `drainRequested`: looping
                // again here would just hit the same pause immediately.
                return
            }
        } while drainRequested
    }

    private func scheduleRetry(afterAttempts attempts: Int) {
        let delay = min(60, retryBase * pow(2, Double(attempts)))
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.retryFired()
        }
    }

    /// Runs on the actor when the backoff timer fires. Clears `retryTask`
    /// to `nil` BEFORE calling `drainOutbox()` (fix round 2, CRITICAL #1):
    /// `drainOutbox()` unconditionally cancels whatever `retryTask`
    /// currently holds, on the theory that any fresh trigger supersedes a
    /// pending backoff. Without this indirection, the firing task WAS that
    /// `retryTask` — calling `drainOutbox()` directly from inside it made
    /// the drain cancel its own currently-running `Task`, so every network
    /// call inside made `URLSession` throw `CancellationError` immediately
    /// (mapped to a retryable `.transport` failure), which scheduled
    /// another retry that self-cancelled the same way — attempts inflated
    /// forever and no retry ever actually delivered.
    private func retryFired() async {
        retryTask = nil
        // `stop()` may have landed during the actor hop; a cancelled retry
        // must not drain (it would burn an attempt and reschedule itself).
        // `stopped` is the same check by another name (fix wave, item G) —
        // `stop()` now cancels this Task too, but checking the flag
        // directly here doesn't depend on that cancellation having already
        // been observed by the time this actor-isolated call runs.
        guard !Task.isCancelled, !stopped else { return }
        await drainOutbox()
    }

    /// How a failed outbox request should be handled. Distinct from a
    /// simple retryable/non-retryable bool (fix round 2, IMPORTANT #3):
    /// auth/support loss needs a third behavior — leave the row alone and
    /// stop, rather than either deleting it (poison) or bumping its
    /// attempt count and scheduling a timed retry (retryable).
    private enum FailureDisposition {
        /// Transient (offline, 5xx, 408/429): mark the attempt, stop the
        /// pass, and let the backoff timer retry it.
        case retryable
        /// This exact request can never succeed (409, other 4xx): drop the
        /// row and keep draining the rest of the queue.
        case poison
        /// The device's session/credentials were rejected: leave the row
        /// queued untouched (no delete, no attempt bump) and stop the pass
        /// without scheduling a backoff — `wipeOutbox()` on sign-out clears
        /// these rows, and a fresh sign-in's `.running` drains them if they
        /// survive.
        case pause
    }

    /// `JournalAPIError` cases classified per `FailureDisposition`. Any
    /// other `Error` (a decode failure, an unexpected throw) is treated as
    /// retryable — the safe default for something we don't recognize is to
    /// not silently drop or freeze a user's data.
    private func disposition(for error: Error) -> FailureDisposition {
        guard let apiError = error as? JournalAPIError else { return .retryable }
        switch apiError {
        case .unauthenticated, .badCredentials, .forbidden:
            // 401/403-credentials cases (`JournalAPI.swift` maps HTTP 401
            // → `.unauthenticated` and 403 → `.forbidden`/`.badCredentials`
            // before this ever sees a raw `.http` status) — a lost or
            // rejected session, not a permanently-bad request.
            return .pause
        case .conflict:
            return .poison
        case .notFound:
            // The journal never deletes items server-side (fix round 2,
            // IMPORTANT #3b) — a 404 on a write is far likelier "this
            // journal doesn't have the tracker routes yet" than "the item
            // was deleted out from under us". Retryable: `refresh` catching
            // its own `.notFound` is what actually flips `isSupported`
            // false and pauses the queue (see the `drainOnce` guard).
            return .retryable
        case .http(let status, _):
            if status == 408 || status == 429 { return .retryable }
            return (400...499).contains(status) ? .poison : .retryable
        case .lockedOut, .rateLimited, .transport:
            return .retryable
        }
    }

    private enum DrainOutcome {
        /// Every pending row was either applied or dropped as poison — the
        /// whole pass completed.
        case clean
        /// Stopped early on a retryable failure; carries the failed row's
        /// post-mark attempt count for the backoff calculation.
        case retry(attempts: Int)
        /// Stopped early because the routes aren't proven to exist yet
        /// (`!isSupported`) or a request was rejected on auth grounds.
        case paused
    }

    private func drainOnce() async -> DrainOutcome {
        // Rows wait until a `refresh` proves the tracker routes exist on
        // this journal (fix round 2, IMPORTANT #3a) — draining against an
        // unproven journal risks exactly the poison-row misclassification
        // #3b fixes for `.notFound` in the first place.
        guard isSupported else { return .paused }
        guard !stopped else { return .clean }
        guard let rows = try? store.itemOutboxPending() else { return .clean }
        for row in rows {
            guard !stopped else { return .clean }
            do {
                switch row.op {
                case "comment":
                    guard let itemID = row.itemID, let data = row.payloadJSON.data(using: .utf8),
                          let p = try? JSONDecoder().decode(CommentPayload.self, from: data) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let r = try await api.commentItem(id: itemID, body: p.body, attachments: p.attachments, idempotencyKey: row.localID)
                    guard !stopped else { return .clean }
                    // Keep the posted comment locally BEFORE deleting the
                    // outbox row and BEFORE the coalesced `refreshItem`
                    // below (fix wave, item A): `refreshItem` is a plain
                    // GET that can itself fail (offline blip, journal
                    // hiccup) — if it does, the row is already gone from
                    // the outbox, so without this the reply would be
                    // invisible until the detail sheet is reopened.
                    // `insertComments` is an upsert, not a replace, so it
                    // can't race-delete anything `refreshItem` also wrote.
                    try store.commitOutboxResult(item: r.item, comment: r.comment, deletingLocalID: row.localID)
                    await refreshItem(id: itemID)
                case "create":
                    guard let data = row.payloadJSON.data(using: .utf8), let p = try? JSONDecoder().decode(CreatePayload.self, from: data),
                          let kind = ItemKind(rawValue: p.kind) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let item = try await api.createItem(NewItem(kind: kind, title: p.title, body: p.body, attachments: p.attachments, convoID: p.convoID), idempotencyKey: row.localID)
                    guard !stopped else { return .clean }
                    try store.commitOutboxResult(item: item, deletingLocalID: row.localID)
                default:
                    try store.itemOutboxDelete(localID: row.localID)
                }
            } catch {
                // A throw can land after `stop()` flipped `stopped` mid-await
                // (fix wave, item I3): the per-row `guard !stopped` above
                // this `do` only covers the window BEFORE the network
                // call/store write starts, not a `stop()` that races in
                // while it's suspended. Without this recheck, a stale
                // failure here would still mark an attempt or delete a row
                // (a write racing whatever `stop()`'s caller does next,
                // typically a sign-out wipe) and, worse, `.retry` would make
                // the OUTER `drainOutbox()` schedule a fresh `retryTask`
                // after `stop()` already awaited the old one to nil —
                // resurrecting a retry the caller believed was fully torn
                // down. `.clean` schedules nothing and writes nothing.
                guard !stopped else { return .clean }
                switch disposition(for: error) {
                case .retryable:
                    do {
                        try store.itemOutboxMarkAttempt(localID: row.localID, error: error.localizedDescription)
                    } catch let markError {
                        Self.logger.error("itemOutboxMarkAttempt failed for \(row.localID, privacy: .public): \(markError.localizedDescription, privacy: .public)")
                    }
                    // Stop at the first retryable failure: the rest will
                    // fail the same way (offline) and order matters for
                    // comments on one item.
                    return .retry(attempts: row.attempts + 1)
                case .poison:
                    // A non-retryable rejection (409, other 4xx) will never
                    // succeed on retry — drop it and keep draining the rest
                    // of the queue instead of blocking behind it.
                    Self.logger.error("outbox row \(row.localID, privacy: .public) rejected non-retryably (\(error.localizedDescription, privacy: .public)) — dropping")
                    do {
                        try store.itemOutboxDelete(localID: row.localID)
                    } catch let delError {
                        Self.logger.error("itemOutboxDelete failed for poisoned row \(row.localID, privacy: .public): \(delError.localizedDescription, privacy: .public)")
                    }
                case .pause:
                    Self.logger.notice("outbox row \(row.localID, privacy: .public) paused (auth/session rejected): \(error.localizedDescription, privacy: .public) — left queued")
                    return .paused
                }
            }
        }
        return .clean
    }
}
