import XCTest
import MatronModels
import MatronChat
import MatronJournal
@testable import MatronViewModels

private final class FakeDashboardStore: MissionsDashboardStoreReading, @unchecked Sendable {
    let missions: AsyncStream<[Mission]>.Continuation
    let conversations: AsyncStream<[String: [MissionConversation]]>.Continuation
    let milestones: AsyncStream<[String: Milestone]>.Continuation
    let items: AsyncStream<[String: [TrackerItem]]>.Continuation
    let tocs: AsyncStream<[String: String]>.Continuation
    let sessionStates: AsyncStream<[String: String]>.Continuation
    private let missionsValue: AsyncStream<[Mission]>
    private let conversationsValue: AsyncStream<[String: [MissionConversation]]>
    private let milestonesValue: AsyncStream<[String: Milestone]>
    private let itemsValue: AsyncStream<[String: [TrackerItem]]>
    private let tocsValue: AsyncStream<[String: String]>
    private let sessionStatesValue: AsyncStream<[String: String]>

    init() {
        (missionsValue, missions) = AsyncStream.makeStream()
        (conversationsValue, conversations) = AsyncStream.makeStream()
        (milestonesValue, milestones) = AsyncStream.makeStream()
        (itemsValue, items) = AsyncStream.makeStream()
        (tocsValue, tocs) = AsyncStream.makeStream()
        (sessionStatesValue, sessionStates) = AsyncStream.makeStream()
    }
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { missionsValue }
    func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]> { conversationsValue }
    func latestMilestonesStream() -> AsyncStream<[String: Milestone]> { milestonesValue }
    func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]> { itemsValue }
    func latestSummaryTOCsStream() -> AsyncStream<[String: String]> { tocsValue }
    func sessionStatesStream() -> AsyncStream<[String: String]> { sessionStatesValue }
}

private final class FakeDashboardSync: MissionsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshes = 0
    private var _refetches: [String] = []
    private var _inFlight = 0
    private var _maxInFlight = 0
    private var _gate = false
    private var _waiters: [CheckedContinuation<Void, Never>] = []
    private var _refreshOutcome: MissionsRefreshOutcome = .succeeded
    var supported: [Bool] = [true]

    var refreshes: Int { lock.withLock { _refreshes } }
    var refetches: [String] { lock.withLock { _refetches } }
    var inFlight: Int { lock.withLock { _inFlight } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var gateDetails: Bool { get { lock.withLock { _gate } } set { lock.withLock { _gate = newValue } } }
    var refreshOutcome: MissionsRefreshOutcome {
        get { lock.withLock { _refreshOutcome } } set { lock.withLock { _refreshOutcome = newValue } }
    }
    func releaseWaiting() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { _waiters = [] }; return _waiters }
        waiters.forEach { $0.resume() }
    }

    func refresh() async -> MissionsRefreshOutcome { lock.withLock { _refreshes += 1; return _refreshOutcome } }
    func refreshMission(id: String) async -> MissionsRefreshOutcome {
        let gated = lock.withLock { () -> Bool in
            _refetches.append(id); _inFlight += 1; _maxInFlight = max(_maxInFlight, _inFlight); return _gate
        }
        if gated { await withCheckedContinuation { c in lock.withLock { _waiters.append(c) } } }
        lock.withLock { _inFlight -= 1 }
        return .succeeded
    }
    func closeMission(id: String, summary: String) async throws -> Mission { fatalError("not used") }
    func supportedStream() async -> AsyncStream<Bool> {
        let values = supported
        return AsyncStream { c in for v in values { c.yield(v) }; c.finish() }
    }
}

private final class FakeRoster: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _results: [Result<[String: String], Error>] = [.success([:])]
    var calls: Int { lock.withLock { _calls } }
    /// Each call takes the next result; the last one repeats forever.
    func script(_ results: [Result<[String: String], Error>]) { lock.withLock { _results = results } }
    func fetch() async throws -> [String: String] {
        let result = lock.withLock { () -> Result<[String: String], Error> in
            _calls += 1
            return _results.count > 1 ? _results.removeFirst() : _results[0]
        }
        return try result.get()
    }
}

private final class SendRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(convoID: String, body: String)] = []
    private var _error: Error?
    var sent: [(convoID: String, body: String)] { lock.withLock { _sent } }
    var error: Error? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    func send(_ convoID: String, _ body: String) async throws {
        if let error { throw error }
        lock.withLock { _sent.append((convoID, body)) }
    }
}

