import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

private final class FakeMissions: MissionsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [Mission] = []
    private var _listCalls = 0
    private var _listError: Error?
    private var _details: [String: MissionDetail] = [:]
    private var _detailCalls: [String] = []
    private var _closed: [(String, String)] = []
    /// Holds the NEXT `mission(id:)` open so a test can prove a second,
    /// coalesced refetch joins the first instead of issuing its own GET.
    private var _blockNextDetail = false
    private var _detailGate: CheckedContinuation<Void, Never>?

    var list: [Mission] { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var listError: Error? { get { lock.withLock { _listError } } set { lock.withLock { _listError = newValue } } }
    var details: [String: MissionDetail] { get { lock.withLock { _details } } set { lock.withLock { _details = newValue } } }
    var detailCalls: [String] { lock.withLock { _detailCalls } }
    var closed: [(String, String)] { lock.withLock { _closed } }
    var blockNextDetail: Bool { get { lock.withLock { _blockNextDetail } } set { lock.withLock { _blockNextDetail = newValue } } }
    var isDetailGated: Bool { lock.withLock { _detailGate != nil } }
    func releaseDetailGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _detailGate = nil }; return _detailGate }
        c?.resume()
    }

    func listMissions(_ query: MissionsListQuery) async throws -> [Mission] {
        lock.withLock { _listCalls += 1 }
        if let e = listError { throw e }
        return list
    }

    func mission(id: String) async throws -> MissionDetail {
        lock.withLock { _detailCalls.append(id) }
        if blockNextDetail {
            blockNextDetail = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { _detailGate = c } }
        }
        guard let d = details[id] else { throw JournalAPIError.notFound }
        return d
    }

    func milestones(convoID: String) async throws -> [Milestone] { [] }

    func closeMission(id: String, summary: String) async throws -> Mission {
        lock.withLock { _closed.append((id, summary)) }
        guard let m = details[id]?.mission else { throw JournalAPIError.notFound }
        return Mission(id: m.id, num: m.num, state: .closed, title: m.title, body: m.body,
                       closeSummary: summary, closedBy: .user, closedOverOpenItems: 1,
                       originConvoID: m.originConvoID, createdAt: m.createdAt, updatedAt: m.updatedAt,
                       closedAt: Date(timeIntervalSince1970: 99))
    }
}

final class MissionsSyncTests: XCTestCase {
    private func mission(_ id: String, num: Int) -> Mission {
        Mission(id: id, num: num, title: "M\(num)", originConvoID: "c1",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: Date(timeIntervalSince1970: 3))
    }

