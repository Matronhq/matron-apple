import Foundation
import MatronSearch
import os

/// What `JournalMaintenance` needs from the store. A protocol so the
/// scheduler can be tested against a recorder without a SQLite file;
/// `JournalStore` satisfies it as written.
public protocol MaintenanceSweeping: Sendable {
    func purgeExpiredToolOutputSnippets(now: Date) throws
    func applyRetention(now: Date) throws -> [Int64]
    func maintenanceLastRun() throws -> Date?
    func recordMaintenanceRun(at date: Date) throws
    /// The tool_output/diff seqs past the retention window that have not
    /// yet been retired from the search index, and the timestamp this call
    /// actually finished scanning up to. Gated on its own watermark,
    /// independent of `applyRetention`'s — see `JournalStore
    /// .searchRetentionWatermarkKey` for why the two must not share one.
    func pendingSearchRetirements(now: Date) throws -> (seqs: [Int64], cutoff: Date)
    /// Advances the search-retention watermark. Callers must only call this
    /// after `SearchService.removeAll(eventIDs:)` has succeeded for the
    /// `seqs` that came with `cutoff`.
    func recordSearchRetirement(upTo cutoff: Date) throws
}

extension JournalStore: MaintenanceSweeping {}

/// The store's background housekeeping: the tool-output TTL sweep, the
/// 30-day retention sweep, and the search-index removal that follows it.
///
/// This replaces the sweep that used to run inside `JournalStore.init`,
/// synchronously, on the main actor, before any caller could read the store
/// — 1.5 s of SQL and 75,791 row decodes on the Mac copy, on every single
/// launch, growing forever. Nothing here is on the launch path: the first
/// run is 10 s after the sync engine starts (or as soon as the first
/// catch-up batch lands, whichever comes first), and everything runs at
/// `.utility`, never on the main actor.
///
/// Failures are logged and retried at the next tick. `maintenance_last_run`
/// is stamped only after a complete pass, so a failed sweep does not buy
/// itself an hour of silence.
public actor JournalMaintenance {
    /// Default time between passes, and the staleness threshold the
    /// foreground check uses (spec §3.4). Named `defaultInterval` because the
    /// INSTANCE `interval` below is what every code path actually reads — a
    /// static named `interval` shadowed by a stored property of the same name
    /// is how an injectable value silently stops being injectable.
    public static let defaultInterval: TimeInterval = 60 * 60
    /// Long enough for the connect + first catch-up replay to have the disk
    /// to themselves; short enough that a session left open still gets swept.
    public static let firstRunDelay: Duration = .seconds(10)

    private let store: any MaintenanceSweeping
    /// `var`, not `let`: a locked background launch on iOS opens the index
    /// late (`AppDependencies.adoptSearch`), well after this actor is
    /// constructed — see `attachSearch`. Only ever goes nil → non-nil, same
    /// shape as `JournalSyncEngine.attachSearch`.
    private var search: (any SearchService)?
    private let now: @Sendable () -> Date
    private let interval: TimeInterval
    /// The pass currently running, if any. Doubles as the re-entrancy gate
    /// and as what `stop()` awaits.
    private var inFlight: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    /// Set at the top of `stop()`. `start()`, `runIfDue(now:)` and the
    /// engine's caught-up trigger all no-op once set — Bugbot Medium, PR
    /// #212: `stop()` cancelling and awaiting only the CURRENT schedule and
    /// in-flight pass left a window, after it returned, for a fresh
    /// `runIfDue` (from a still-live sync engine reaching `.running` again,
    /// or from `start()` being called a second time) to begin a brand new
    /// pass — sign-out's teardown spends several seconds on push
    /// deregistration between `maintenance.stop()` and `store.wipe()`,
    /// plenty of time for that to happen. There is no "unstop": a new
    /// sign-in builds a new `JournalMaintenance` on a new core.
    private var stopped = false
    private static let logger = os.Logger(subsystem: "chat.matron", category: "journal-maintenance")

    public init(store: any MaintenanceSweeping, search: (any SearchService)?,
                now: @escaping @Sendable () -> Date = { Date() },
                interval: TimeInterval = JournalMaintenance.defaultInterval) {
        self.store = store
        self.search = search
        self.now = now
        self.interval = interval
    }

    /// Attaches a just-opened search index to a maintenance actor that was
    /// constructed without one (iOS locked-background-launch path, mirroring
    /// `JournalSyncEngine.attachSearch`). Only ever nil → non-nil. The very
    /// next pass after this call resolves `search` fresh (`run(now:)` reads
    /// the stored property at call time, not at construction), so rows that
    /// piled up in `pendingSearchRetirements` while `search` was nil are
    /// retired on the next tick instead of the watermark having silently
    /// skipped past them (Bugbot High, PR #212).
    public func attachSearch(_ service: any SearchService) {
        guard search == nil else { return }
        search = service
    }

    /// Arms the first run and the hourly cadence. Idempotent, and a no-op
    /// once `stop()` has been called — there is nothing to restart.
    public func start() {
        guard !stopped, schedule == nil else { return }
        schedule = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.firstRunDelay)
            if Task.isCancelled { return }
            await self?.runIfDue()
            while !Task.isCancelled {
                // The INSTANCE interval, so a test (or a future debug build)
                // that injects a shorter one actually gets it.
                let seconds = await self?.interval ?? Self.defaultInterval
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self?.runIfDue()
            }
        }
    }

    /// Cancels the schedule AND waits for any pass already running, then
    /// fences every future trigger — idempotent, and safe to call more than
    /// once (a second call finds `schedule`/`inFlight` already nil and
    /// returns immediately).
    ///
    /// Cancelling alone is not enough, for two separate reasons:
    ///  - a `runIfDue` suspended in `await search.removeAll(…)` resumes
    ///    after sign-out has wiped the mirror and then stamps
    ///    `maintenance_last_run` on an empty `meta`, leaving a fresh stamp
    ///    beside absent watermarks (`backfillTask` in the same teardown
    ///    block is cancelled and awaited for exactly this reason);
    ///  - without the `stopped` flag, sign-out's several seconds of push
    ///    deregistration between this call returning and `store.wipe()`
    ///    running is a wide open window for a still-live sync engine to
    ///    reach `.running` again (or anything else holding this instance to
    ///    call `runIfDue`/`start()`) and kick off a BRAND NEW pass against a
    ///    store that's about to be wiped out from under it (Bugbot Medium,
    ///    PR #212).
    public func stop() async {
        stopped = true
        schedule?.cancel()
        schedule = nil
        await inFlight?.value
    }

    /// Sweeps when the stored `maintenance_last_run` is older than
    /// `interval` (or absent). Every trigger — the 10 s first run, the
    /// hourly tick, the sync engine's first catch-up, and app foreground —
    /// funnels through here, so "whichever comes first" needs no extra
    /// state: the first caller does the work and the rest are no-ops. A
    /// no-op too once `stop()` has been called.
    public func runIfDue(now overrideNow: Date? = nil) async {
        guard !stopped else { return }
        let current = overrideNow ?? now()
        guard inFlight == nil else { return }
        if let last = try? store.maintenanceLastRun(),
           current.timeIntervalSince(last) < interval { return }
        let pass = Task { await self.run(now: current) }
        inFlight = pass
        await pass.value
        inFlight = nil
    }

    /// RETENTION FIRST (R9). Spec §3.4 numbers the sweeps the other way, and
    /// that numbering is a trap: on a first pass the 24 h sweep's range is
    /// `(0, now − 24 h]`, which contains every row older than 30 days, and
    /// `EventTombstone.apply` gives those the RETENTION rewrite. Run that way
    /// round, `applyRetention` would then find them already tombstoned,
    /// return an empty seq list — but that no longer matters for search
    /// (see below), so the ordering's remaining purpose is purely disk
    /// hygiene: a row gets the strongest applicable rewrite in one pass
    /// rather than the weaker 24 h one now and the 30-day one an hour later.
    ///
    /// Search retirement (step 3) is INDEPENDENT of `applyRetention`'s
    /// return value — it has its own watermark
    /// (`pendingSearchRetirements`/`recordSearchRetirement`), because
    /// `applyRetention`'s seqs were being silently dropped whenever `search`
    /// was nil at pass time (a locked iOS background launch opens the index
    /// late; `JournalMaintenance` used to snapshot `search` only at
    /// construction) — Bugbot High, PR #212. With a separate watermark, a
    /// pass with no search attached simply leaves it untouched, and the
    /// SAME rows are found and retired once `attachSearch` runs and a later
    /// pass fires.
    private func run(now current: Date) async {
        do {
            let retentionVisited = try store.applyRetention(now: current)
            try store.purgeExpiredToolOutputSnippets(now: current)
            var searchRetired = 0
            if let search {
                let pending = try store.pendingSearchRetirements(now: current)
                if !pending.seqs.isEmpty {
                    // Search rows are keyed by `String(seq)` by every feeder
                    // (JournalSyncEngine.indexForSearch), so the seqs this
                    // scan returns ARE the index's event ids. `removeAll`
                    // does its own per-chunk transactions.
                    try await search.removeAll(eventIDs: pending.seqs.map(String.init))
                }
                // Recorded even when `seqs` is empty: an empty pass still
                // scanned up to `pending.cutoff`, and skipping this write
                // would just re-scan the same empty range every tick.
                // Recorded only AFTER `removeAll` succeeds (or wasn't
                // needed) — a thrown `removeAll` skips straight to the
                // `catch` below, leaving the watermark exactly where it was
                // so the next pass retries the same seqs.
                try store.recordSearchRetirement(upTo: pending.cutoff)
                searchRetired = pending.seqs.count
            } else {
                Self.logger.debug("maintenance pass: no search attached, search retirement skipped")
            }
            try store.recordMaintenanceRun(at: current)
            Self.logger.info("""
                maintenance pass done; retention visited \(retentionVisited.count, privacy: .public), \
                search retired \(searchRetired, privacy: .public)
                """)
        } catch {
            // No stamp on failure: the next tick retries immediately rather
            // than waiting out the hour. Neither watermark this pass would
            // have advanced was written before the throw, so retention and
            // search retirement both retry from exactly where they left off.
            Self.logger.error("maintenance pass failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