@MainActor
final class MissionsDashboardViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var store: FakeDashboardStore!
    private var sync: FakeDashboardSync!
    private var roster: FakeRoster!
    private var sender: SendRecorder!
    private var summaries: AsyncThrowingStream<[ChatSummary], Error>.Continuation!
    private var vm: MissionsDashboardViewModel!

    private func makeVM(rosterInterval: Duration = .seconds(60)) {
        store = FakeDashboardStore(); sync = FakeDashboardSync(); roster = FakeRoster(); sender = SendRecorder()
        let (stream, continuation) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        summaries = continuation
        let rosterFake: FakeRoster = self.roster, senderFake: SendRecorder = self.sender, fixedNow = now
        vm = MissionsDashboardViewModel(store: store, sync: sync, summaries: { stream },
                                        roster: { try await rosterFake.fetch() },
                                        send: { try await senderFake.send($0, $1) },
                                        rosterInterval: rosterInterval, now: { fixedNow })
    }

    override func tearDown() async throws {
        sync?.gateDetails = false
        sync?.releaseWaiting()
        vm?.stop()
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func mission(_ id: String, num: Int, needsYou: Int = 0, statusUpdatedAt: Date? = nil) -> Mission {
        Mission(id: id, num: num, title: "M\(num)", originConvoID: "c-origin-\(num)",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                needsYou: needsYou, conversationCount: 1,
                status: statusUpdatedAt == nil ? nil : "Status", statusBy: statusUpdatedAt == nil ? nil : .agent,
                statusUpdatedAt: statusUpdatedAt)
    }

    /// `ChatSummary` carries no session state of its own (removed for
    /// chat-list performance; state comes from `JournalStore
    /// .sessionStatesStream()` instead) — this returns the summary paired
    /// with its intended state so a call site can push both together
    /// through `yieldSummaries`, exactly like `MissionsDashboardAssemblyTests`
    /// does for `MissionsDashboardInputs.setSummaries`.
    private func summary(_ id: String, state: String = "running") -> (ChatSummary, String) {
        (ChatSummary(id: id, title: "Chat \(id)", bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
                    lastActivity: now.addingTimeInterval(-60), unreadCount: 0), state)
    }

    /// Yields the summaries list and their paired session states together,
    /// so a test can never forget one half of the pair.
    private func yieldSummaries(_ pairs: [(ChatSummary, String)]) {
        summaries.yield(pairs.map(\.0))
        store.sessionStates.yield(Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) }))
    }

    // MARK: Streams

    func testStartPublishesCardsLooseAndClosedAndTheBadge() async {
        makeVM()
        vm.start()
        store.missions.yield([
            mission("ms_1", num: 61, needsYou: 2),
            Mission(id: "ms_0", num: 50, state: .closed, title: "Old", originConvoID: "c0", closedAt: now),
        ])
        store.conversations.yield(["ms_1": [MissionConversation(id: "c1", title: "", box: nil, state: "running")]])
        yieldSummaries([summary("c1"), summary("c-loose")])
        await waitUntil { vm.cards.first?.sessions.first?.title == "Chat c1" && !vm.looseSessions.isEmpty }
        XCTAssertEqual(vm.cards.map(\.id), ["ms_1"])
        XCTAssertEqual(vm.closed.map(\.id), ["ms_0"])
        XCTAssertEqual(vm.looseSessions.map(\.id), ["c-loose"])
        XCTAssertEqual(vm.needsYouTotal, 2)
        XCTAssertEqual(sync.refreshes, 1, "start runs one list refresh")
        XCTAssertEqual(roster.calls, 0, "no roster until the page shows")
    }

    func testIsSupportedStartsUnknownThenFollowsTheSync() async {
        makeVM()
        XCTAssertNil(vm.isSupported)
        sync.supported = [true, false]
        vm.start()
        await waitUntil { vm.isSupported == false }
    }

    func testRefreshReportsAFailureAndASuccessClearsIt() async {
        makeVM()
        sync.refreshOutcome = .failed(MissionsRefreshFailure(message: "offline"))
        await vm.refresh()
        XCTAssertEqual(vm.error, "offline")
        sync.refreshOutcome = .succeeded
        await vm.refresh()
        XCTAssertNil(vm.error)
        XCTAssertEqual(roster.calls, 2, "a refresh also fetches the roster")
    }

    // MARK: Roster poll (spec §3.7)

    func testRosterPollsOnlyWhileThePageShows() async {
        makeVM(rosterInterval: .milliseconds(30))
        vm.start()
        vm.pageDidAppear()
        await waitUntil { roster.calls >= 3 }
        vm.pageDidDisappear()
        let settled = roster.calls
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(roster.calls, settled, "the poll stops with the page")
    }

    /// Review Focus: SwiftUI can deliver `onAppear` twice.
    func testAppearingTwiceRunsOneRosterLoop() async {
        makeVM(rosterInterval: .seconds(60))
        vm.start()
        vm.pageDidAppear()
        vm.pageDidAppear()
        await waitUntil { roster.calls >= 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(roster.calls, 1)
    }

    func testAFailedRosterFetchKeepsTheLastSummaries() async {
        makeVM(rosterInterval: .milliseconds(30))
        roster.script([.success(["c1": "Reviewing the parser"]), .failure(URLError(.notConnectedToInternet))])
        vm.start()
        store.missions.yield([mission("ms_1", num: 61)])
        store.conversations.yield(["ms_1": [MissionConversation(id: "c1", title: "", box: nil, state: "running")]])
        yieldSummaries([summary("c1")])
        vm.pageDidAppear()
        await waitUntil { vm.cards.first?.sessions.first?.summary == "Reviewing the parser" }
        await waitUntil { roster.calls >= 3 }
        XCTAssertEqual(vm.cards.first?.sessions.first?.summary, "Reviewing the parser")
        XCTAssertNil(vm.error, "a failed roster fetch is not an error")
    }

    // MARK: Detail fan-out (spec §3.7)

    func testDetailRefreshOnAppearIsCappedAtFourInFlight() async {
        makeVM()
        sync.gateDetails = true
        vm.start()
        store.missions.yield((1...6).map { mission("ms_\($0)", num: $0) })
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.inFlight == 4 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.refetches.count, 4, "the fifth waits for a slot")
        while sync.refetches.count < 6 {
            sync.releaseWaiting()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        sync.gateDetails = false
        sync.releaseWaiting()
        XCTAssertEqual(Set(sync.refetches), Set((1...6).map { "ms_\($0)" }))
        XCTAssertEqual(sync.maxInFlight, 4)
    }

    /// The page can show before the first missions snapshot lands (cold
    /// launch straight onto the tab): the fan-out waits for it.
    func testAppearingBeforeTheMissionsLandStillRefreshesTheirDetails() async {
        makeVM()
        vm.start()
        vm.pageDidAppear()
        store.missions.yield([mission("ms_1", num: 1), mission("ms_2", num: 2)])
        await waitUntil { Set(sync.refetches) == ["ms_1", "ms_2"] }
    }

    // MARK: Ask the Coordinator (spec §3.4)

    func testAskSendsTheExactMessageToTheCoordinatorAndShowsAsked() async {
        makeVM()
        vm.coordinatorConvoID = "c-coord"
        XCTAssertTrue(vm.canAskCoordinator)
        await vm.askCoordinator()
        XCTAssertEqual(sender.sent.map(\.convoID), ["c-coord"])
        XCTAssertEqual(sender.sent.map(\.body),
                       ["Refresh the status of every open mission from its latest milestones, sessions and open items."])
        XCTAssertEqual(vm.askedAt, now)
    }

    func testAskedClearsWhenAStatusLandsAfterIt() async {
        makeVM()
        vm.start()
        vm.coordinatorConvoID = "c-coord"
        await vm.askCoordinator()
        store.missions.yield([mission("ms_1", num: 1, statusUpdatedAt: now.addingTimeInterval(-600))])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.askedAt, now, "an older status is not the answer")
        store.missions.yield([mission("ms_1", num: 1, statusUpdatedAt: now.addingTimeInterval(5))])
        await waitUntil { vm.askedAt == nil }
    }

    func testAFailedAskSurfacesTheErrorAndIsNotMarkedAsked() async {
        makeVM()
        vm.coordinatorConvoID = "c-coord"
        sender.error = URLError(.cannotWriteToFile)
        await vm.askCoordinator()
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.askedAt)
    }

    /// Review Focus: no Coordinator, or a blank cached id.
    func testAskIsHiddenAndInertWithoutACoordinator() async {
        makeVM()
        for id in [nil, "", "   "] as [String?] {
            vm.coordinatorConvoID = id
            XCTAssertFalse(vm.canAskCoordinator)
            await vm.askCoordinator()
        }
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertNil(vm.askedAt)
    }

    func testTheCoordinatorIsNeverALooseSession() async {
        makeVM()
        vm.start()
        yieldSummaries([summary("c-coord"), summary("c-other")])
        await waitUntil { vm.looseSessions.count == 2 }
        vm.coordinatorConvoID = "c-coord"
        XCTAssertEqual(vm.looseSessions.map(\.id), ["c-other"])
    }
}
