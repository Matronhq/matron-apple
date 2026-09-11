import Foundation
import Observation
import MatronChat
import MatronModels
import MatronJournal

/// The store reads the missions surfaces need, as a protocol so tests fake
/// the store (`JournalStore` conforms; the conformance is declared here
/// because `MatronJournal` cannot import this module).
public protocol MissionsStoreReading: Sendable {
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]>
    func missionStream(id: String) -> AsyncStream<Mission?>
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]>
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]>
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]>
    /// The `A:bc` tag halves for one conversation, or `nil` when this
    /// device has no cached row for it (a milestone can name a
    /// conversation that has never synced here — it renders untagged).
    /// The batch form's one-element caller (MINOR-5).
    func sessionTag(convoID: String) -> SessionTagInputs?
    /// The `A:bc` tag halves for several conversations, keyed by id, with
    /// no entry for a conversation this device has no cached row for. The
    /// box roster and letter overrides are read ONCE for the whole batch,
    /// not once per conversation — a mission page re-derives every tag on
    /// every milestone-stream emission, so that part is not irreducible
    /// the way the per-conversation `conversation(id:)` read is (MINOR-5).
    func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs]
}

extension JournalStore: MissionsStoreReading {
    public func sessionTag(convoID: String) -> SessionTagInputs? {
        sessionTags(convoIDs: [convoID])[convoID]
    }

    /// Derived from reads the store already has: the conversation row
    /// (`conversation(id:)`, one per id), the box roster (`agentNames()`)
    /// and the journal-held tag overrides (`agentTagChars()`) — the latter
    /// two hoisted out of the per-conversation loop. This is the same
    /// derivation `JournalChatService.summary(from:boxNames:boxLetters:)`
    /// runs for a chat-list row — restated here because that one is
    /// internal to `MatronChat` — including its two gates: a box letter
    /// only means something when the user has two or more boxes, and the
    /// session short is peeled off the stored title by
    /// `SessionTag.splitTitle`. Also restates `JournalChatService.roomTags`
    /// for a multi-agent room (Bugbot: the mission page used to carry only
    /// the single-box halves, so a room conversation rendered as an
    /// owner-box `A:bc` there instead of `A↔B:bc` — chat headers and list
    /// rows already try `SessionTagText.room` before `.run`). Cheap enough
    /// to call on the main actor (a handful of indexed row reads), like
    /// `conversationOriginLabels()`.
    public func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs] {
        guard !convoIDs.isEmpty else { return [:] }
        let names = (try? agentNames()) ?? [:]
        let letters = SessionTag.boxLetters(for: names, overrides: (try? agentTagChars()) ?? [:])
        var tags: [String: SessionTagInputs] = [:]
        for convoID in convoIDs {
            guard let record = try? conversation(id: convoID) else { continue }
            let boxName = names.count >= 2 ? record.agentDeviceID.flatMap { names[$0] } : nil
            let boxLetter = boxName != nil ? record.agentDeviceID.flatMap { letters[$0] } : nil
            let sessionShort = SessionTag.splitTitle(record.title).sessionShort
            let room = Self.roomTags(participantIDs: record.participantIDs, names: names, letters: letters)
            guard boxLetter != nil || sessionShort != nil || !room.isEmpty else { continue }
            tags[convoID] = SessionTagInputs(boxLetter: boxLetter, boxName: boxName, sessionShort: sessionShort,
                                             roomBoxNames: room.map(\.name), roomBoxShorts: room.map(\.letter))
        }
        return tags
    }

    /// Restates `JournalChatService.roomTags(for:boxNames:boxLetters:)`:
    /// every participant id resolved to its box name AND display letter,
    /// deduped by name in journal order, empty unless at least two
    /// DISTINCT boxes resolve — same two-box gate as the single-box tag,
    /// so a local room (both ends share one box) or a single-box user
    /// falls through to `run(...)`.
    private static func roomTags(
        participantIDs: [Int64], names: [Int64: String], letters: [Int64: String]
    ) -> [(name: String, letter: String)] {
        guard names.count >= 2, participantIDs.count >= 2 else { return [] }
        var seen = Set<String>()
        var tags: [(name: String, letter: String)] = []
        for id in participantIDs {
            guard let name = names[id], seen.insert(name).inserted else { continue }
            tags.append((name: name, letter: letters[id] ?? "?"))
        }
        return tags.count >= 2 ? tags : []
    }
}

/// The write/refresh surface, mirroring `ItemsSyncing`. `supportedStream` is
/// `async` because `MissionsSync` is an actor and the method is isolated.
public protocol MissionsSyncing: Sendable {
    @discardableResult
    func refresh() async -> MissionsRefreshOutcome
    @discardableResult
    func refreshMission(id: String) async -> MissionsRefreshOutcome
    @discardableResult
    func closeMission(id: String, summary: String) async throws -> Mission
    func supportedStream() async -> AsyncStream<Bool>
}
extension MissionsSync: MissionsSyncing {}

/// Backs the Missions tab's list (spec: Apps → Missions tab). Open missions
/// sorted by latest milestone; closed ones in a collapsed section.
@MainActor @Observable
public final class MissionsListViewModel {
    public private(set) var open: [Mission] = []
    public private(set) var closed: [Mission] = []
    /// `false` once the journal has answered 404 on `GET /missions` — the
    /// hosts hide the tab entirely on it.
    public private(set) var isSupported = true
    public private(set) var isRefreshing = false
    public var error: String?
    /// The tab / nav badge: how many items across every open mission are
    /// waiting on the user.
    public var needsYouTotal: Int { open.reduce(0) { $0 + $1.needsYou } }

    private let store: any MissionsStoreReading
    private let sync: any MissionsSyncing
    private var missionsTask: Task<Void, Never>?
    private var supportedTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(store: any MissionsStoreReading, sync: any MissionsSyncing) {
        self.store = store; self.sync = sync
    }

    /// Open: `lastMilestoneAt` desc with never-checkpointed missions last,
    /// `createdAt` desc as the tiebreak — the journal's own order, restated
    /// here so a cache assembled from several fetches still agrees with it.
    /// Closed: newest close first.
    public static func sections(from missions: [Mission]) -> (open: [Mission], closed: [Mission]) {
        let open = missions.filter { $0.state == .open }.sorted { a, b in
            switch (a.lastMilestoneAt, b.lastMilestoneAt) {
            case let (l?, r?): return l == r ? a.createdAt > b.createdAt : l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return a.createdAt > b.createdAt
            }
        }
        let closed = missions.filter { $0.state == .closed }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        return (open, closed)
    }

    public func start() {
        stop()
        missionsTask = Task { [weak self] in
            guard let stream = self?.store.missionsStream(state: nil) else { return }
            for await missions in stream {
                guard let self, !Task.isCancelled else { return }
                let sections = Self.sections(from: missions)
                self.open = sections.open
                self.closed = sections.closed
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
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    public func stop() {
        missionsTask?.cancel(); missionsTask = nil
        supportedTask?.cancel(); supportedTask = nil
        refreshTask?.cancel(); refreshTask = nil
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        // A failed refresh leaves the cached tables alone; the banner is the
        // only visible consequence (spec, Error handling). A later success
        // clears that banner instead of leaving it stuck past the failure
        // that caused it.
        switch await sync.refresh() {
        case .succeeded: error = nil
        case .failed(let failure): error = failure.message
        case .unsupported, .stopped: break
        }
    }
}
