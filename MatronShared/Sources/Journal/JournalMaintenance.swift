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
    private let search: (any SearchService)?
    private let now: @Sendable () -> Date
    private let interval: TimeInterval
    /// The pass currently running, if any. Doubles as the re-entrancy gate
    /// and as what `stop()` awaits.
    private var inFlight: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    private static let logger = os.Logger(subsystem: "chat.matron", category: "journal-maintenance")

    public init(store: any MaintenanceSweeping, search: (any SearchService)?,
                now: @escaping @Sendable () -> Date = { Date() },
                interval: TimeInterval = JournalMaintenance.defaultInterval) {
        self.store = store
        self.search = search
        self.now = now
        self.interval = interval
    }

    /// Arms the first run and the hourly cadence. Idempotent.
    public func start() {
        guard schedule == nil else { return }
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

    /// Cancels the schedule AND waits for any pass already running.
    ///
    /// Cancelling alone is not enough: a `runIfDue` suspended in
    /// `await search.removeAll(…)` resumes after sign-out has wiped the
    /// mirror and then stamps `maintenance_last_run` on an empty `meta`,
    /// leaving a fresh stamp beside absent watermarks. `backfillTask` in the
    /// same teardown block is cancelled and awaited for exactly this reason.
    public func stop() async {
        schedule?.cancel()
        schedule = nil
        await inFlight?.value
    }

    /// Sweeps when the stored `maintenance_last_run` is older than
    /// `interval` (or absent). Every trigger — the 10 s first run, the
    /// hourly tick, the sync engine's first catch-up, and app foreground —
    /// funnels through here, so "whichever comes first" needs no extra
    /// state: the first caller does the work and the rest are no-ops.
    public func runIfDue(now overrideNow: Date? = nil) async {
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
    /// return an empty seq list, and the search index would keep every
    /// >30-day tool-output body forever — spec goal D silently unmet, and
    /// nothing in the logs to show it.
    private func run(now current: Date) async {
        do {
            let retired = try store.applyRetention(now: current)
            try store.purgeExpiredToolOutputSnippets(now: current)
            if !retired.isEmpty, let search {
                // Search rows are keyed by `String(seq)` by every feeder
                // (JournalSyncEngine.indexForSearch), so the seqs the
                // retention sweep returns ARE the index's event ids.
                // `removeAll` does its own per-chunk transactions.
                try await search.removeAll(eventIDs: retired.map(String.init))
            }
            try store.recordMaintenanceRun(at: current)
            Self.logger.info("maintenance pass done; retired \(retired.count, privacy: .public) bodies")
        } catch {
            // No stamp on failure: the next tick retries immediately rather
            // than waiting out the hour.
            Self.logger.error("maintenance pass failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
