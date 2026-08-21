import Foundation
import MatronJournal
import MatronModels

/// The RPC slice New Chat needs, extracted so the view model tests against
/// a fake. The app adapter wraps `JournalAPI.devices()` and
/// `JournalSyncEngine.agentRequest(...)` (engine default timeout applies).
public protocol AgentRPCProviding: Sendable {
    func devices() async throws -> [DeviceDTO]
    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply
}

/// Production adapter: the session's `JournalAPI` (roster) + sync engine
/// (RPC send/correlate, engine-default timeout).
public struct JournalAgentRPCService: AgentRPCProviding {
    private let api: JournalAPI
    private let engine: JournalSyncEngine

    public init(api: JournalAPI, engine: JournalSyncEngine) {
        self.api = api
        self.engine = engine
    }

    public func devices() async throws -> [DeviceDTO] {
        try await api.devices()
    }

    public func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        try await engine.agentRequest(agentDeviceID: agentDeviceID, method: method, paramsData: paramsData)
    }
}

/// One entry of a bridge's `recent_folders` answer. `lastUsed` (epoch ms)
/// is nil for "available but never used here" (the bridge's default
/// workdir on a fresh box) — sorts last, reads "never used".
public struct RecentFolder: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let lastUsed: Int64?

    public init(path: String, lastUsed: Int64?) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

