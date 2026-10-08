import XCTest
import MatronChat
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Plays the journal's briefings routes: `GET` answers `stored`; a `POST`
/// that is not told to fail marks a refresh pending, as the journal does,
/// and answers the new state.
private final class FakeBriefingsAPI: BriefingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: LatestBriefing
    private var _getError: Error?
    private var _postError: Error?
    private var _gets = 0
    private var _posts = 0
    private var _postDelay: Duration?
    private let askedAt: Date

    init(stored: LatestBriefing, askedAt: Date) {
        _stored = stored
        self.askedAt = askedAt
    }

    var stored: LatestBriefing { get { lock.withLock { _stored } } set { lock.withLock { _stored = newValue } } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }
    var postError: Error? { get { lock.withLock { _postError } } set { lock.withLock { _postError = newValue } } }
    var gets: Int { lock.withLock { _gets } }
    var posts: Int { lock.withLock { _posts } }
    /// Holds the `POST`'s answer this long after taking its snapshot, so a
    /// `GET` can overtake it.
    var postDelay: Duration? { get { lock.withLock { _postDelay } } set { lock.withLock { _postDelay = newValue } } }

    func latestBriefing() async throws -> LatestBriefing {
        lock.withLock { _gets += 1 }
        if let getError { throw getError }
        return stored
    }

    func refreshBriefing() async throws -> LatestBriefing {
        lock.withLock { _posts += 1 }
        if let postError { throw postError }
        let answer = lock.withLock {
            let expires = askedAt.addingTimeInterval(600)
            _stored = LatestBriefing(briefing: _stored.briefing,
                                     refresh: BriefingRefresh(requestedAt: askedAt, state: .pending, expiresAt: expires),
                                     nextRefreshAt: expires, hasCoordinator: _stored.hasCoordinator)
            return _stored
        }
        if let postDelay { try? await Task.sleep(for: postDelay) }
        return answer
    }
}

private final class BriefingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
}

