import Foundation
import os
import MatronJournal
import MatronModels

/// What the Boxes screen reads: New Chat's RPC slice, plus the roster for
/// each box's sessions and whether a disconnected box can be woken.
public protocol BoxesProviding: AgentRPCProviding {
    func roster() async throws -> RosterSnapshot
}

/// One row of the Boxes screen.
public struct BoxRow: Identifiable {
    public var id: Int64 { device.id }
    public let device: DeviceDTO
    public let state: BoxConnectionState
    public let capacity: BoxCapacity?
    public let freshness: AgentCapacityFreshness
    /// The sessions to list under this box, busiest first.
    public let sessions: [RosterSession]
    public let isNearLimit: Bool
    public let isMostSpare: Bool
    public let defaultsText: String?
    /// When the usage numbers were read; nil when there are none.
    public let readingDate: Date?
    /// A wake in progress or just failed; nil otherwise.
    public let wake: NewChatViewModel.RowWake?

    /// The live-session count to show. A sleeping box runs nothing, so its
    /// last count would be false rather than merely old.
    public var liveCount: Int? { state == .online ? capacity?.liveSessions : nil }
    /// A session can be started here: the box is up or can be woken.
    public var canStartSession: Bool { state != .offline }
}

/// The figures across the top of the Boxes screen.
public struct BoxesSummary {
    public let total: Int
    public let online: Int
    public let asleep: Int
    public let offline: Int
    public let spare: AllowanceSpare?
    /// Names of the boxes on the most-spare login.
    public let spareBoxNames: [String]
    public let nearLimitNames: [String]
    public let lowestDisk: (name: String, disk: BoxDisk)?

    /// "21 boxes · 19 online · 2 asleep"; a zero count is left out.
    public var countsText: String {
        var parts = ["\(total) \(total == 1 ? "box" : "boxes")"]
        if online > 0 { parts.append("\(online) online") }
        if asleep > 0 { parts.append("\(asleep) asleep") }
        if offline > 0 { parts.append("\(offline) offline") }
        return parts.joined(separator: " · ")
    }

    /// "a, b, c and 2 more".
    public static func namesText(_ names: [String], limit: Int = 3) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
    }
}

/// Every paired box with its state, usage and sessions. Reads what the
/// journal already holds, so opening the screen asks no box anything;
/// `box_status` frames and a slow poll keep it current while it shows.
@Observable @MainActor
public final class BoxesViewModel {
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?
    private var devices: [DeviceDTO] = []
    private var reports: [Int64: BoxStatus] = [:]
    /// Nil until the first roster answer. Until then a disconnected box
    /// reads as asleep, as New Chat treats it.
    private var roster: RosterSnapshot?

    private let api: any BoxesProviding
    private let waker: NewChatViewModel
    private let pollSleep: @Sendable () async -> Void
    private static let logger = Logger(subsystem: "chat.matron", category: "boxes")