extension RecentFolder {
    /// Row caption: relative last-used, or the never-used convention
    /// (`last_used: null` = the bridge's default workdir on a fresh box).
    public func lastUsedText(now: Date = Date()) -> String {
        guard let lastUsed else { return "Never used" }
        let date = Date(timeIntervalSince1970: TimeInterval(lastUsed) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Drives the New Chat flow (spec: 2026-07-15-new-chat-flow-design.md):
/// connected-agent picker → recent-folders picker → `start` RPC → the
/// caller navigates to `convo_id`.
///
/// Contract rules baked in here:
/// - `start` is non-idempotent and the relay has no dedup, so the trigger
///   is single-flight (`isStarting`).
/// - A failed `recent_folders` degrades the picker only — the free-text
///   path row must keep working.
/// - An offline box is a *sleeping* box (the infra host idle-stops VMs, and
///   the journal boots one whenever an agent_request targets it — wake.js),
///   so `agent_unreachable` from a box picked while offline means "booting,
///   ask again", never "dead end". That is the wake loop below.
@Observable @MainActor
public final class NewChatViewModel {
    public enum Phase: Equatable {
        case loadingAgents
        /// Roster shown for picking: connected agents first, then by name.
        case agents([DeviceDTO])
        case folders(agent: DeviceDTO)
        case done(convoID: String)
    }

    public private(set) var phase: Phase = .loadingAgents
    public private(set) var folders: [RecentFolder] = []
    /// Set when `recent_folders` failed — shown inline; picking by text
    /// still works.
    public private(set) var foldersError: String?
    public private(set) var errorMessage: String?
    /// True while a `start` round-trip is in flight; all start affordances
    /// disable on it.
    public private(set) var isStarting = false
    /// True while a wake loop is re-asking a sleeping box (folder fetch or
    /// a retried start): the folder step shows "Waking the box…" on it.
    public private(set) var isWakingBox = false
    /// When the running wake loop began, for the banner's elapsed time
    /// (`Text(_, style: .relative)`); nil whenever `isWakingBox` is false.
    public private(set) var wakeStartedAt: Date?
    /// True when the wake loop exhausted its attempts — the folder step
    /// offers Try Again (`retryWake()`) on it.
    public var wakeGaveUp: Bool { errorMessage == Self.wakeGaveUpMessage }
    public var customPath = ""
    public var browserEnabled = false
    /// Per-box capacity blocks, filled by the roster fan-out as replies
    /// land. Display-only: a missing entry just means a quieter row, never
    /// an unpickable one.
    public private(set) var capacities: [Int64: BoxCapacity] = [:]
    /// Boxes whose fan-out reply hasn't landed yet ("Checking…" rows).
    public private(set) var capacityPending: Set<Int64> = []
    /// The in-flight fan-out task; tests await it for determinism.
    public private(set) var capacityFanOutForTesting: Task<Void, Never>?
    /// Capture times for the entries in `capacities` that came out of the
    /// cache rather than off the wire this visit. Only offline boxes are ever
    /// seeded, so a key here means exactly "this row is showing last-known
    /// numbers" — see `capacityFreshness(for:)`.
    private var capacityCapturedAt: [Int64: Date] = [:]

    /// How stale a cached capacity may be before it stops being worth
    /// showing: past this, every limit window it describes has rolled over
    /// several times, so the percentages say nothing about the box today.
    static let maxCachedCapacityAge: TimeInterval = 7 * 86_400

    /// Wake-loop cadence and ceiling (~2 minutes): incus boot plus bridge
    /// reconnect lands well inside it. Past the ceiling the user gets the
    /// try-again copy — the journal debounces wake commands, so retrying
    /// costs nothing.
    public static let wakeRetryDelay: Duration = .seconds(3)
    public static let wakeAttemptLimit = 40
    static let wakeGaveUpMessage = "The box didn't wake — try again."

    private let api: any AgentRPCProviding
    private let capacityCache: any BoxCapacityCaching
    /// Injected clock, so tests can pin capture times.
    private let now: @Sendable () -> Date
    /// Folder lists learned by the fan-out, keyed by device — lets
    /// `select(agent:)` render the folder step from cache instead of paying
    /// for a second round-trip to the same box.
    private var folderCache: [Int64: [RecentFolder]] = [:]
    /// Bumped by every fan-out. Cancelling the previous task doesn't stop an
    /// RPC that's already in flight from answering, so each leg carries the
    /// generation it was started for and drops its reply if it's been
    /// superseded — otherwise a late leg would clear the new generation's
    /// pending row and overwrite its capacity and folder cache.
    private var capacityGeneration = 0
    /// Injected wake-loop sleep, so tests run the loops at test speed.
    private let wakeSleep: @Sendable (Duration) async -> Void

    public init(api: any AgentRPCProviding,
                // Not defaulted: the cache is namespaced per account, and a
                // convenient default here would be a silent app-global one.
                capacityCache: any BoxCapacityCaching,
                now: @escaping @Sendable () -> Date = Date.init,
                wakeSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.api = api
        self.capacityCache = capacityCache
        self.now = now
        self.wakeSleep = wakeSleep
    }

    /// How much a row's capacity numbers can be trusted: live for a box this
    /// visit asked, cached-with-an-age for an offline box seeded from the
    /// store. A box with no entry at all reads `.live` — it has nothing to
    /// disclaim, and its row shows nothing either way.
    public func capacityFreshness(for agentID: Int64) -> AgentCapacityFreshness {
        capacityCapturedAt[agentID].map { .offline(capturedAt: $0) } ?? .live
    }

    public func load() async {
        do {
            let agents = try await api.devices().filter { $0.kind == "agent" }
            let connected = agents.filter(\.connected)
            if connected.count == 1 {
                // Auto-skip: the folder step fetches this box's reply itself,
                // and no picker row is ever shown — nothing to fan out for.
                await select(agent: connected[0])
            } else {
                phase = .agents(Self.sorted(agents))
                startCapacityFanOut(connected: connected.map(\.id),
                                    offline: agents.filter { !$0.connected }.map(\.id))
            }
        } catch {
            phase = .agents([])
            errorMessage = "Couldn't load agents — try again."
        }
    }

    public func select(agent: DeviceDTO) async {
        // An impatient re-tap on the row already being woken must not stack
        // a second loop — the RPC traffic would double for nothing.
        if isWakingBox, Self.sameFolderAgent(phase, agent) { return }
        phase = .folders(agent: agent)
        folders = []
        foldersError = nil
        errorMessage = nil
        // The roster fan-out already asked this box for its folders — render
        // them instantly rather than paying for the same round-trip twice.
        if let cached = folderCache[agent.id] {
            folders = cached
            return
        }
        guard agent.connected else {
            await wakeAndFetchFolders(agent: agent)
            return
        }
        do {
            let reply = try await api.agentRequest(
                agentDeviceID: agent.id, method: "recent_folders", paramsData: Data("{}".utf8))
            recordCapacity(from: reply, agentID: agent.id)
            guard Self.sameFolderAgent(phase, agent) else { return } // switched away meanwhile
            switch reply {
            case .ok(let resultData):
                folders = Self.parseFolders(resultData)
            case .failure:
                foldersError = "Couldn't fetch recent folders — you can still type a path."
            }
        } catch {
            guard Self.sameFolderAgent(phase, agent) else { return }
            foldersError = "Couldn't fetch recent folders — you can still type a path."
        }
    }

    /// Re-arms the wake loop after it gave up ("try again"). Only meaningful
    /// on the folder step of a box that never answered.
    public func retryWake() async {
        guard case .folders(let agent) = phase, !isWakingBox, !isStarting else { return }
        errorMessage = nil
        await wakeAndFetchFolders(agent: agent)
    }

    /// The wake loop (journal `wake.js`): the server boots an idle-stopped
    /// box whenever an agent_request targets it, then refuses with
    /// `agent_unreachable` — so the first refused ask IS the wake trigger,
    /// and re-asking until the bridge connects is the whole protocol. Only
    /// `agent_unreachable` keeps the loop alive; any other failure means
    /// the box is up and merely can't list folders, which degrades exactly
    /// like the connected path. A timeout also keeps waking — mid-boot the
    /// socket can be up while the bridge is still starting. Leaving this
    /// box's folder step ends the loop silently at its next check.
    private func wakeAndFetchFolders(agent: DeviceDTO) async {
        isWakingBox = true
        wakeStartedAt = now()
        defer {
            isWakingBox = false
            wakeStartedAt = nil
        }
        for attempt in 1...Self.wakeAttemptLimit {
            do {
                let reply = try await api.agentRequest(
                    agentDeviceID: agent.id, method: "recent_folders", paramsData: Data("{}".utf8))
                recordCapacity(from: reply, agentID: agent.id)
                guard Self.sameFolderAgent(phase, agent) else { return }
                switch reply {
                case .ok(let resultData):
                    folders = Self.parseFolders(resultData)
                    return
                case .failure(let code, _) where code == "agent_unreachable":
                    break // still booting — go around
                case .failure:
                    foldersError = "Couldn't fetch recent folders — you can still type a path."
                    return
                }
            } catch RPCRequestError.timeout {
                guard Self.sameFolderAgent(phase, agent) else { return }
            } catch {
                guard Self.sameFolderAgent(phase, agent) else { return }
                foldersError = "Couldn't fetch recent folders — you can still type a path."
                return
            }
            guard attempt < Self.wakeAttemptLimit else { break }
            await wakeSleep(Self.wakeRetryDelay)
            guard Self.sameFolderAgent(phase, agent) else { return }
        }
        errorMessage = Self.wakeGaveUpMessage
    }

    /// Capacity is recorded off every ok `recent_folders` answer, whether
    /// or not the user has moved on since: a fleet with one connected box
    /// auto-skips the roster and never fans out, so this can be the only
    /// reply that box's capacity is ever learned from before it sleeps.
    private func recordCapacity(from reply: RPCReply, agentID: Int64) {
        if case .ok(let resultData) = reply,
           let object = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any] {
            capacityCache.save(BoxCapacity.parse(replyObject: object), for: agentID, at: now())
        }
    }

    /// Fires `start {workdir?, browser?}` at the picked agent. `workdir`
    /// nil/blank means the bridge's default workdir — the key is omitted.
    public func start(workdir: String?) async {
        guard case .folders(let agent) = phase, !isStarting else { return }
        isStarting = true
        defer {
            isStarting = false
            isWakingBox = false
            wakeStartedAt = nil
        }
        errorMessage = nil
        var params: [String: Any] = [:]
        let trimmed = workdir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { params["workdir"] = trimmed }
        if browserEnabled { params["browser"] = true }
        // A [String: Any] of strings/bools always serializes.
        let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        do {
            var reply = try await api.agentRequest(
                agentDeviceID: agent.id, method: "start", paramsData: paramsData)
            // `agent_unreachable` is refused server-side before anything
            // reaches the bridge — the one start failure that cannot have
            // opened a session, so the one that is safe to retry. The
            // refused frame has already fired the box's wake, and going
            // around again is what lets a Start tapped while the box is
            // still booting land the moment the bridge connects. A timeout
            // stays fatal: the frame may have been delivered, and start is
            // non-idempotent.
            var attempts = 1
            while attempts < Self.wakeAttemptLimit, Self.isUnreachable(reply) {
                isWakingBox = true
                if wakeStartedAt == nil { wakeStartedAt = now() }
                await wakeSleep(Self.wakeRetryDelay)
                guard Self.sameFolderAgent(phase, agent) else { return }
                reply = try await api.agentRequest(
                    agentDeviceID: agent.id, method: "start", paramsData: paramsData)
                attempts += 1
            }
            switch reply {
            case .ok(let resultData):
                guard let obj = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any],
                      let convoID = obj["convo_id"] as? String, !convoID.isEmpty else {
                    errorMessage = "Couldn't start — the agent answered without a conversation id."
                    return
                }
                phase = .done(convoID: convoID)
            case .failure(let code, let detail):
                errorMessage = Self.startErrorCopy(code: code, detail: detail)
            }
        } catch RPCRequestError.timeout {
            errorMessage = "The agent didn't answer — is the box awake?"
        } catch {
            errorMessage = "Couldn't start — check your connection and try again."
        }
    }

    /// Back from the folder step to the roster (only reachable when the
    /// roster was shown — the auto-skip case has nowhere to go back to).
    public func backToAgents() async {
        await load()
    }

    // MARK: Capacity fan-out

    /// Asks every connected box for its `recent_folders` in parallel (2–5
    /// boxes in practice) so the roster rows can show load, quota and
    /// account while the user is still choosing, and seeds the offline rows
    /// from the capacity cache. The roster is already on screen — this only
    /// fills rows in, so failures stay silent.
    private func startCapacityFanOut(connected agentIDs: [Int64], offline offlineIDs: [Int64]) {
        capacityFanOutForTesting?.cancel()
        capacityGeneration &+= 1
        let generation = capacityGeneration
        let refreshing = Set(agentIDs)
        capacityPending = refreshing
        // A reload re-asks every box, so last visit's folder lists are stale
        // from this moment: drop them rather than let `select(agent:)` serve
        // them before the new replies land — it falls back to a live
        // `recent_folders` when the cache is empty.
        folderCache.removeAll()
        // Capacity, unlike folders, is deliberately stale-while-revalidate:
        // the rows keep last-known numbers until the refresh answers, so
        // coming back from the folder step doesn't collapse every three-line
        // row to "Checking…" and grow it back a moment later. The honesty
        // that buys is paid for at the other end — a leg that fails clears
        // its entry (see `fetchCapacity`).
        //
        // Two entries never survive: a box this fan-out won't ask at all
        // (nothing would ever revalidate it — it is re-seeded from the cache
        // below instead, captioned with its age), and a cache seed for a box
        // that has since come online. The latter has never been confirmed
        // against the running box, so keeping it would launder disk data into
        // an uncaptioned, live-looking row.
        capacities = capacities.filter { refreshing.contains($0.key) && capacityCapturedAt[$0.key] == nil }
        capacityCapturedAt = [:]
        seedOfflineCapacities(connected: refreshing, offline: offlineIDs)
        capacityFanOutForTesting = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for id in agentIDs {
                    group.addTask { await self?.fetchCapacity(agentID: id, generation: generation) }
                }
            }
        }
    }

    /// Fills the rows of boxes the host has put to sleep with what they last
    /// reported. Nothing here is ever asked for over the wire — that is the
    /// whole point: the user picks which box to wake by its remaining quota.
    private func seedOfflineCapacities(connected: Set<Int64>, offline offlineIDs: [Int64]) {
        // The roster is the authority on which boxes exist; an unpaired box
        // would otherwise sit in the cache forever with nothing to refresh it.
        capacityCache.prune(keeping: connected.union(offlineIDs))
        let cached = capacityCache.loadAll()
        let moment = now()
        for id in offlineIDs {
            guard let entry = cached[id],
                  moment.timeIntervalSince(entry.capturedAt) <= Self.maxCachedCapacityAge else { continue }
            capacities[id] = entry.capacity
            capacityCapturedAt[id] = entry.capturedAt
        }
    }

    /// One box's fan-out leg. A failure, a timeout or an unparseable reply
    /// all leave the row at name + "Connected" — capacity is a convenience,
    /// never a gate — which includes dropping anything this box told us on
    /// an earlier visit: a box that just failed to answer is exactly the one
    /// whose old numbers shouldn't be presented as live. The *persisted*
    /// entry is deliberately left alone, though: it costs nothing while the
    /// box is connected, and it is what the row will show once the host puts
    /// that box to sleep, where it reads as last-known rather than as live.
    private func fetchCapacity(agentID: Int64, generation: Int) async {
        let reply = try? await api.agentRequest(
            agentDeviceID: agentID, method: "recent_folders", paramsData: Data("{}".utf8))
        // Superseded by a newer fan-out while this leg was in flight: this
        // answer describes a roster nobody is looking at any more.
        guard generation == capacityGeneration else { return }
        capacityPending.remove(agentID)
        guard case .ok(let resultData) = reply,
              let obj = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        else {
            capacities.removeValue(forKey: agentID)
            return
        }
        let capacity = BoxCapacity.parse(replyObject: obj)
        capacities[agentID] = capacity
        // These numbers came off the wire, so the row must not carry an age
        // caption for them. Unreachable today (a box is either fanned out to
        // or seeded, never both) but the two maps have to agree, and this is
        // the one place `capacities` is written from a live reply.
        capacityCapturedAt.removeValue(forKey: agentID)
        folderCache[agentID] = Self.parseFolders(resultData)
        capacityCache.save(capacity, for: agentID, at: now())
    }

    // MARK: Helpers

    static func sorted(_ agents: [DeviceDTO]) -> [DeviceDTO] {
        agents.sorted { a, b in
            if a.connected != b.connected { return a.connected }
            return a.name < b.name
        }
    }

    private static func sameFolderAgent(_ phase: Phase, _ agent: DeviceDTO) -> Bool {
        if case .folders(let current) = phase, current.id == agent.id { return true }
        return false
    }

    private static func isUnreachable(_ reply: RPCReply) -> Bool {
        if case .failure(let code, _) = reply { return code == "agent_unreachable" }
        return false
    }

    static func parseFolders(_ data: Data) -> [RecentFolder] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["folders"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry -> RecentFolder? in
            guard let path = entry["path"] as? String, !path.isEmpty else { return nil }
            return RecentFolder(path: path, lastUsed: (entry["last_used"] as? NSNumber)?.int64Value)
        }
        // Newest first; never-used (nil) entries last.
        .sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.path < b.path
            }
        }
    }

    static func startErrorCopy(code: String, detail: String?) -> String {
        switch code {
        case "agent_unreachable", "not_ready":
            // Same situation as a timeout from where the user stands.
            return "The agent didn't answer — is the box awake?"
        case "bad_workdir":
            return "That folder doesn't exist on the box."
        default:
            return "Couldn't start — \(detail ?? code)."
        }
    }
}
