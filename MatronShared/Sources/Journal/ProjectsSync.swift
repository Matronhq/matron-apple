import Foundation
import os
import MatronModels
import MatronEvents

public enum ProjectsRefreshOutcome: Equatable, Sendable {
    case succeeded
    /// `GET /projects` 404: a journal that predates projects.
    case unsupported
    case stopped
    case failed(MissionsRefreshFailure)
}

public enum ProjectRefreshOutcome: Equatable, Sendable {
    /// The id the journal answered with — a merged project's TARGET.
    case loaded(projectID: String)
    case notFound
    case stopped
    case failed(MissionsRefreshFailure)
}

/// Keeps the local project cache and conversation links fresh (spec
/// 2026-09-30 §4.2, §6). Cloned from `MissionsSync`: markers are
/// invalidation signals only, nothing they carry is written.
public actor ProjectsSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "projects-sync")

    private let api: any ProjectsProviding
    private let store: JournalStore
    private let markers: @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private var markerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var inFlightRefresh: Task<ProjectsRefreshOutcome, Never>?
    /// Set when a refresh is requested while one runs: the running pass
    /// repeats ONCE, however many requests arrived (the marker flood rule).
    private var refreshAgain = false
    /// Ids a detail fetch or a create wrote since the current list GET
    /// started — kept by `replaceProjects` (same race as `MissionsSync` H1).
    private var protectedSinceListStart: Set<String> = []
    /// Conversation id → number of on-screen chat views showing it. Fix
    /// round 1: survives `stop()`/`start()` (a reconnect) on purpose — a
    /// chat that never left the screen must keep refetching its links once
    /// the marker stream resumes, with no `beginWatching` call to redo it.
    private var watched: [String: Int] = [:]
    private var inFlightLinks: [String: Task<Void, Never>] = [:]
    private var linksAgain: Set<String> = []
    /// Fix round 1: per-project detail coalescing, mirroring
    /// `MissionsSync.inFlightRefetches` — an out-of-order or merely slower
    /// second response for the SAME id must not race the first.
    private var inFlightDetails: [String: Task<ProjectRefreshOutcome, Never>] = [:]
    private var detailAgain: Set<String> = []
    /// Test-only observability seam — see the increment site in
    /// `refreshProject(id:)`. Not private, so `@testable` tests can await it.
    private(set) var detailJoins = 0
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// Set by `stop()`, cleared by `start()`. Every write site re-checks it
    /// immediately after its await, so a call suspended in the network when
    /// sign-out lands cannot resume and write into a wiped store. Not
    /// private, so a test can poll it (`waitUntil { await sync.stopped }`)
    /// instead of sleeping a fixed interval to synchronize with `stop()`'s
    /// synchronous prefix.
    private(set) var stopped = false

    public init(api: any ProjectsProviding, store: JournalStore,
                markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: MissionMarker)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api; self.store = store; self.markers = markers; self.connectionStates = connectionStates
    }

    // MARK: Support

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

    // MARK: Lifetime

    public func start() {
        stopped = false
        guard markerTask == nil else { return }
        let markers = markers()
        markerTask = Task { [weak self] in
            for await (convoID, _) in markers {
                guard let self else { return }
                await self.markerLanded(convoID: convoID)
            }
        }
        let states = connectionStates()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                if case .running = state { await self.refresh() }
            }
        }
    }

    /// Fix round 1 (Important): cancels every in-flight run BEFORE awaiting
    /// it, mirroring `MissionsSync.stop` — the order matters, not just the
    /// presence of the calls. Without cancelling first, a `start()` fired
    /// while `stop()` is still suspended here (a real window: `stop()`
    /// yields at the first `await` below, and the actor is free again
    /// until it resumes) resets the shared `stopped` flag back to `false`
    /// before a gated fetch resolves — at that point `Task.isCancelled` on
    /// the specific, already-cancelled run is the ONLY thing left standing
    /// between a stale response and the store, because it is permanent
    /// once set and cannot be undone by that later `start()` (same
    /// reasoning as `ItemsSync`'s `testStopCancelsInFlightRefreshSo…` fix).
    /// `watched` is deliberately NOT cleared here — see its declaration.
    public func stop() async {
        stopped = true
        let mt = markerTask, st = stateTask
        markerTask = nil; stateTask = nil
        mt?.cancel(); st?.cancel()
        let refresh = inFlightRefresh
        refresh?.cancel()
        let links = Array(inFlightLinks.values)
        for t in links { t.cancel() }
        let details = Array(inFlightDetails.values)
        for t in details { t.cancel() }
        await mt?.value; await st?.value
        _ = await refresh?.value
        for t in links { await t.value }
        for t in details { await t.value }
    }

    /// Never awaits the fetches it starts: the marker loop must keep
    /// draining so a flood collapses into one repeat (`refreshAgain`).
    private func markerLanded(convoID: String) {
        if watched[convoID, default: 0] > 0 {
            Task { await self.refreshConversationMissions(convoID: convoID) }
        }
        if inFlightRefresh != nil { refreshAgain = true } else { Task { await self.refresh() } }
    }

    // MARK: List

    @discardableResult
    public func refresh() async -> ProjectsRefreshOutcome {
        guard !stopped else { return .stopped }
        if let running = inFlightRefresh {
            refreshAgain = true
            return await running.value
        }
        var run: Task<ProjectsRefreshOutcome, Never>!
        run = Task { [self] in
            var outcome = await refreshOnce()
            while refreshAgain, !stopped {
                refreshAgain = false
                outcome = await refreshOnce()
            }
            if inFlightRefresh == run { inFlightRefresh = nil }
            return outcome
        }
        inFlightRefresh = run
        return await run.value
    }

    private func refreshOnce() async -> ProjectsRefreshOutcome {
        protectedSinceListStart.removeAll()
        do {
            let decoded = try await api.listProjects()
            guard !stopped, !Task.isCancelled else { return .stopped }
            try store.replaceProjects(decoded.projects,
                                      keeping: protectedSinceListStart.union(decoded.droppedIDs))
            setSupported(true)
            return .succeeded
        } catch JournalAPIError.notFound {
            setSupported(false)
            return .unsupported
        } catch {
            Self.logger.warning("projects refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed(MissionsRefreshFailure(error))
        }
    }

    // MARK: One project

    /// R1 (preflight 2026-09-30-projects-apple): `ProjectDetail` carries no
    /// `needsYou` — the journal's project-detail item rows are slim (no
    /// `created_at`), so decoding them would let an authoritative upsert
    /// overwrite a fully-synced cached item with one missing fields. The
    /// project page reads needs-you from the item cache `ItemsSync` fills.
    ///
    /// Fix round 1: coalesced per id, mirroring `MissionsSync.refreshMission`
    /// — a joiner awaits the SAME in-flight run rather than issuing its own
    /// concurrent GET, and the running pass repeats once more for it. This
    /// closes an out-of-order window: two independently-ordered detail
    /// fetches for the same id could otherwise land in whichever order the
    /// network happened to deliver them, letting an older response win.
    @discardableResult
    public func refreshProject(id: String) async -> ProjectRefreshOutcome {
        guard !stopped else { return .stopped }
        if let running = inFlightDetails[id] {
            detailAgain.insert(id)
            detailJoins += 1
            return await running.value
        }
        let run = Task<ProjectRefreshOutcome, Never> { [self] in
            var outcome = await refreshProjectOnce(id: id)
            while detailAgain.remove(id) != nil { outcome = await refreshProjectOnce(id: id) }
            inFlightDetails[id] = nil
            return outcome
        }
        inFlightDetails[id] = run
        return await run.value
    }

    private func refreshProjectOnce(id: String) async -> ProjectRefreshOutcome {
        do {
            let detail = try await api.project(id: id)
            guard !stopped, !Task.isCancelled else { return .stopped }
            try store.upsertProjects([detail.project])
            try store.setProjectSessionsByBox(id: detail.project.id, detail.sessionsByBox)
            try store.upsertMissions(detail.missions)
            try store.upsertMilestones(detail.recentMilestones)
            // Same race as `refreshOnce`'s `protectedSinceListStart`: an
            // in-flight list GET issued before this landed must not let its
            // (now stale) response revert or delete what was just written.
            protectedSinceListStart.insert(detail.project.id)
            return .loaded(projectID: detail.project.id)
        } catch JournalAPIError.notFound {
            return .notFound
        } catch {
            Self.logger.warning("project \(id, privacy: .public) refresh failed: \(error.localizedDescription, privacy: .public)")
            return .failed(MissionsRefreshFailure(error))
        }
    }

    // MARK: Conversation links (the header chip)

    /// A chat view came on screen. Counted, so two windows on one
    /// conversation keep it watched until both leave. Returns at once; the
    /// first fetch runs in the background.
    public func beginWatching(convoID: String) {
        guard !stopped else { return }
        watched[convoID, default: 0] += 1
        Task { await self.refreshConversationMissions(convoID: convoID) }
    }

    public func endWatching(convoID: String) {
        guard let n = watched[convoID] else { return }
        watched[convoID] = n <= 1 ? nil : n - 1
    }

    public func refreshConversationMissions(convoID: String) async {
        guard !stopped else { return }
        if let running = inFlightLinks[convoID] {
            linksAgain.insert(convoID)
            await running.value
            return
        }
        let run = Task { [self] in
            await refreshLinksOnce(convoID)
            while linksAgain.remove(convoID) != nil { await refreshLinksOnce(convoID) }
            inFlightLinks[convoID] = nil
        }
        inFlightLinks[convoID] = run
        await run.value
    }

    private func refreshLinksOnce(_ convoID: String) async {
        guard !stopped else { return }
        do {
            let links = try await api.conversationMissions(convoID: convoID)
            guard !stopped, !Task.isCancelled else { return }
            try store.replaceConversationMissionLinks(convoID: convoID, links)
        } catch JournalAPIError.notFound {
            // An old journal, or a conversation it doesn't know: the local
            // derivation in `missionsStream(convoID:)` stands.
        } catch {
            Self.logger.warning("links \(convoID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Writes (interactive; each throws its real message)

    public func createProject(title: String, body: String?) async throws -> Project {
        let project = try await api.createProject(title: title, body: body, idempotencyKey: UUID().uuidString)
        guard !stopped else { return project }
        try store.upsertProjects([project])
        protectedSinceListStart.insert(project.id)
        return project
    }

    public func mergeProject(id: String, into: String) async throws {
        try await api.mergeProject(id: id, into: into)
        guard !stopped else { return }
        _ = await refresh()
        _ = await refreshProject(id: into)
    }

    @discardableResult
    public func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        let mission = try await api.setMissionProject(missionID: missionID, project: project)
        guard !stopped else { return mission }
        try store.upsertMissions([mission])
        Task { await self.refresh() }
        return mission
    }
}