    public init(api: any BoxesProviding, capacityCache: any BoxCapacityCaching,
                pollSleep: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(60)) }) {
        self.api = api
        self.waker = NewChatViewModel(api: api, capacityCache: capacityCache)
        self.pollSleep = pollSleep
    }

    public func load() async {
        do {
            let agents = try await api.devices().filter { $0.kind == "agent" }
            let snapshot = try? await api.roster()
            devices = agents
            if let snapshot { roster = snapshot }
            for agent in agents {
                if let status = agent.status { adopt(status, for: agent.id) }
            }
            errorMessage = nil
        } catch {
            Self.logger.error("boxes load failed: \(String(describing: error), privacy: .public)")
            errorMessage = "Couldn't load your boxes. Try again."
        }
        hasLoaded = true
    }

    /// Applies live reports and refreshes on a reconnect and on a slow poll
    /// (which is how a box coming or going, or a new session, shows up).
    /// Runs until the calling task is cancelled.
    public func watch() async {
        let frames = api.boxStatusUpdates()
        let states = api.connectionStates()
        let sleep = pollSleep
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await update in frames {
                    await self?.adopt(update.status, for: update.deviceID)
                }
            }
            group.addTask { [weak self] in
                var wasRunning: Bool?
                for await state in states {
                    let isRunning = state == .running
                    defer { wasRunning = isRunning }
                    guard let wasRunning, isRunning, !wasRunning else { continue }
                    await self?.load()
                }
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    await sleep()
                    guard !Task.isCancelled else { return }
                    await self?.load()
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Locked boxes

    /// Signs unlocks and lockdown clears. Set by the app.
    public var approvalSigner: ApprovalSigner?
    /// Why the last unlock, lock or clear failed; shown by the screen.
    public var lockError: String?
    /// A box that answered "in lockdown": the screen offers to clear it.
    public private(set) var lockdownBoxes: Set<Int64> = []
    /// Boxes with an unlock, lock or clear in flight.
    public private(set) var lockBusy: Set<Int64> = []

    /// Opens an unlock window on a locked box. True when the box took it.
    @discardableResult
    public func unlock(_ device: DeviceDTO, minutes: Int) async -> Bool {
        await lockAction(device) {
            await BoxLockControl.unlock(box: device, minutes: minutes, api: self.api, signer: self.approvalSigner)
        }
    }

    /// Ends an unlock window now.
    @discardableResult
    public func lock(_ device: DeviceDTO) async -> Bool {
        await lockAction(device) { await BoxLockControl.lock(box: device, api: self.api) }
    }

    /// Ends a box's lockdown.
    @discardableResult
    public func clearLockdown(_ device: DeviceDTO) async -> Bool {
        let cleared = await lockAction(device) {
            await BoxLockControl.clearLockdown(box: device, api: self.api, signer: self.approvalSigner)
        }
        if cleared { lockdownBoxes.remove(device.id) }
        return cleared
    }

    private func lockAction(_ device: DeviceDTO, _ action: () async -> BoxLockControl.Failure?) async -> Bool {
        guard !lockBusy.contains(device.id) else { return false }
        lockBusy.insert(device.id)
        defer { lockBusy.remove(device.id) }
        lockError = nil
        if let failure = await action() {
            if case .lockdown = failure { lockdownBoxes.insert(device.id) }
            lockError = failure.text
            return false
        }
        // The box reports its new state to the journal a moment later.
        await load()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.load()
        }
        return true
    }

    public func wake(_ device: DeviceDTO) async {
        await waker.wake(agent: device)
        await load()
    }

    /// Latest report wins, so a frame that beat a roster read is kept.
    private func adopt(_ status: BoxStatus, for boxID: Int64) {
        if let held = reports[boxID], held.reportedAt >= status.reportedAt { return }
        reports[boxID] = status
    }

    /// Online, then asleep, then offline, each A to Z: the rows stay put
    /// as their numbers change.
    public func rows(now: Date = Date()) -> [BoxRow] {
        let readings = devices.compactMap { device -> BoxAllowanceReading? in
            guard let capacity = reports[device.id]?.capacity else { return nil }
            return BoxAllowanceReading(boxID: device.id, accountEmail: capacity.accountEmail,
                                       lines: capacity.limitLines)
        }
        let spare = BoxAllowances.mostSpare(readings, now: now)
        return devices.map { row(for: $0, spare: spare, now: now) }.sorted { lhs, rhs in
            let (left, right) = (Self.rank(lhs.state), Self.rank(rhs.state))
            if left != right { return left < right }
            return lhs.device.name.localizedStandardCompare(rhs.device.name) == .orderedAscending
        }
    }

    public func summary(of rows: [BoxRow], now: Date = Date()) -> BoxesSummary {
        let readings = rows.compactMap { row in
            row.capacity.map {
                BoxAllowanceReading(boxID: row.id, accountEmail: $0.accountEmail, lines: $0.limitLines)
            }
        }
        let spare = BoxAllowances.mostSpare(readings, now: now)
        let lowest = rows.compactMap { row in row.capacity?.disk.map { (name: row.device.name, disk: $0) } }
            .min { $0.disk.freeBytes < $1.disk.freeBytes }
        return BoxesSummary(
            total: rows.count,
            online: rows.filter { $0.state == .online }.count,
            asleep: rows.filter { $0.state == .asleep }.count,
            offline: rows.filter { $0.state == .offline }.count,
            spare: spare,
            spareBoxNames: rows.filter { spare?.boxIDs.contains($0.id) == true }.map(\.device.name),
            nearLimitNames: rows.filter(\.isNearLimit).map(\.device.name),
            lowestDisk: lowest)
    }

    private func row(for device: DeviceDTO, spare: AllowanceSpare?, now: Date) -> BoxRow {
        let report = reports[device.id]
        let capacity = report?.capacity
        let state: BoxConnectionState = device.connected
            ? .online
            : (roster == nil || roster?.wakeableBoxes.contains(device.id) == true) ? .asleep : .offline
        let freshness = report.map { AgentCapacityFreshness.report($0, connected: device.connected) } ?? .live
        let hasLines = capacity?.limitLines.isEmpty == false
        return BoxRow(
            device: device, state: state, capacity: capacity, freshness: freshness,
            sessions: Self.shownSessions(roster?.sessionsByBox[device.id] ?? [],
                                         liveCount: capacity?.liveSessions,
                                         isOnline: state == .online, now: now),
            isNearLimit: !freshness.isStale && BoxAllowances.isNearLimit(capacity?.limitLines ?? [], now: now),
            isMostSpare: spare?.boxIDs.contains(device.id) == true,
            defaultsText: Self.defaultsText(device: device, capacity: capacity),
            readingDate: hasLines ? (capacity?.limitsAsOf ?? report?.reportedAt) : nil,
            wake: Self.visibleWake(waker.rowWake(for: device)))
    }

    /// `rowWake` says `.asleep` for every disconnected box; the row only
    /// cares about a wake that is under way or has failed.
    private static func visibleWake(_ wake: NewChatViewModel.RowWake?) -> NewChatViewModel.RowWake? {
        wake == .asleep ? nil : wake
    }

    private static func rank(_ state: BoxConnectionState) -> Int {
        switch state {
        case .online: return 0
        case .asleep: return 1
        case .offline: return 2
        }
    }

    /// The bridge's own stored defaults first (they include what the box's
    /// environment chose), else what the journal holds for the box.
    private static func defaultsText(device: DeviceDTO, capacity: BoxCapacity?) -> String? {
        if let resolved = capacity?.defaults {
            return BoxAllowances.defaultsText(agent: resolved.agent, model: resolved.model, effort: resolved.effort)
        }
        guard let agent = device.defaults?.agent else { return nil }
        return BoxAllowances.defaultsText(agent: agent, model: device.defaults?.model, effort: device.defaults?.effort)
    }

    /// The journal marks a session `waiting` even after its process has
    /// gone, so the open list alone overstates what is live. Running ones
    /// always show; waiting ones fill up to the box's own live count, most
    /// recent first. A box that reports no count shows the last hour's.
    static func shownSessions(_ sessions: [RosterSession], liveCount: Int?, isOnline: Bool,
                              now: Date) -> [RosterSession] {
        guard isOnline else { return [] }
        let byRecency = sessions.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
        let running = byRecency.filter(\.isRunning)
        let waiting = byRecency.filter { !$0.isRunning }
        guard let liveCount else {
            return running + waiting.filter {
                ($0.lastActivity).map { now.timeIntervalSince($0) < 3600 } ?? false
            }
        }
        return running + waiting.prefix(max(0, liveCount - running.count))
    }
}