@MainActor
final class LatestBriefingStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var frames: (stream: AsyncStream<BriefingSignal>, continuation: AsyncStream<BriefingSignal>.Continuation)!
    private var states: (stream: AsyncStream<SyncConnectionState>, continuation: AsyncStream<SyncConnectionState>.Continuation)!

    override func setUp() async throws {
        frames = AsyncStream.makeStream()
        states = AsyncStream.makeStream()
    }

    private func briefing(_ id: String = "br_1", body: String = "## Sweep\nAll quiet.", at: Date? = nil) -> Briefing {
        Briefing(id: id, body: body, createdAt: at ?? t0.addingTimeInterval(-300), convoID: "c-coord", seq: 42)
    }

    private func latest(_ briefing: Briefing?, refresh: BriefingRefresh? = nil, nextRefreshAt: Date? = nil,
                        hasCoordinator: Bool = true) -> LatestBriefing {
        LatestBriefing(briefing: briefing, refresh: refresh, nextRefreshAt: nextRefreshAt, hasCoordinator: hasCoordinator)
    }

    private func makeStore(_ api: FakeBriefingsAPI, now: (@Sendable () -> Date)? = nil,
                           expiryGrace: TimeInterval = 2) -> LatestBriefingStore {
        let clock = BriefingClock(t0)
        let fixed: @Sendable () -> Date = { clock.now }
        let frameStream = frames.stream
        let stateStream = states.stream
        return LatestBriefingStore(api: api, updates: { frameStream }, connectionStates: { stateStream },
                                   now: now ?? fixed, expiryGrace: expiryGrace)
    }

    /// Spins the main actor until `condition` holds (live streams deliver on
    /// their own tasks).
    private func eventually(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out: \(message)")
    }

    func testRunningConnectionReadsTheLatest() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        let store = makeStore(api)
        store.start()
        XCTAssertNil(store.cardModel, "no card before the journal answers")
        states.continuation.yield(.connecting)
        states.continuation.yield(.running)
        await eventually("GET on running") { store.cardModel != nil }
        XCTAssertEqual(store.cardModel, BriefingCardModel(createdAt: t0.addingTimeInterval(-300),
                                                          body: "## Sweep\nAll quiet.", state: .idle, canRefresh: true))
        XCTAssertEqual(store.isSupported, true)
        XCTAssertEqual(store.briefing?.seq, 42)
        store.stop()
    }

    func testOldJournalHidesTheCard() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        api.getError = BriefingsError.unsupported
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.isSupported, false)
        XCTAssertNil(store.cardModel)
    }

    func testNoCoordinatorHidesTheCard() async {
        let api = FakeBriefingsAPI(stored: latest(nil, hasCoordinator: false), askedAt: t0)
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.isSupported, true)
        XCTAssertNil(store.cardModel)
    }

    func testNoBriefingYetStillShowsTheCard() async {
        let api = FakeBriefingsAPI(stored: latest(nil), askedAt: t0)
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.cardModel?.hasBriefing, false)
        XCTAssertEqual(store.cardModel?.canRefresh, true)
    }

    func testABriefingFrameRefetches() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.stored = latest(briefing("br_2", body: "Newer", at: t0))
        frames.continuation.yield(BriefingSignal(action: BriefingSignal.published, briefingID: "br_2"))
        await eventually("refetch on the frame") { store.briefing?.id == "br_2" }
        XCTAssertEqual(store.cardModel?.body, "Newer")
        store.stop()
    }

    func testPendingRefreshShowsRefreshingWithTheButtonOff() async {
        let refresh = BriefingRefresh(requestedAt: t0.addingTimeInterval(-60), state: .pending,
                                      expiresAt: t0.addingTimeInterval(540))
        let api = FakeBriefingsAPI(stored: latest(briefing(), refresh: refresh, nextRefreshAt: refresh.expiresAt),
                                   askedAt: t0)
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.cardModel?.state, .refreshing)
        XCTAssertEqual(store.cardModel?.canRefresh, false)
        await store.requestRefresh()
        XCTAssertEqual(api.posts, 0, "no second ask while one is pending")
        store.stop()
    }

    func testFailedAndTimedOutOfferARetry() async {
        for state in [BriefingRefresh.State.failed, .timedOut] {
            let refresh = BriefingRefresh(requestedAt: t0.addingTimeInterval(-900), state: state)
            let api = FakeBriefingsAPI(stored: latest(briefing(), refresh: refresh), askedAt: t0)
            let store = makeStore(api)
            await store.refresh()
            XCTAssertEqual(store.cardModel?.state, .failed, "\(state)")
            XCTAssertEqual(store.cardModel?.canRefresh, true, "\(state)")
        }
    }

    func testAskingPostsOnceAndShowsThePendingRefresh() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        let store = makeStore(api)
        await store.refresh()
        await store.requestRefresh()
        XCTAssertEqual(api.posts, 1)
        XCTAssertEqual(store.cardModel?.state, .refreshing)
        XCTAssertEqual(store.cardModel?.canRefresh, false)
        XCTAssertFalse(store.isAsking)
        await store.requestRefresh()
        XCTAssertEqual(api.posts, 1, "a double tap asks once")
        store.stop()
    }

    func testRateLimitedCoolsTheButtonDown() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        api.postError = BriefingsError.rateLimited(retryAt: t0.addingTimeInterval(90))
        let store = makeStore(api)
        await store.refresh()
        let getsBefore = api.gets
        await store.requestRefresh()
        XCTAssertEqual(store.cooldownUntil, t0.addingTimeInterval(90))
        XCTAssertEqual(store.cardModel?.state, .idle)
        XCTAssertEqual(store.cardModel?.canRefresh, false)
        XCTAssertNil(store.cardModel?.notice, "a cooldown is not an error")
        XCTAssertEqual(api.gets, getsBefore + 1, "re-reads the journal's view after a refused ask")
        store.stop()
    }

    func testBusyLeavesANotice() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        api.postError = BriefingsError.busy
        let store = makeStore(api)
        await store.refresh()
        await store.requestRefresh()
        XCTAssertEqual(store.cardModel?.notice, BriefingsError.busy.localizedDescription)
        XCTAssertEqual(store.cardModel?.canRefresh, true, "busy is worth another try")
        api.postError = nil
        await store.requestRefresh()
        XCTAssertNil(store.cardModel?.notice, "the next ask clears it")
        store.stop()
    }

    func testTheCooldownEndsOnItsOwn() async {
        let start = Date()
        let api = FakeBriefingsAPI(stored: latest(briefing(at: start), nextRefreshAt: start.addingTimeInterval(0.2)),
                                   askedAt: start)
        let store = makeStore(api, now: { Date() })
        await store.refresh()
        XCTAssertEqual(store.cardModel?.canRefresh, false)
        await eventually("the button comes back once the cooldown passes") { store.cardModel?.canRefresh == true }
        store.stop()
    }

    func testAPendingRefreshPastItsExpiryIsReRead() async {
        let start = Date()
        let refresh = BriefingRefresh(requestedAt: start, state: .pending, expiresAt: start.addingTimeInterval(0.2))
        let api = FakeBriefingsAPI(stored: latest(briefing(at: start), refresh: refresh), askedAt: start)
        let store = makeStore(api, now: { Date() }, expiryGrace: 0)
        await store.refresh()
        XCTAssertEqual(store.cardModel?.state, .refreshing)
        api.stored = latest(briefing(at: start), refresh: BriefingRefresh(requestedAt: start, state: .timedOut))
        await eventually("re-read at expiry shows the timeout") { store.cardModel?.state == .failed }
        store.stop()
    }

    /// Bugbot: the Coordinator publishes while the ask is in flight, and
    /// the `published` frame's re-read lands first. The ask's older `202`
    /// must not put the previous briefing and "Refreshing…" back.
    func testAnAsksLateAnswerDoesNotOverwriteANewerRead() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        let store = makeStore(api)
        await store.refresh()
        api.postDelay = .milliseconds(200)
        let ask = Task { await store.requestRefresh() }
        await eventually("the POST went out") { api.posts == 1 }
        api.stored = latest(briefing("br_2", body: "## New sweep"))
        await store.refresh()
        XCTAssertEqual(store.briefing?.id, "br_2")
        await ask.value
        XCTAssertEqual(store.briefing?.id, "br_2", "the older 202 is dropped")
        XCTAssertEqual(store.cardModel?.state, .idle)
        store.stop()
    }

    /// With nothing newer read meanwhile, the ask's own `202` is what shows.
    func testAnAsksAnswerAppliesWhenNothingNewerLanded() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        let store = makeStore(api)
        await store.refresh()
        api.postDelay = .milliseconds(200)
        let ask = Task { await store.requestRefresh() }
        await eventually("the POST went out") { api.posts == 1 }
        await ask.value
        XCTAssertEqual(store.cardModel?.state, .refreshing, "with nothing newer, the 202 applies")
        store.stop()
    }

    func testStopDropsAReadStillInFlight() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        let store = makeStore(api)
        store.start()
        store.stop()
        states.continuation.yield(.running)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(store.latest, "a stopped store reads nothing")
    }

    // MARK: - Projects home

    func testTheProjectsHomeAppearingReReadsTheBriefing() async {
        let api = FakeBriefingsAPI(stored: latest(briefing()), askedAt: t0)
        let store = makeStore(api)
        let vm = MissionsDashboardViewModel(
            store: FakeDashboardStoreForProjects(), sync: FakeMissionsSyncForProjects(),
            summaries: { AsyncThrowingStream { $0.yield([]) } },
            roster: { RosterSnapshot() }, send: { _, _ in },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            briefing: store)
        vm.pageDidAppear()
        await eventually("GET on appear") { api.gets == 1 }
        XCTAssertNotNil(vm.briefing?.cardModel)
        vm.pageDidDisappear()

        // Not again on a journal that already answered 404.
        api.getError = BriefingsError.unsupported
        await store.refresh()
        let getsBefore = api.gets
        vm.pageDidAppear()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(api.gets, getsBefore)
        vm.pageDidDisappear()
    }
}
