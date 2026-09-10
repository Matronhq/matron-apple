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
    func sessionTag(convoID: String) -> SessionTagInputs?
}

extension JournalStore: MissionsStoreReading {
    /// Derived from three reads the store already has: the conversation row
    /// (`conversation(id:)`), the box roster (`agentNames()`) and the
    /// journal-held tag overrides (`agentTagChars()`). This is the same
    /// derivation `JournalChatService.summary(from:boxNames:boxLetters:)`
    /// runs for a chat-list row — restated here because that one is
    /// internal to `MatronChat` — including its two gates: a box letter
    /// only means something when the user has two or more boxes, and the
    /// session short is peeled off the stored title by
    /// `SessionTag.splitTitle`. Cheap enough to call on the main actor
    /// (a handful of indexed row reads), like `conversationOriginLabels()`.
    public func sessionTag(convoID: String) -> SessionTagInputs? {
        guard let record = try? conversation(id: convoID) else { return nil }
        let names = (try? agentNames()) ?? [:]
        let letters = SessionTag.boxLetters(for: names, overrides: (try? agentTagChars()) ?? [:])
        let boxName = names.count >= 2 ? record.agentDeviceID.flatMap { names[$0] } : nil
        let boxLetter = boxName != nil ? record.agentDeviceID.flatMap { letters[$0] } : nil
        let sessionShort = SessionTag.splitTitle(record.title).sessionShort
        guard boxLetter != nil || sessionShort != nil else { return nil }
        return SessionTagInputs(boxLetter: boxLetter, boxName: boxName, sessionShort: sessionShort)
    }
}

/// The write/refresh surface, mirroring `ItemsSyncing`. `supportedStream` is
/// `async` because `MissionsSync` is an actor and the method is isolated.
public protocol MissionsSyncing: Sendable {
    @discardableResult
    func refresh() async -> MissionsRefreshOutcome
    func refreshMission(id: String) async
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
        // only visible consequence (spec, Error handling).
        if case .failed(let failure) = await sync.refresh() { error = failure.message }
    }
}
