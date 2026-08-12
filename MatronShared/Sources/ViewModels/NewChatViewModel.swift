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
/// - Timeout and `agent_unreachable` are the same situation to the user.
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

    private let api: any AgentRPCProviding
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

    public init(api: any AgentRPCProviding) {
        self.api = api
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
                startCapacityFanOut(connected.map(\.id))
            }
        } catch {
            phase = .agents([])
            errorMessage = "Couldn't load agents — try again."
        }
    }

    public func select(agent: DeviceDTO) async {
        phase = .folders(agent: agent)
        folders = []
        foldersError = nil
        // The roster fan-out already asked this box for its folders — render
        // them instantly rather than paying for the same round-trip twice.
        if let cached = folderCache[agent.id] {
            folders = cached
            return
        }
        do {
            let reply = try await api.agentRequest(
                agentDeviceID: agent.id, method: "recent_folders", paramsData: Data("{}".utf8))
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

    /// Fires `start {workdir?, browser?}` at the picked agent. `workdir`
    /// nil/blank means the bridge's default workdir — the key is omitted.
    public func start(workdir: String?) async {
        guard case .folders(let agent) = phase, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil
        var params: [String: Any] = [:]
        let trimmed = workdir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { params["workdir"] = trimmed }
        if browserEnabled { params["browser"] = true }
        // A [String: Any] of strings/bools always serializes.
        let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        do {
            let reply = try await api.agentRequest(
                agentDeviceID: agent.id, method: "start", paramsData: paramsData)
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
    /// account while the user is still choosing. The roster is already on
    /// screen — this only fills rows in, so failures stay silent.
    private func startCapacityFanOut(_ agentIDs: [Int64]) {
        capacityFanOutForTesting?.cancel()
        capacityGeneration &+= 1
        let generation = capacityGeneration
        capacityPending = Set(agentIDs)
        // A reload re-asks every box, so last visit's folder lists are stale
        // from this moment: drop them rather than let `select(agent:)` serve
        // them before the new replies land — it falls back to a live
        // `recent_folders` when the cache is empty.
        folderCache.removeAll()
        capacityFanOutForTesting = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for id in agentIDs {
                    group.addTask { await self?.fetchCapacity(agentID: id, generation: generation) }
                }
            }
        }
    }

    /// One box's fan-out leg. A failure, a timeout or an unparseable reply
    /// all leave the row exactly as it was before (name + "Connected") —
    /// capacity is a convenience, never a gate.
    private func fetchCapacity(agentID: Int64, generation: Int) async {
        let reply = try? await api.agentRequest(
            agentDeviceID: agentID, method: "recent_folders", paramsData: Data("{}".utf8))
        // Superseded by a newer fan-out while this leg was in flight: this
        // answer describes a roster nobody is looking at any more.
        guard generation == capacityGeneration else { return }
        capacityPending.remove(agentID)
        guard case .ok(let resultData) = reply,
              let obj = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        else { return }
        capacities[agentID] = BoxCapacity.parse(replyObject: obj)
        folderCache[agentID] = Self.parseFolders(resultData)
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
