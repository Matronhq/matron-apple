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
    private var _ignoresCancellation = false
    /// Keyed so a specific blocked call can be resumed from `onCancel`
    /// without disturbing the others (a plain array can't identify which
    /// entry belongs to which cancelled `Task`).
    private var _waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var _refreshOutcome: MissionsRefreshOutcome = .succeeded
    var supported: [Bool] = [true]

    var refreshes: Int { lock.withLock { _refreshes } }
    var refetches: [String] { lock.withLock { _refetches } }
    var inFlight: Int { lock.withLock { _inFlight } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    /// Calls currently parked on the gate (registered, so the next
    /// `releaseWaiting()` is guaranteed to reach them).
    var waiting: Int { lock.withLock { _waiters.count } }
    var gateDetails: Bool { get { lock.withLock { _gate } } set { lock.withLock { _gate = newValue } } }
    /// Production mode: a gated call IGNORES its caller's cancellation, as
    /// the real `MissionsSync.refreshMission` does (its work runs in an
    /// unstructured `Task`), and only `releaseWaiting()` lets it finish.
    var ignoresCancellation: Bool {
        get { lock.withLock { _ignoresCancellation } } set { lock.withLock { _ignoresCancellation = newValue } }
    }
    var refreshOutcome: MissionsRefreshOutcome {
        get { lock.withLock { _refreshOutcome } } set { lock.withLock { _refreshOutcome = newValue } }
    }
    /// The test's manual "the network replied" signal: resumes every
    /// currently blocked call.
    func releaseWaiting() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { _waiters.removeAll() }
            return Array(_waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    func refresh() async -> MissionsRefreshOutcome { lock.withLock { _refreshes += 1; return _refreshOutcome } }

    /// Gated like a real request: blocks until `releaseWaiting()`. By
    /// default it also resumes early on cancellation — a TEST CONVENIENCE
    /// so a cancelled fan-out settles quickly, NOT a simulation of
    /// production: the real `MissionsSync.refreshMission` launches its
    /// work in an unstructured `Task` and ignores the caller's
    /// cancellation, so an already-launched request keeps running to
    /// completion regardless of whether the page that asked for it is
    /// still around. Set `ignoresCancellation` to model that exactly.
    func refreshMission(id: String) async -> MissionsRefreshOutcome {
        let (gated, ignoring) = lock.withLock { () -> (Bool, Bool) in
            _refetches.append(id); _inFlight += 1; _maxInFlight = max(_maxInFlight, _inFlight)
            return (_gate, _ignoresCancellation)
        }
        if gated && ignoring {
            let waiterID = UUID()
            await withCheckedContinuation { c in lock.withLock { _waiters[waiterID] = c } }
        } else if gated {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in
                    // Registering and checking cancellation together,
                    // under the same lock, closes the race with
                    // `onCancel` below: if cancellation already landed
                    // before we got here, `onCancel` already ran and
                    // found nothing in `_waiters` — resume ourselves
                    // right away instead of storing a continuation
                    // nothing will ever come back to resume.
                    let alreadyCancelled = lock.withLock { () -> Bool in
                        if Task.isCancelled { return true }
                        _waiters[waiterID] = c
                        return false
                    }
                    if alreadyCancelled { c.resume() }
                }
            } onCancel: {
                let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    defer { _waiters[waiterID] = nil }
                    return _waiters[waiterID]
                }
                continuation?.resume()
            }
        }
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

