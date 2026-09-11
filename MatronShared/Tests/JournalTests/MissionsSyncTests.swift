import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

private final class FakeMissions: MissionsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [Mission] = []
    private var _listDroppedIDs: [String] = []
    private var _listCalls = 0
    private var _listError: Error?
    private var _details: [String: MissionDetail] = [:]
    private var _detailCalls: [String] = []
    private var _closed: [(String, String)] = []
    /// Holds the NEXT `mission(id:)` open so a test can prove a second,
    /// coalesced refetch joins the first instead of issuing its own GET.
    private var _blockNextDetail = false
    private var _detailGate: CheckedContinuation<Void, Never>?
    /// Holds the NEXT `listMissions(_:)` open — fix round 2, H1: lets a
    /// test prove a detail refresh that completes WHILE a list GET is
    /// still in flight isn't clobbered by that (now stale) list response.
    private var _blockNextList = false
    private var _listGate: CheckedContinuation<Void, Never>?

    var list: [Mission] { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    /// Fix round 2, addendum: ids `listMissions` reports as locally
    /// undecodable on its NEXT call, so a test can prove they're
    /// protected from the authoritative replace's stale-id sweep.
    var listDroppedIDs: [String] { get { lock.withLock { _listDroppedIDs } } set { lock.withLock { _listDroppedIDs = newValue } } }
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
    var blockNextList: Bool { get { lock.withLock { _blockNextList } } set { lock.withLock { _blockNextList = newValue } } }
    var isListGated: Bool { lock.withLock { _listGate != nil } }
    func releaseListGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _listGate = nil }; return _listGate }
        c?.resume()
    }

    func listMissions(_ query: MissionsListQuery) async throws -> MissionsListDecode {
        lock.withLock { _listCalls += 1 }
        if blockNextList {
            blockNextList = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { _listGate = c } }
        }
        if let e = listError { throw e }
        return MissionsListDecode(missions: list, droppedIDs: listDroppedIDs)
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

    /// CodeRabbit #209 MAJOR: the full-list refresh IS authoritative — a
    /// mission the server stops returning must not linger, and neither
    /// must its cached milestones/conversations (no FK cascade on those
    /// tables — `JournalStore.replaceMissions`).
    func testReconnectDropsAMissionTheServerNoLongerReturns() async throws {
        let api = FakeMissions()
        api.list = [mission("ms_1", num: 61), mission("ms_2", num: 62)]
        let (sync, store, _, _) = try make(api: api)
        let firstOutcome = await sync.refresh()
        XCTAssertEqual(firstOutcome, .succeeded)
        try store.replaceMilestones(missionID: "ms_1", [
            Milestone(id: "ml_1", missionID: "ms_1", num: 1, kind: .userInput, title: "step",
                     convoID: "c1", seq: 400, createdAt: Date(timeIntervalSince1970: 4)),
        ])
        try store.replaceMissionConversations(missionID: "ms_1", [
            MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running"),
        ])
        // Fix round 2, L2: a tracker item pointed at "ms_1" must stop
        // naming it once the mission is gone from the cache.
        try store.upsertItems([
            TrackerItem(id: "it_1", num: 900, kind: .task, title: "carry", originConvoID: "c1",
                       missionID: "ms_1", missionNum: 61),
        ])
        api.list = [mission("ms_2", num: 62)]
        let secondOutcome = await sync.refresh()
        XCTAssertEqual(secondOutcome, .succeeded)
        XCTAssertEqual(try store.missions(state: nil).map(\.id), ["ms_2"])
        XCTAssertEqual(try store.milestones(missionID: "ms_1"), [])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1"), [])
        let survivingItem = try store.item(id: "it_1")
        XCTAssertNil(survivingItem?.missionID, "an item pointed at a deleted mission must be cleared, not left dangling")
        XCTAssertNil(survivingItem?.missionNum)
        await sync.stop()
    }

    /// CodeRabbit #209 fix round 2, H1: a list GET issued before a
    /// mission existed can still be in flight when a marker-driven
    /// detail refresh for that NEW mission completes FIRST — the (now
    /// stale) list response must not delete the mission the detail
    /// refresh just wrote.
    func testAConcurrentDetailRefreshSurvivesAStaleInFlightListRefresh() async throws {
        let api = FakeMissions()
        // The list response, once released, carries its OWN (stale) row
        // for "ms_2" too — not just an absent one — so this pins fix
        // round 3, N3: `keeping:` alone stops the row from being
        // DELETED, but the stale row was still upserted over whatever
        // the concurrent detail fetch just wrote, reverting its fields
        // until the next refresh. The fresh title must survive, not just
        // the row's existence.
        api.list = [
            mission("ms_1", num: 61),
            Mission(id: "ms_2", num: 62, title: "stale title from an earlier snapshot", originConvoID: "c1"),
        ]
        api.details = ["ms_2": MissionDetail(mission: mission("ms_2", num: 62), milestones: [], items: [], conversations: [])]
        let (sync, store, _, _) = try make(api: api)
        api.blockNextList = true
        let listTask = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        let detailOutcome = await sync.refreshMission(id: "ms_2")
        XCTAssertEqual(detailOutcome, .succeeded)
        XCTAssertEqual(try store.mission(id: "ms_2")?.title, "M62",
                       "the detail refresh must land before the stale list response is even released")
        api.releaseListGate()
        let listOutcome = await listTask.value
        XCTAssertEqual(listOutcome, .succeeded)
        XCTAssertEqual(try store.mission(id: "ms_2")?.title, "M62",
                       "the concurrent detail refresh's fields must survive the now-stale list response's upsert, not just the row's existence")
        await sync.stop()
    }

    /// CodeRabbit #209 fix round 2, addendum (Bugbot on #216): a mission
    /// this device merely failed to DECODE on the next list response —
    /// as opposed to one the server actually stopped returning — must
    /// survive the authoritative replace.
    func testAMissionDroppedByLocalDecodeFailureSurvivesTheReplace() async throws {
        let api = FakeMissions()
        api.list = [mission("ms_1", num: 61)]
        let (sync, store, _, _) = try make(api: api)
        let firstOutcome = await sync.refresh()
        XCTAssertEqual(firstOutcome, .succeeded)
        // "ms_2" is cached some other way (a prior detail refresh, say),
        // and the NEXT list response's row for it fails to decode.
        try store.upsertMissions([mission("ms_2", num: 62)])
        api.listDroppedIDs = ["ms_2"]
        let secondOutcome = await sync.refresh()
        XCTAssertEqual(secondOutcome, .succeeded)
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
        let first = Task { await sync.refreshMission(id: "ms_1") }
        try await waitUntil { api.isDetailGated }
        let joinsBefore = await sync.refetchJoins
        let second = Task { await sync.refreshMission(id: "ms_1") }
        // Deterministic joiner barrier (CodeRabbit #209 fix round 2, M1):
        // the earlier version released the gate right after spawning
        // `second`, timed a fixed sleep to give it a chance to (wrongly)
        // return, and only then checked the FINAL call count — on a
        // loaded machine, `second` might not even have been SCHEDULED
        // yet within that sleep, so the assertion could pass for the
        // wrong reason. Waiting on the actor's own `refetchJoins` counter
        // instead proves `second` actually reached the "already in
        // flight" branch and registered itself, with no timing guesswork.
        try await waitUntil { await sync.refetchJoins > joinsBefore }
        XCTAssertEqual(api.detailCalls.filter { $0 == "ms_1" }.count, 1,
                       "only one request may be active before the gate releases")
        api.releaseDetailGate()
        _ = await first.value
        _ = await second.value
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
        // Fix round 3, N5: pins L1's "a transport error is not a support
        // signal" — only `.notFound` (404) may flip `isSupported`.
        let s = await sync.isSupported
        XCTAssertTrue(s)
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

    /// Fix round 5 (Bugbot): `closeMission` upserted the returned row but
    /// never protected its id — an in-flight list GET issued before the
    /// close landed can still be holding the OLDER, still-open snapshot
    /// when it returns, reverting the just-closed row. Mirrors the H1
    /// race test, but for the close path instead of a detail refresh.
    func testCloseSurvivesAStaleInFlightListRefresh() async throws {
        let api = FakeMissions()
        api.details = ["ms_1": MissionDetail(mission: mission("ms_1", num: 61), milestones: [], items: [], conversations: [])]
        // Still "open" in the gated response — a snapshot taken before
        // the close landed.
        api.list = [mission("ms_1", num: 61)]
        let (sync, store, _, _) = try make(api: api)
        api.blockNextList = true
        let listTask = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        let closed = try await sync.closeMission(id: "ms_1", summary: "Done.")
        XCTAssertEqual(closed.state, .closed)
        XCTAssertEqual(try store.mission(id: "ms_1")?.state, .closed,
                       "the close must land before the stale list response is even released")
        api.releaseListGate()
        let listOutcome = await listTask.value
        XCTAssertEqual(listOutcome, .succeeded)
        XCTAssertEqual(try store.mission(id: "ms_1")?.state, .closed,
                       "the closed mission must survive the now-stale, still-open list response")
        await sync.stop()
    }

    /// Polls a condition rather than sleeping a fixed interval.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
