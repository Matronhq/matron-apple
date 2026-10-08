import Foundation
import os
import MatronModels
import MatronEvents

/// Why a refresh could not fetch, in a form that can leave the actor —
/// same reasoning as `ItemsRefreshFailure`: the outcome travels out through
/// a `Task` value, whose success type must be `Sendable`, and `any Error`
/// is not. The concrete error stays in the log line beside it.
public struct MissionsRefreshFailure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ error: any Error) { self.message = error.localizedDescription }
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What a `refresh()` pass actually did. `.unsupported` is a real answer
/// from an old journal (404 on `GET /missions`), not a transport fault —
/// the Missions tab hides itself on it.
public enum MissionsRefreshOutcome: Equatable, Sendable {
    case succeeded
    case unsupported
    case stopped
    case failed(MissionsRefreshFailure)
}

/// Keeps the local mission cache fresh (spec: Apps → Shared core). Three
/// triggers refetch: a `mission`/`milestone` marker (refetch THAT mission),
/// a reconnect (full list), and an explicit refresh from a view model.
/// Markers are invalidation signals only — nothing they carry is written to
/// the store, because a marker written across the privacy boundary has no
/// title at all.
///
/// There is no outbox: the one write the apps can make (a user close) is an
/// interactive, foreground action that reports its own failure.
public actor MissionsSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "missions-sync")

    private let api: any MissionsProviding
    private let store: JournalStore
    private let markers: @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private var markerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    /// List-refresh coalescing, mirroring `ItemsSync.refresh(scope:)`: a
    /// reconnect, a tab open and a pull-to-refresh landing together each
    /// ran their own full GET over the same rows. There is only one scope
    /// here, so one slot suffices.
    private var inFlightRefresh: Task<MissionsRefreshOutcome, Never>?
    /// Per-mission refetch coalescing, mirroring `ItemsSync.refreshItem`: a
    /// joiner AWAITS the run already in flight (callers take "refreshMission
    /// returned" to mean the store now holds the server's page), and the
    /// running pass repeats once more if another was requested meanwhile.
    private var inFlightRefetches: [String: Task<MissionsRefreshOutcome, Never>] = [:]
    private var refetchAgain: Set<String> = []
    /// Fix round 2, H1: ids a detail refresh (`refreshMissionOnce`) has
    /// written since the CURRENT full-list `GET` started. `refreshOnce`
    /// clears this immediately before issuing `api.listMissions` and
    /// passes it to `replaceMissions(_:keeping:)`, so a mission that
    /// didn't exist when the list request was made — but was created and
    /// detail-fetched (via a marker) while that request was still in
    /// flight — survives the authoritative sweep instead of being read
    /// as "the list doesn't have it, so it's gone."
    private var protectedSinceListStart: Set<String> = []
    /// Test-only observability seam — see the increment site in
    /// `refreshMission(id:)`.
    private(set) var refetchJoins = 0
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// Set by `stop()`, cleared by `start()`. Every write site re-checks it
    /// immediately after its await, so a call suspended in the network when
    /// sign-out lands cannot resume and write into a wiped store.
    private var stopped = false

    public init(api: any MissionsProviding, store: JournalStore,
                markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api; self.store = store; self.markers = markers; self.connectionStates = connectionStates
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
                await self.refreshMission(id: marker.missionID)
            }
        }
        let states = connectionStates()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                // No `setSupported(true)` here: publishing "supported"
                // before the probe would flash true→false for an old
                // journal that 404s. `refresh` publishes the real answer.
                if case .running = state { await self.refresh() }
            }
        }
    }

    /// Awaits every in-flight task before returning, so a caller that
    /// follows this with a store wipe cannot be raced by a suspended
    /// network call resuming into a write. Same contract as `ItemsSync.stop`.
    public func stop() async {
        stopped = true
        let mt = markerTask; let st = stateTask
        markerTask = nil; stateTask = nil
        mt?.cancel(); st?.cancel()
        let refresh = inFlightRefresh
        refresh?.cancel()
        let refetches = Array(inFlightRefetches.values)
        for t in refetches { t.cancel() }
        await mt?.value; await st?.value
        _ = await refresh?.value
        for t in refetches { await t.value }
    }

    /// Full `GET /missions` (both states — the list shows open and a
    /// collapsed Closed section). Joiners of a coalesced run get the SAME
    /// outcome, so two triggers racing one fetch cannot disagree.
    @discardableResult
    public func refresh() async -> MissionsRefreshOutcome {
        if let running = inFlightRefresh { return await running.value }
        var run: Task<MissionsRefreshOutcome, Never>!
        run = Task { [self] in
            let outcome = await refreshOnce()
            // Deregister with no suspension between the last line of the
            // run and the removal, and only if the slot still holds THIS
            // task — a `stop()` racing a `start()` + `refresh()` must not
            // let this task delete a newer registration on its way out.
            if inFlightRefresh == run { inFlightRefresh = nil }
            return outcome
        }
        inFlightRefresh = run
        return await run.value
    }

    private func refreshOnce() async -> MissionsRefreshOutcome {
        // Full list, unconditionally — unlike `ItemsSync`, the row counts
        // (`open_items`, `needs_you`, …) are server-side aggregates over
        // OTHER tables (item, milestone, mission_conversation), not columns
        // on `mission` itself. A `?since=` filtered on `missions.updated_at`
        // cannot see an item answered or closed, so the tab badge would go
        // permanently stale. The list is tens of rows, so a full `GET` on
        // every connect/tab-open/pull is cheap and always right (spec:
        // Apps → Shared core, "full GET /missions on connect and reconnect").
        let query = MissionsListQuery()
        // Fix round 2, H1: cleared right before the request so anything
        // a detail refresh writes from here on is provably "since this
        // list GET started," and therefore must survive the sweep below
        // even if this response predates it.
        protectedSinceListStart.removeAll()
        do {
            let decoded = try await api.listMissions(query)
            guard !stopped, !Task.isCancelled else { return .stopped }
            // The complete list, unconditionally (comment above) — so
            // this write is authoritative and a mission the server no
            // longer returns must not linger (CodeRabbit #209 MAJOR),
            // except a mission a concurrent detail refresh just wrote
            // that this (now stale) response predates (fix round 2, H1),
            // or one this device merely failed to DECODE this time
            // (`droppedIDs` — fix round 2, addendum): a local decode
            // failure is never grounds to treat a mission as gone.
            try store.replaceMissions(decoded.missions, keeping: protectedSinceListStart.union(decoded.droppedIDs))
            setSupported(true)
            return .succeeded
        } catch JournalAPIError.notFound {
            // The journal has no /missions routes. Not a transport fault:
            // the server answered, and the tab hides itself.
            setSupported(false)
            return .unsupported
        } catch {
            Self.logger.warning("missions refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed(MissionsRefreshFailure(error))
        }
    }

    /// `GET /missions/:id` — the mission row, its milestones, its open items
    /// and its conversations, all written in one pass. Called on a marker
    /// and whenever a mission page opens. Returns the outcome (MAJOR-4) so
    /// `MissionDetailViewModel.refresh()` can tell a transport failure from
    /// a quiet success and surface it — a swallowed failure here, combined
    /// with the page's optimistic "not on this device yet" placeholder,
    /// used to be a permanent, un-retryable dead end.
    @discardableResult
    public func refreshMission(id: String) async -> MissionsRefreshOutcome {
        if let running = inFlightRefetches[id] {
            refetchAgain.insert(id)
            // Test-only observability (internal, not private, so
            // `@testable` tests can await it): incremented the instant a
            // joiner registers against an in-flight run, so a test can
            // deterministically wait for that registration instead of
            // sleeping a fixed interval and hoping it happened in time
            // (CodeRabbit #209 fix round 2, M1).
            refetchJoins += 1
            return await running.value
        }
        let run = Task<MissionsRefreshOutcome, Never> { [self] in
            var outcome = await refreshMissionOnce(id: id)
            while refetchAgain.remove(id) != nil { outcome = await refreshMissionOnce(id: id) }
            // Deregister here, with no suspension between the final
            // `refetchAgain` check and the removal, so a joiner can never
            // await a task that has already finished AND deregistered.
            inFlightRefetches[id] = nil
            return outcome
        }
        inFlightRefetches[id] = run
        return await run.value
    }

    private func refreshMissionOnce(id: String) async -> MissionsRefreshOutcome {
        do {
            let detail = try await api.mission(id: id)
            guard !stopped else { return .stopped }
            try store.upsertMissions([detail.mission])
            try store.replaceMilestones(missionID: detail.mission.id, detail.milestones)
            try store.replaceMissionConversations(missionID: detail.mission.id, detail.conversations)
            // The detail's items are ordinary tracker rows carrying
            // `mission_id`; upserting them keeps the tracker cache and the
            // mission page in agreement without a second /items fetch.
            if !detail.items.isEmpty { try store.upsertItems(detail.items) }
            // Fix round 2, H1: protects this id from a concurrent,
            // now-stale list refresh's sweep — see `protectedSinceListStart`.
            protectedSinceListStart.insert(detail.mission.id)
            setSupported(true)
            return .succeeded
        } catch JournalAPIError.notFound {
            // Unknown, or invisible to this caller. Not a support signal —
            // `refresh()` owns `isSupported` — and not a failure to surface
            // either: the page has nothing to retry into.
            Self.logger.notice("mission \(id, privacy: .public) not found or not visible")
            return .succeeded
        } catch {
            Self.logger.warning("mission refetch \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed(MissionsRefreshFailure(error))
        }
    }

    /// The user's own close. Throws so the view model can surface the real
    /// message; the returned row is written straight to the store so the
    /// page flips to "closed" without waiting for a marker round-trip.
    @discardableResult
    public func closeMission(id: String, summary: String) async throws -> Mission {
        let mission = try await api.closeMission(id: id, summary: summary)
        guard !stopped else { return mission }
        try store.upsertMissions([mission])
        // Fix round 5 (Bugbot): same reasoning as `refreshMissionOnce`'s
        // insert — an in-flight list GET issued before this close landed
        // can still be holding the OLDER, still-open snapshot when it
        // returns; without protecting this id, that (now stale) response
        // would overwrite the just-closed row. No suspension between the
        // upsert above and this insert.
        protectedSinceListStart.insert(mission.id)
        return mission
    }
}