/// An injectable, advanceable `now()` for the detail-refresh throttle tests
/// — a plain fixed `Date` can't express "60 seconds later."
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(by seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
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

    private func makeVM(rosterInterval: Duration = .seconds(60), clock: MutableClock? = nil) {
        store = FakeDashboardStore(); sync = FakeDashboardSync(); roster = FakeRoster(); sender = SendRecorder()
        let (stream, continuation) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        summaries = continuation
        let rosterFake: FakeRoster = self.roster, senderFake: SendRecorder = self.sender, fixedNow = now
        let nowProvider: @Sendable () -> Date
        if let clock { nowProvider = { clock.now } } else { nowProvider = { fixedNow } }
        vm = MissionsDashboardViewModel(store: store, sync: sync, summaries: { stream },
                                        roster: { try await rosterFake.fetch() },
                                        send: { try await senderFake.send($0, $1) },
                                        rosterInterval: rosterInterval, now: nowProvider)
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

    /// Answers every parked request, round after round, until `condition`
    /// holds — for the production-mode fake, whose requests only finish
    /// when released.
    private func releaseUntil(_ condition: () -> Bool, timeout: TimeInterval = 3,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            sync.releaseWaiting()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out releasing", file: file, line: line)
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

    /// Review Focus (fix round 1): the shell's `.task { vm.start() }` runs
    /// on a later main-actor turn than a child page's `onAppear`, so the
    /// dashboard can already be the page on screen when `start()` runs.
    func testAppearingBeforeStartStillPollsAndRunsTheDetailRefresh() async {
        makeVM(rosterInterval: .seconds(60))
        vm.pageDidAppear()
        vm.start()
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { roster.calls >= 1 }
        await waitUntil { sync.refetches.contains("ms_1") }
    }

    func testAfterStopAStoreYieldDoesNotChangeTheSnapshot() async {
        makeVM()
        vm.start()
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { !vm.cards.isEmpty }
        let cardsBefore = vm.cards
        vm.stop()
        store.missions.yield([mission("ms_1", num: 1, needsYou: 5)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.cards, cardsBefore, "a stopped view model ignores further store emissions")
    }

    // MARK: Coalescing (fix round 1, MINOR-3)

    /// A cold-launch snapshot fans a mission out across five separate
    /// streams landing in the same main-actor turn; each used to cost its
    /// own `assemble`.
    func testABurstOfEmissionsProducesOneRebuild() async {
        makeVM()
        vm.start()
        let before = vm.rebuildRunCount
        store.missions.yield([mission("ms_1", num: 1)])
        store.conversations.yield(["ms_1": [MissionConversation(id: "c1", title: "", box: nil, state: "running")]])
        store.milestones.yield(["ms_1": Milestone(id: "mi1", missionID: "ms_1", num: 1, kind: .progress,
                                                   title: "step", convoID: "c1", seq: 1, createdAt: now)])
        store.items.yield(["ms_1": []])
        store.tocs.yield(["c1": "heading"])
        await waitUntil { vm.cards.first?.latestStep?.title == "step" }
        XCTAssertLessThan(vm.rebuildRunCount - before, 5, "five emissions must coalesce to fewer than five assembles")
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
        // `rosterSource` is `nonisolated` — a fetch already in flight the
        // instant `pageDidDisappear()` cancels the loop can still land
        // after it, since cancellation doesn't abort a call already under
        // way. At most one such straggler, never a whole extra cycle.
        XCTAssertLessThanOrEqual(roster.calls, settled + 1, "the poll stops with the page")
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
        let deadline = Date().addingTimeInterval(2)
        while sync.refetches.count < 6, Date() < deadline {
            sync.releaseWaiting()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        sync.gateDetails = false
        sync.releaseWaiting()
        XCTAssertEqual(sync.refetches.count, 6, "timed out waiting for the remaining two")
        XCTAssertEqual(Set(sync.refetches), Set((1...6).map { "ms_\($0)" }))
        XCTAssertEqual(sync.maxInFlight, 4)
    }

    /// Review Focus (fix round 1): cancelling the fan-out mid-flight must
    /// stop it from handing out any more ids, not just leave the four
    /// already-blocked calls to finish on their own.
    func testPageDidDisappearPartWayThroughTheDetailRefreshCancelsTheRemainingRequests() async {
        makeVM()
        sync.gateDetails = true
        vm.start()
        store.missions.yield((1...6).map { mission("ms_\($0)", num: $0) })
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.inFlight == 4 }
        vm.pageDidDisappear()
        // Fix round 2: production's real `refreshMission` ignores caller
        // cancellation (an unstructured `Task` underneath), so asserting
        // `inFlight == 0` here would test something only this fake's own
        // cancellation-shortcut provides, not a real guarantee — the actual
        // invariant is just "no more ids get requested".
        XCTAssertEqual(sync.refetches.count, 4, "the fifth and sixth were never requested")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.refetches.count, 4, "still no new ids requested a moment later")
        sync.gateDetails = false
        sync.releaseWaiting()
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

    // MARK: refresh() vs. the page's own detail fan-out (fix round 1)

    /// Review Focus: pull-to-refresh used to run its own detail fan-out
    /// alongside the page's still-running one — up to 8+ in flight.
    /// `refresh()` must cancel the page's fan-out, wait for it to actually
    /// drain, then run its own — never both contributing to the cap at once.
    func testRefreshDuringTheOwnDetailRefreshNeverExceedsFourInFlight() async {
        makeVM()
        sync.gateDetails = true
        vm.start()
        store.missions.yield((1...6).map { mission("ms_\($0)", num: $0) })
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.inFlight == 4 }
        let refreshTask = Task { await vm.refresh() }
        await waitUntil({ sync.refetches.count >= 8 }, timeout: 3)
        XCTAssertLessThanOrEqual(sync.maxInFlight, 4, "refresh must drain the page's fan-out before starting its own")
        sync.gateDetails = false
        sync.releaseWaiting()
        await refreshTask.value
        XCTAssertEqual(Set(sync.refetches), Set((1...6).map { "ms_\($0)" }), "every open mission was eventually refreshed")
    }

    // MARK: Cancelled fan-outs drain before a new one dispatches (Task 10b)
    //
    // These run the fake in production mode (`ignoresCancellation`): the
    // real `MissionsSync.refreshMission` keeps a launched request running
    // after its caller is cancelled, so a cancelled fan-out's (up to four)
    // requests are still in flight until the network answers. A new batch
    // that doesn't wait for them stacks up to eight in flight.

    /// Appear -> disappear -> appear mid-fan-out: the disappear cancels the
    /// first batch, but its four requests keep running. The second appear's
    /// batch must park until they finish, never dispatching alongside them.
    func testAppearDisappearAppearMidFanOutNeverExceedsFourInFlight() async {
        makeVM()
        sync.gateDetails = true
        sync.ignoresCancellation = true
        vm.start()
        store.missions.yield((1...6).map { mission("ms_\($0)", num: $0) })
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.waiting == 4 }
        vm.pageDidDisappear()
        XCTAssertEqual(sync.inFlight, 4, "production requests outlive their caller's cancellation")
        vm.pageDidAppear()
        // Either the new batch dispatched over the old one (the bug), or it
        // parked on the cancelled batch's drain — whichever happens first.
        await waitUntil { sync.refetches.count > 4 || vm.detailDrainWaitCount >= 1 }
        XCTAssertEqual(sync.refetches.count, 4, "nothing new dispatched while the cancelled batch still runs")
        sync.releaseWaiting() // exactly the cancelled batch's four
        await waitUntil { sync.refetches.count == 8 && sync.waiting == 4 }
        XCTAssertEqual(sync.maxInFlight, 4, "the new batch only dispatched once the cancelled one drained")
        sync.gateDetails = false
        await releaseUntil { sync.refetches.count == 10 && sync.inFlight == 0 }
        XCTAssertEqual(sync.maxInFlight, 4)
        XCTAssertEqual(Set(sync.refetches.suffix(6)), Set((1...6).map { "ms_\($0)" }),
                       "the second batch still refreshed every open mission")
    }

    /// `refresh()` cancels the page's fan-out and parks on its drain; a
    /// `pageDidAppear()` landing during that park (the fix-round-2 orphan
    /// scenario) must not dispatch alongside the still-running requests.
    func testAppearDuringRefreshsDrainNeverExceedsFourInFlight() async {
        await runAppearDuringRefreshDrainScenario(disappearFirst: false)
    }

    /// As above, with a disappear first — the tab switched away and back
    /// while pull-to-refresh was still waiting on the page's batch.
    func testDisappearThenAppearDuringRefreshsDrainNeverExceedsFourInFlight() async {
        await runAppearDuringRefreshDrainScenario(disappearFirst: true)
    }

    private func runAppearDuringRefreshDrainScenario(disappearFirst: Bool,
                                                     file: StaticString = #filePath, line: UInt = #line) async {
        makeVM()
        sync.gateDetails = true
        sync.ignoresCancellation = true
        vm.start()
        store.missions.yield((1...6).map { mission("ms_\($0)", num: $0) })
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.waiting == 4 }
        let refreshTask = Task { await vm.refresh() }
        // `refresh()` has cancelled the page's batch and is parked on it.
        await waitUntil { vm.detailDrainWaitCount >= 1 }
        XCTAssertTrue(vm.isRefreshing)
        if disappearFirst { vm.pageDidDisappear() }
        vm.pageDidAppear()
        await waitUntil { sync.refetches.count > 4 || vm.detailDrainWaitCount >= 2 }
        XCTAssertEqual(sync.refetches.count, 4, "nothing new dispatched while the page's batch still runs",
                       file: file, line: line)
        // Keep the gate on and answer requests one round at a time, so every
        // overlap is visible to `maxInFlight`, until refresh() has finished.
        await releaseUntil { !vm.isRefreshing }
        await refreshTask.value
        XCTAssertEqual(sync.maxInFlight, 4, "no combination of page-appear and refresh may exceed the cap",
                       file: file, line: line)
        XCTAssertEqual(Set(sync.refetches.dropFirst(4)), Set((1...6).map { "ms_\($0)" }),
                       "refresh still refreshed every open mission", file: file, line: line)
        // Nothing is left running now, so a disappear finds no orphan still
        // quietly requesting more ids.
        await releaseUntil { sync.inFlight == 0 }
        vm.pageDidDisappear()
        let afterDisappear = sync.refetches.count
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.refetches.count, afterDisappear, "no orphaned fan-out keeps requesting ids",
                       file: file, line: line)
    }

    /// A mission arriving while a re-appear's batch is parked on a retired
    /// batch's drain: the catch-up pass queues behind both, so the cap holds
    /// and the new mission is still fetched, exactly once.
    func testACatchUpDuringARetiredBatchsDrainNeverExceedsFourInFlight() async {
        makeVM()
        sync.gateDetails = true
        sync.ignoresCancellation = true
        vm.start()
        store.missions.yield((1...6).map { mission("ms_\($0)", num: $0) })
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.waiting == 4 }
        vm.pageDidDisappear()
        vm.pageDidAppear()
        await waitUntil { sync.refetches.count > 4 || vm.detailDrainWaitCount >= 1 }
        store.missions.yield((1...7).map { mission("ms_\($0)", num: $0) })
        await waitUntil { vm.cards.count == 7 }
        XCTAssertEqual(sync.refetches.count, 4, "nothing new dispatched while the retired batch still runs")
        await releaseUntil { sync.refetches.contains("ms_7") && sync.inFlight == 0 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.maxInFlight, 4, "the catch-up never overlapped the retired batch or the new one")
        XCTAssertEqual(sync.refetches.filter { $0 == "ms_7" }.count, 1, "the new mission was fetched once")
    }

    func testASecondRefreshWhileOneRunsIsANoOp() async {
        makeVM()
        sync.gateDetails = true
        vm.start()
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { !vm.cards.isEmpty }
        // `start()` already ran its own automatic list refresh; baseline
        // after it settles so only `first`'s and the no-op's contributions
        // are measured below.
        await waitUntil { sync.refreshes >= 1 }
        let refreshesBaseline = sync.refreshes
        let rosterBaseline = roster.calls
        let first = Task { await vm.refresh() }
        await waitUntil { sync.inFlight >= 1 }
        XCTAssertTrue(vm.isRefreshing)
        await vm.refresh()
        XCTAssertEqual(sync.refreshes, refreshesBaseline + 1, "the second call made no additional list refresh")
        XCTAssertEqual(roster.calls, rosterBaseline + 1, "the second call made no additional roster fetch")
        sync.gateDetails = false
        sync.releaseWaiting()
        await first.value
    }

    /// Review Focus (fix round 2): `refresh()` before the first missions
    /// snapshot used to unconditionally clear `detailFanOutPending` and fan
    /// out over an empty list — silently dropping the page's own deferred
    /// fan-out for whenever missions eventually did land.
    func testRefreshBeforeMissionsLoadDoesNotClearThePendingFanOutFlagOrFanOutEmpty() async {
        makeVM()
        vm.start()
        vm.pageDidAppear()
        await vm.refresh()
        XCTAssertTrue(sync.refetches.isEmpty, "nothing to fan out over before the first missions snapshot")
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { sync.refetches.contains("ms_1") }
    }

    // MARK: Page-appear throttle (spec §3.7: skip a re-appear within 60s
    // of the last completed detail fan-out; an explicit refresh() never
    // skips).

    func testPageDidAppearSkipsTheDetailRefreshWithinSixtySecondsOfTheLastCompletedOne() async {
        let clock = MutableClock(now)
        makeVM(clock: clock)
        vm.start()
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.refetches.contains("ms_1") }
        // The throttle's clock only starts on a genuine completion, not
        // merely a dispatch — wait for that stamp itself.
        await waitUntil { vm.lastDetailFanOutCompletedAt != nil }
        vm.pageDidDisappear()
        let afterFirst = sync.refetches.count

        clock.advance(by: 30)
        vm.pageDidAppear()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.refetches.count, afterFirst,
                       "a fan-out that completed 30s ago is still fresh enough to skip")
        vm.pageDidDisappear()

        clock.advance(by: 31) // 61s since the last completion
        vm.pageDidAppear()
        await waitUntil { sync.refetches.count == afterFirst + 1 }
    }

    func testExplicitRefreshAlwaysRunsTheDetailFanOutRegardlessOfTheThrottle() async {
        let clock = MutableClock(now)
        makeVM(clock: clock)
        vm.start()
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { vm.lastDetailFanOutCompletedAt != nil }
        vm.pageDidDisappear()
        let afterFirst = sync.refetches.count

        clock.advance(by: 5) // well inside the 60s throttle window
        let armedAt = vm.lastDetailFanOutCompletedAt
        XCTAssertEqual(armedAt, now, "the throttle is armed by the completed fan-out")
        XCTAssertLessThan(clock.now.timeIntervalSince(armedAt ?? .distantPast),
                          MissionsDashboardViewModel.detailFanOutThrottle,
                          "a page-appear now would be skipped — so refresh() must bypass it")
        await vm.refresh()
        XCTAssertEqual(sync.refetches.count, afterFirst + 1, "an explicit refresh always runs the detail fan-out")
    }

    // MARK: Detail refresh follows the missions that arrive (PR 265 Bugbot)

    /// GRDB delivers the current snapshot at once, and after sign-in or a
    /// wipe that snapshot is EMPTY. A fan-out over nothing must not count
    /// as done: the real missions arriving next still get their details.
    func testAnEmptyFirstSnapshotThenRealMissionsStillRefreshesTheirDetails() async {
        let clock = MutableClock(now)
        makeVM(clock: clock)
        vm.start()
        vm.pageDidAppear()
        store.missions.yield([])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(sync.refetches.isEmpty)
        clock.advance(by: 5)
        store.missions.yield([mission("ms_1", num: 1), mission("ms_2", num: 2)])
        await waitUntil { Set(sync.refetches) == ["ms_1", "ms_2"] }
    }

    /// A mission that appears while the page shows is fetched even inside
    /// the 60 s throttle window, and so is one that arrived while hidden
    /// when the page shows again; the already-refreshed ones are not.
    func testANewMissionIsRefreshedEvenWithinTheThrottleWindow() async {
        let clock = MutableClock(now)
        makeVM(clock: clock)
        vm.start()
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.refetches == ["ms_1"] }
        try? await Task.sleep(nanoseconds: 50_000_000)

        clock.advance(by: 5)
        store.missions.yield([mission("ms_1", num: 1), mission("ms_2", num: 2)])
        await waitUntil { sync.refetches.contains("ms_2") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.refetches, ["ms_1", "ms_2"], "only the new mission was fetched")

        vm.pageDidDisappear()
        store.missions.yield([mission("ms_1", num: 1), mission("ms_2", num: 2), mission("ms_3", num: 3)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.refetches.count, 2, "no fetch while the page is hidden")
        clock.advance(by: 5)
        vm.pageDidAppear()
        await waitUntil { sync.refetches.contains("ms_3") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.refetches, ["ms_1", "ms_2", "ms_3"], "the re-appear fetched only the missing one")
    }

    /// The throttle still suppresses a repeat pass when nothing is new —
    /// a missions emission for already-refreshed missions, or a re-appear.
    func testTheThrottleStillSkipsARepeatPassWhenNothingIsNew() async {
        let clock = MutableClock(now)
        makeVM(clock: clock)
        vm.start()
        store.missions.yield([mission("ms_1", num: 1)])
        await waitUntil { !vm.cards.isEmpty }
        vm.pageDidAppear()
        await waitUntil { sync.refetches == ["ms_1"] }
        try? await Task.sleep(nanoseconds: 50_000_000)

        clock.advance(by: 5)
        store.missions.yield([mission("ms_1", num: 1, statusUpdatedAt: now)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.pageDidDisappear()
        vm.pageDidAppear()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sync.refetches, ["ms_1"], "nothing new, so no repeat pass")
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