    private func make(api: FakeMissions) throws -> (MissionsSync, JournalStore,
                                                    AsyncStream<(convoID: String, marker: MissionMarker)>.Continuation,
                                                    AsyncStream<SyncConnectionState>.Continuation) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let (markers, mc) = AsyncStream<(convoID: String, marker: MissionMarker)>.makeStream()
        let (states, sc) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = MissionsSync(api: api, store: store, markers: { markers }, connectionStates: { states })
        return (sync, store, mc, sc)
    }

    func testReconnectFetchesTheWholeListIntoTheStore() async throws {
        let api = FakeMissions()
        api.list = [mission("ms_1", num: 61), mission("ms_2", num: 62)]
        let (sync, store, _, states) = try make(api: api)
        await sync.start()
        states.yield(.running)
        try await waitUntil { try store.missions(state: nil).count == 2 }
        XCTAssertEqual(try store.missions(state: nil).map(\.id).sorted(), ["ms_1", "ms_2"])
        await sync.stop()
    }

    func testMarkerForAMissionRefetchesThatMissionOnly() async throws {
        let api = FakeMissions()
        api.details = ["ms_1": MissionDetail(
            mission: mission("ms_1", num: 61),
            milestones: [Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .userInput, title: "step",
                                   convoID: "c1", seq: 400, createdAt: Date(timeIntervalSince1970: 4))],
            items: [], conversations: [MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running")])]
        let (sync, store, markers, _) = try make(api: api)
        await sync.start()
        markers.yield((convoID: "c1", marker: .milestone(MilestoneMarkerEvent(
            milestoneID: "ml_1", num: 62, kind: .userInput, title: "step",
            missionID: "ms_1", missionNum: 61, missionTitle: nil, by: .agent))))
        try await waitUntil { try store.mission(id: "ms_1") != nil }
        XCTAssertEqual(api.detailCalls, ["ms_1"])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.seq), [400])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1").map(\.id), ["c1"])
        // The marker carried NO mission_title — the store still learned the
        // real title, because it came from the fetch, not the marker.
        XCTAssertEqual(try store.mission(id: "ms_1")?.title, "M61")
        await sync.stop()
    }

    /// Mirrors `ItemsSyncTests.testCoalescedRefreshItemAwaitsTheInFlightRun`:
    /// a joiner does not issue its own concurrent GET, but the in-flight run
    /// repeats once more for it before returning — so the joiner's await
    /// really does mean "the store now holds a page fetched after my call
    /// landed," at the cost of one extra request rather than a stale read.
    func testConcurrentRefetchesForOneMissionCoalesceIntoOneRepeatedRequest() async throws {
        let api = FakeMissions()
        api.details = ["ms_1": MissionDetail(mission: mission("ms_1", num: 61), milestones: [], items: [], conversations: [])]
        let (sync, _, _, _) = try make(api: api)
        api.blockNextDetail = true
        async let first = sync.refreshMission(id: "ms_1")
        try await waitUntil { api.isDetailGated }
        async let second = sync.refreshMission(id: "ms_1")
        api.releaseDetailGate()
        _ = await (first, second)
        XCTAssertEqual(api.detailCalls.filter { $0 == "ms_1" }.count, 2,
                       "the in-flight run repeats once for the coalesced joiner rather than issuing a separate concurrent GET")
        await sync.stop()
    }

    func testA404MarksTheJournalUnsupportedAndPublishesIt() async throws {
        let api = FakeMissions()
        api.listError = JournalAPIError.notFound
        let (sync, _, _, _) = try make(api: api)
        var seen: [Bool] = []
        let stream = await sync.supportedStream()
        let watcher = Task { for await v in stream { seen.append(v); if seen.count == 2 { return } } }
        let outcome = await sync.refresh()
        XCTAssertEqual(outcome, .unsupported)
        _ = await watcher.value
        XCTAssertEqual(seen, [true, false])
        await sync.stop()
    }

    /// A failed refresh must leave the cached tables exactly as they were —
    /// the mission list keeps showing what it had (spec, Error handling).
    func testAFailedRefreshKeepsTheCacheAndReportsTheFailure() async throws {
        let api = FakeMissions()
        api.list = [mission("ms_1", num: 61)]
        let (sync, store, _, _) = try make(api: api)
        let firstOutcome = await sync.refresh()
        XCTAssertEqual(firstOutcome, .succeeded)
        api.listError = JournalAPIError.transport("offline")
        guard case .failed = await sync.refresh() else { return XCTFail("expected .failed") }
        XCTAssertEqual(try store.missions(state: nil).map(\.id), ["ms_1"])
        await sync.stop()
    }

    func testCloseWritesTheReturnedMissionStraightIntoTheStore() async throws {
        let api = FakeMissions()
        api.details = ["ms_1": MissionDetail(mission: mission("ms_1", num: 61), milestones: [], items: [], conversations: [])]
        let (sync, store, _, _) = try make(api: api)
        try store.upsertMissions([mission("ms_1", num: 61)])
        let closed = try await sync.closeMission(id: "ms_1", summary: "Done.")
        XCTAssertEqual(closed.state, .closed)
        XCTAssertEqual(api.closed.map(\.1), ["Done."])
        XCTAssertEqual(try store.mission(id: "ms_1")?.state, .closed)
        XCTAssertEqual(try store.mission(id: "ms_1")?.closedOverOpenItems, 1)
        await sync.stop()
    }

    /// Polls a condition rather than sleeping a fixed interval.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
