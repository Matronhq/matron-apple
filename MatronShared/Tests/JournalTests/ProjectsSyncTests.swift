import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

private final class FakeProjects: ProjectsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: [Project] = []
    private var _listError: Error?
    private var _listCalls = 0
    private var _details: [String: ProjectDetail] = [:]
    private var _links: [String: [ConversationMissionLink]] = [:]
    private var _linkCalls: [String] = []
    private var _created: [(String, String?, String)] = []
    private var _merged: [(String, String)] = []
    private var _filed: [(String, String?)] = []
    private var _listGate: CheckedContinuation<Void, Never>?
    private var _blockNextList = false
    private var _detailCalls: [String] = []
    private var _blockNextDetail = false
    private var _detailGate: CheckedContinuation<Void, Never>?
    private var _blockNextLinks = false
    private var _linksGate: CheckedContinuation<Void, Never>?
    private var _feedPages: [String: ProjectFeedSlice] = [:]
    private var _feedCalls: [(String, ProjectFeedKind, String?, Int?)] = []

    var list: [Project] { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    var listError: Error? { get { lock.withLock { _listError } } set { lock.withLock { _listError = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var details: [String: ProjectDetail] { get { lock.withLock { _details } } set { lock.withLock { _details = newValue } } }
    var links: [String: [ConversationMissionLink]] { get { lock.withLock { _links } } set { lock.withLock { _links = newValue } } }
    var linkCalls: [String] { lock.withLock { _linkCalls } }
    /// `projectFeed` answers, keyed by `before` ("" for the first page).
    var feedPages: [String: ProjectFeedSlice] { get { lock.withLock { _feedPages } } set { lock.withLock { _feedPages = newValue } } }
    var feedCalls: [(String, ProjectFeedKind, String?, Int?)] { lock.withLock { _feedCalls } }
    var created: [(String, String?, String)] { lock.withLock { _created } }
    var merged: [(String, String)] { lock.withLock { _merged } }
    var filed: [(String, String?)] { lock.withLock { _filed } }
    var blockNextList: Bool { get { lock.withLock { _blockNextList } } set { lock.withLock { _blockNextList = newValue } } }
    var isListGated: Bool { lock.withLock { _listGate != nil } }
    func releaseListGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _listGate = nil }; return _listGate }
        c?.resume()
    }
    /// Fix round 1: gates `project(id:)`, mirroring `FakeMissions`'s detail
    /// gate — proves a coalesced `refreshProject` joiner doesn't issue its
    /// own concurrent GET.
    var detailCalls: [String] { lock.withLock { _detailCalls } }
    var blockNextDetail: Bool { get { lock.withLock { _blockNextDetail } } set { lock.withLock { _blockNextDetail = newValue } } }
    var isDetailGated: Bool { lock.withLock { _detailGate != nil } }
    func releaseDetailGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _detailGate = nil }; return _detailGate }
        c?.resume()
    }

    /// PR 278 review: gates `conversationMissions(convoID:)`, so a test can
    /// hold a links fetch in the network across a `stop()`/`start()`.
    var blockNextLinks: Bool { get { lock.withLock { _blockNextLinks } } set { lock.withLock { _blockNextLinks = newValue } } }
    var isLinksGated: Bool { lock.withLock { _linksGate != nil } }
    func releaseLinksGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _linksGate = nil }; return _linksGate }
        c?.resume()
    }

    func listProjects() async throws -> ProjectsListDecode {
        lock.withLock { _listCalls += 1 }
        if blockNextList {
            blockNextList = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { _listGate = c } }
        }
        if let e = listError { throw e }
        return ProjectsListDecode(projects: list, droppedIDs: [])
    }
    func project(id: String) async throws -> ProjectDetail {
        let shouldGate = lock.withLock { () -> Bool in
            _detailCalls.append(id)
            guard _blockNextDetail else { return false }
            _blockNextDetail = false
            return true
        }
        if shouldGate {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { _detailGate = c } }
        }
        guard let d = details[id] else { throw JournalAPIError.notFound }
        return d
    }
    func createProject(title: String, body: String?, idempotencyKey: String) async throws -> Project {
        lock.withLock { _created.append((title, body, idempotencyKey)) }
        return Project(id: "pj_new", num: 9000, title: title, createdAt: Date(timeIntervalSince1970: 1),
                       updatedAt: Date(timeIntervalSince1970: 1))
    }
    func mergeProject(id: String, into: String) async throws { lock.withLock { _merged.append((id, into)) } }
    func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        lock.withLock { _filed.append((missionID, project)) }
        return Mission(id: missionID, num: 61, title: "M61", originConvoID: "c1",
                       createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 3),
                       projectID: project)
    }
    func conversationMissions(convoID: String) async throws -> [ConversationMissionLink] {
        let shouldGate = lock.withLock { () -> Bool in
            _linkCalls.append(convoID)
            guard _blockNextLinks else { return false }
            _blockNextLinks = false
            return true
        }
        if shouldGate {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { _linksGate = c } }
        }
        guard let l = links[convoID] else { throw JournalAPIError.notFound }
        return l
    }
    func projectFeed(id: String, kind: ProjectFeedKind, before: String?, limit: Int?) async throws -> ProjectFeedSlice {
        lock.withLock { _feedCalls.append((id, kind, before, limit)) }
        guard let page = feedPages[before ?? ""] else { throw JournalAPIError.notFound }
        return page
    }
}

/// Fix round 1 test infra: production's `JournalSyncEngine.missionMarkers()`
/// mints a FRESH `AsyncStream` (with its own registration) on every call —
/// so a `stop()`/`start()` cycle gets an independent stream, unaffected by
/// the old one. `ProjectsSyncTests.make(api:)` hands back the SAME captured
/// stream on every call instead, which is fine for every other test here
/// (none of them call `start()` twice) but wrong for a restart test: once
/// any consumer of a plain `AsyncStream` observes cancellation, the stream
/// itself finishes for ALL iterators, including ones created afterward —
/// so a second `start()` reusing that same stream would silently never see
/// another marker. This hub mints a new stream per `stream()` call and
/// yields into whichever one is current, matching the real engine.
private final class MarkerHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<(convoID: String, marker: MissionMarker)>.Continuation?
    func stream() -> AsyncStream<(convoID: String, marker: MissionMarker)> {
        let (s, c) = AsyncStream<(convoID: String, marker: MissionMarker)>.makeStream()
        lock.withLock { continuation = c }
        return s
    }
    func yield(_ value: (convoID: String, marker: MissionMarker)) {
        lock.withLock { continuation }?.yield(value)
    }
}

final class ProjectsSyncTests: XCTestCase {
    private func project(_ id: String, num: Int) -> Project {
        Project(id: id, num: num, title: "P\(num)", createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2))
    }

    private func make(api: FakeProjects) throws -> (ProjectsSync, JournalStore,
                                                     AsyncStream<(convoID: String, marker: MissionMarker)>.Continuation,
                                                     AsyncStream<SyncConnectionState>.Continuation) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let (markers, mc) = AsyncStream<(convoID: String, marker: MissionMarker)>.makeStream()
        let (states, sc) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = ProjectsSync(api: api, store: store, markers: { markers }, connectionStates: { states })
        return (sync, store, mc, sc)
    }

    private func marker(_ missionID: String = "ms_1") -> MissionMarker {
        .mission(MissionMarkerEvent(missionID: missionID, num: 61, action: .joined))
    }

    /// Fix round 1: accepts an `async` condition too (a plain, non-async
    /// closure still satisfies this), so a test can poll an actor property
    /// (`await sync.stopped`, `await sync.detailJoins`) instead of
    /// sleeping a fixed interval and hoping the actor got there in time.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testReconnectFetchesTheListIntoTheStore() async throws {
        let api = FakeProjects()
        api.list = [project("pj_1", num: 1), project("pj_2", num: 2)]
        let (sync, store, _, states) = try make(api: api)
        await sync.start()
        states.yield(.running)
        try await waitUntil { try store.projects().count == 2 }
        await sync.stop()
    }

    /// Review Focus: an old journal answers 404 — unsupported, not an error.
    func testListNotFoundIsUnsupported() async throws {
        let api = FakeProjects()
        api.listError = JournalAPIError.notFound
        let (sync, _, _, _) = try make(api: api)
        var supported = await sync.supportedStream().makeAsyncIterator()
        let initial = await supported.next()
        XCTAssertEqual(initial, true, "optimistic until proven")
        let outcome = await sync.refresh()
        XCTAssertEqual(outcome, .unsupported)
        let updated = await supported.next()
        XCTAssertEqual(updated, false)
    }

    /// R1 (preflight): `ProjectDetail` carries no `needsYou` — the journal's
    /// project-detail rows are slim and would clobber the fully-synced item
    /// cache. Only the project, its missions and its milestones land.
    func testRefreshProjectWritesEveryPart() async throws {
        let api = FakeProjects()
        let mission = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1", projectID: "pj_1")
        api.details["pj_1"] = ProjectDetail(
            project: project("pj_1", num: 1), missions: [mission],
            recentMilestones: [Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress, title: "s",
                                         convoID: "c1", seq: 1)],
            sessionsByBox: ["greg": 2])
        let (sync, store, _, _) = try make(api: api)
        let outcome = await sync.refreshProject(id: "pj_1")
        XCTAssertEqual(outcome, .loaded(projectID: "pj_1"))
        XCTAssertNotNil(try store.project(id: "pj_1"))
        XCTAssertEqual(try store.mission(id: "ms_1")?.projectID, "pj_1")
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.id), ["ml_1"])
    }

    /// Projects view v2: the detail's first feed pages land in
    /// `feed_json`, and its milestone rows in the milestone cache.
    func testRefreshProjectWritesTheFeedAndItsMilestones() async throws {
        let api = FakeProjects()
        api.details["pj_1"] = ProjectDetail(project: project("pj_1", num: 1), missions: [], recentMilestones: [],
                                            sessionsByBox: [:], feed: JournalStoreProjectsTests.feed)
        let (sync, store, _, _) = try make(api: api)
        _ = await sync.refreshProject(id: "pj_1")
        var feeds = store.projectFeedStream(id: "pj_1").makeAsyncIterator()
        let feed = await feeds.next()
        XCTAssertEqual(feed, .some(JournalStoreProjectsTests.feed))
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.id), ["ml_1"])
    }

    /// The case the brief singles out, end to end: a list refresh writes
    /// the card, then a detail refresh (whose project has no card fields)
    /// must leave it — and a later list refresh must leave the feed.
    func testListAndDetailRefreshesKeepEachOthersColumns() async throws {
        let api = FakeProjects()
        api.list = [JournalStoreProjectsTests.withCard(project("pj_1", num: 1), JournalStoreProjectsTests.card)]
        api.details["pj_1"] = ProjectDetail(project: project("pj_1", num: 1), missions: [], recentMilestones: [],
                                            sessionsByBox: ["greg": 1], feed: JournalStoreProjectsTests.feed)
        let (sync, store, _, _) = try make(api: api)
        _ = await sync.refresh()
        _ = await sync.refreshProject(id: "pj_1")
        XCTAssertEqual(try store.project(id: "pj_1")?.card, JournalStoreProjectsTests.card)
        _ = await sync.refresh()
        var feeds = store.projectFeedStream(id: "pj_1").makeAsyncIterator()
        let feed = await feeds.next()
        XCTAssertEqual(feed, .some(JournalStoreProjectsTests.feed))
        XCTAssertEqual(try store.project(id: "pj_1")?.card, JournalStoreProjectsTests.card)
    }

    /// An older journal's detail has no feed: nothing is written, and a
    /// feed cached earlier is left as it was.
    func testADetailWithoutAFeedWritesNone() async throws {
        let api = FakeProjects()
        api.details["pj_1"] = ProjectDetail(project: project("pj_1", num: 1), missions: [], recentMilestones: [],
                                            sessionsByBox: [:])
        let (sync, store, _, _) = try make(api: api)
        _ = await sync.refreshProject(id: "pj_1")
        var feeds = store.projectFeedStream(id: "pj_1").makeAsyncIterator()
        let feed = await feeds.next()
        XCTAssertEqual(feed, .some(nil))
    }

    func testProjectFeedPassesStraightThroughAndWritesNothing() async throws {
        let api = FakeProjects()
        let page = ProjectFeedPage<ProjectMilestone>(total: 9, rows: JournalStoreProjectsTests.feed.milestones.rows,
                                                     nextBefore: nil)
        api.feedPages["cur"] = .milestones(page)
        let (sync, store, _, _) = try make(api: api)
        let slice = try await sync.projectFeed(id: "pj_1", kind: .milestones, before: "cur", limit: 50)
        XCTAssertEqual(slice, .milestones(page))
        XCTAssertEqual(api.feedCalls.first?.0, "pj_1")
        XCTAssertEqual(api.feedCalls.first?.1, .milestones)
        XCTAssertEqual(api.feedCalls.first?.2, "cur")
        XCTAssertEqual(api.feedCalls.first?.3, 50)
        XCTAssertEqual(try store.milestones(missionID: "ms_1"), [], "pages past the first stay in memory")
    }

    /// A merged project's detail answers with the target (spec §4.2).
    func testRefreshingAMergedProjectReportsTheTarget() async throws {
        let api = FakeProjects()
        api.details["pj_old"] = ProjectDetail(project: project("pj_new", num: 2), missions: [],
                                              recentMilestones: [], sessionsByBox: [:])
        let (sync, _, _, _) = try make(api: api)
        let outcome = await sync.refreshProject(id: "pj_old")
        XCTAssertEqual(outcome, .loaded(projectID: "pj_new"))
        let missing = await sync.refreshProject(id: "pj_gone")
        XCTAssertEqual(missing, .notFound)
    }

    /// A catch-up replay floods markers: the list refresh coalesces, and an
    /// unwatched conversation's links are never fetched.
    func testAMarkerFloodCostsAtMostTwoListFetchesAndNoLinkFetches() async throws {
        let api = FakeProjects()
        api.blockNextList = true
        let (sync, _, markers, _) = try make(api: api)
        await sync.start()
        markers.yield((convoID: "c-unwatched", marker: marker()))
        try await waitUntil { api.isListGated }
        for _ in 0..<50 { markers.yield((convoID: "c-unwatched", marker: marker())) }
        try await Task.sleep(for: .milliseconds(100))
        api.releaseListGate()
        try await waitUntil { api.listCalls == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.listCalls, 2)
        XCTAssertEqual(api.linkCalls, [])
        await sync.stop()
    }

    func testAWatchedConversationRefetchesItsLinksOnOpenAndOnAMarker() async throws {
        let api = FakeProjects()
        let m = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1")
        api.links["c1"] = [ConversationMissionLink(mission: m, isCurrent: true, joinedAt: Date(timeIntervalSince1970: 1))]
        let (sync, store, markers, _) = try make(api: api)
        await sync.start()
        await sync.beginWatching(convoID: "c1")
        try await waitUntil { try store.conversationMissions(convoID: "c1").sections.current?.id == "ms_1" }
        markers.yield((convoID: "c1", marker: marker()))
        try await waitUntil { api.linkCalls.count == 2 }
        await sync.endWatching(convoID: "c1")
        markers.yield((convoID: "c1", marker: marker()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.linkCalls.count, 2, "no longer watched")
        await sync.stop()
    }

    func testWritesLandInTheStore() async throws {
        let api = FakeProjects()
        let (sync, store, _, _) = try make(api: api)
        let created = try await sync.createProject(title: "Promo", body: nil)
        XCTAssertEqual(created.id, "pj_new")
        XCTAssertEqual(try store.project(id: "pj_new")?.title, "Promo")
        XCTAssertFalse(api.created[0].2.isEmpty, "an idempotency key is always sent")
        let filed = try await sync.setMissionProject(missionID: "ms_1", project: "pj_new")
        XCTAssertEqual(filed.projectID, "pj_new")
        XCTAssertEqual(try store.mission(id: "ms_1")?.projectID, "pj_new")
        try await sync.mergeProject(id: "pj_a", into: "pj_b")
        XCTAssertEqual(api.merged.map(\.1), ["pj_b"])
    }

    /// A created project must survive a list GET that left before it existed.
    func testACreateDuringAListFetchSurvivesTheReplace() async throws {
        let api = FakeProjects()
        api.list = []
        api.blockNextList = true
        let (sync, store, _, _) = try make(api: api)
        let list = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        _ = try await sync.createProject(title: "Fresh", body: nil)
        api.releaseListGate()
        _ = await list.value
        XCTAssertNotNil(try store.project(id: "pj_new"))
    }

    /// Fix round 1: the fixed 50ms sleep was a guess at how long `stop()`
    /// needs to set `stopped = true` before the gate releases — replaced
    /// with a poll on the actor's own (test-only) `stopped` flag, so the
    /// ordering is guaranteed rather than merely likely.
    func testStopPreventsLaterWrites() async throws {
        let api = FakeProjects()
        api.list = [project("pj_1", num: 1)]
        api.blockNextList = true
        let (sync, store, _, _) = try make(api: api)
        let run = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        let stopping = Task { await sync.stop() }
        try await waitUntil { await sync.stopped }
        api.releaseListGate()
        _ = await run.value
        await stopping.value
        XCTAssertEqual(try store.projects(), [])
    }

    /// Fix round 1 (Important): `stop()` must cancel the in-flight run
    /// BEFORE awaiting it, mirroring `MissionsSync.stop` and `ItemsSync`'s
    /// own race fix. `stop()` yields at its first await (waiting on the
    /// marker/state tasks, then the refresh task), which is a real window
    /// where another actor call — here, a concurrent `start()` — can run
    /// and reset the SHARED `stopped` flag back to `false` before the
    /// gated fetch resolves. Once that happens, only `Task.isCancelled` on
    /// the specific run `stop()` already cancelled (permanent, and immune
    /// to the later `start()`) can still keep the stale response out of
    /// the store — proving `stop()` returns promptly with the CORRECT
    /// outcome once the gate is released, not a stale "succeeded".
    func testStopCancelsTheGatedFetchBeforeAConcurrentStartCanLetItLand() async throws {
        let api = FakeProjects()
        api.list = [project("pj_1", num: 1)]
        api.blockNextList = true
        let (sync, store, _, _) = try make(api: api)
        let owner = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        let stopTask = Task { await sync.stop() }
        try await waitUntil { await sync.stopped }
        await sync.start()
        api.releaseListGate()
        let outcome = await owner.value
        await stopTask.value
        XCTAssertEqual(outcome, .stopped,
                       "a concurrent start() resetting the shared flag must not let the pre-stop fetch's stale response land")
        XCTAssertEqual(try store.projects(), [], "the cancelled fetch's response must never reach the store")
        await sync.stop()
    }

    /// PR 278 review: the links refresh gets the same guard as the list and
    /// detail refreshes. A `start()` that lands while `stop()` is suspended
    /// resets `stopped`, so only `Task.isCancelled` on the run `stop()`
    /// cancelled can keep the pre-stop response out of the store.
    func testStopCancelsAGatedLinksFetchBeforeAConcurrentStartCanLetItLand() async throws {
        let api = FakeProjects()
        let m = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1")
        api.links["c1"] = [ConversationMissionLink(mission: m, isCurrent: true, joinedAt: Date(timeIntervalSince1970: 1))]
        api.blockNextLinks = true
        let (sync, store, _, _) = try make(api: api)
        let owner = Task { await sync.refreshConversationMissions(convoID: "c1") }
        try await waitUntil { api.isLinksGated }
        let stopTask = Task { await sync.stop() }
        try await waitUntil { await sync.stopped }
        await sync.start()
        api.releaseLinksGate()
        await owner.value
        await stopTask.value
        XCTAssertEqual(try store.conversationMissions(convoID: "c1").links, [],
                       "the cancelled links fetch's response must never reach the store")
        await sync.stop()
    }

    /// Fix round 2: `watched` must survive a `stop()`/`start()` cycle (a
    /// reconnect) — a chat that never left the screen has no reason to
    /// call `beginWatching` again, so if the count were cleared, a marker
    /// landing after the restart would silently stop refreshing its links.
    func testWatchedConversationsSurviveARestart() async throws {
        let api = FakeProjects()
        let m = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1")
        api.links["c1"] = [ConversationMissionLink(mission: m, isCurrent: true, joinedAt: Date(timeIntervalSince1970: 1))]
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let hub = MarkerHub()
        let (states, _) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = ProjectsSync(api: api, store: store, markers: { hub.stream() }, connectionStates: { states })
        await sync.start()
        await sync.beginWatching(convoID: "c1")
        try await waitUntil { api.linkCalls.count == 1 }
        await sync.stop()
        await sync.start()
        hub.yield((convoID: "c1", marker: marker()))
        try await waitUntil { api.linkCalls.count == 2 }
        await sync.stop()
    }

    /// Mirrors `MissionsSyncTests.testConcurrentRefetchesForOneMissionCoalesceIntoOneRepeatedRequest`:
    /// an out-of-order or merely slower SECOND detail fetch for the same id
    /// must not race the first — a joiner awaits the in-flight run, which
    /// then repeats once more for it, rather than letting two
    /// independently-ordered responses land in whichever order the network
    /// happens to deliver them.
    func testConcurrentRefreshesForOneProjectCoalesceIntoOneRepeatedRequest() async throws {
        let api = FakeProjects()
        api.details["pj_1"] = ProjectDetail(project: project("pj_1", num: 1), missions: [],
                                            recentMilestones: [], sessionsByBox: [:])
        let (sync, _, _, _) = try make(api: api)
        api.blockNextDetail = true
        let first = Task { await sync.refreshProject(id: "pj_1") }
        try await waitUntil { api.isDetailGated }
        let joinsBefore = await sync.detailJoins
        let second = Task { await sync.refreshProject(id: "pj_1") }
        try await waitUntil { await sync.detailJoins > joinsBefore }
        XCTAssertEqual(api.detailCalls.filter { $0 == "pj_1" }.count, 1,
                       "only one request may be active before the gate releases")
        api.releaseDetailGate()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .loaded(projectID: "pj_1"))
        XCTAssertEqual(secondOutcome, .loaded(projectID: "pj_1"))
        XCTAssertEqual(api.detailCalls.filter { $0 == "pj_1" }.count, 2,
                       "the in-flight run repeats once for the coalesced joiner rather than issuing a separate concurrent GET")
        await sync.stop()
    }

    /// Mirrors `MissionsSyncTests.testAConcurrentDetailRefreshSurvivesAStaleInFlightListRefresh`
    /// (fix round 2, H1): a list GET issued before a project's fresh detail
    /// lands must not let its (now stale) response revert or delete that
    /// project once it resolves — `protectedSinceListStart` is the same
    /// mechanism `replaceProjects(keeping:)` already honors.
    func testAConcurrentDetailRefreshSurvivesAStaleInFlightListRefresh() async throws {
        let api = FakeProjects()
        api.list = [
            project("pj_1", num: 1),
            Project(id: "pj_2", num: 2, title: "stale title from an earlier snapshot",
                   createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2)),
        ]
        api.details["pj_2"] = ProjectDetail(project: project("pj_2", num: 2), missions: [],
                                            recentMilestones: [], sessionsByBox: [:])
        let (sync, store, _, _) = try make(api: api)
        api.blockNextList = true
        let listTask = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        let detailOutcome = await sync.refreshProject(id: "pj_2")
        XCTAssertEqual(detailOutcome, .loaded(projectID: "pj_2"))
        XCTAssertEqual(try store.project(id: "pj_2")?.title, "P2",
                       "the detail refresh must land before the stale list response is even released")
        api.releaseListGate()
        let listOutcome = await listTask.value
        XCTAssertEqual(listOutcome, .succeeded)
        XCTAssertEqual(try store.project(id: "pj_2")?.title, "P2",
                       "the concurrent detail refresh's fields must survive the now-stale list response's upsert")
        await sync.stop()
    }

    /// Fix round 2: `isSupported` must flip back to `true` once the
    /// journal starts answering `GET /projects` again — an old-journal
    /// probe must not be a permanent, one-way trip.
    func testUnsupportedRecoversWhenTheJournalStartsAnsweringAgain() async throws {
        let api = FakeProjects()
        api.listError = JournalAPIError.notFound
        let (sync, _, _, _) = try make(api: api)
        var seen: [Bool] = []
        let stream = await sync.supportedStream()
        let watcher = Task { for await v in stream { seen.append(v); if seen.count == 3 { return } } }
        let firstOutcome = await sync.refresh()
        XCTAssertEqual(firstOutcome, .unsupported)
        api.listError = nil
        api.list = [project("pj_1", num: 1)]
        let secondOutcome = await sync.refresh()
        XCTAssertEqual(secondOutcome, .succeeded)
        _ = await watcher.value
        XCTAssertEqual(seen, [true, false, true])
        await sync.stop()
    }

    /// pr3-review M5: once `GET /projects` has answered 404, chat opens
    /// and markers in a watched chat fetch no links. A transient list
    /// failure never turns links off, and a later success turns them back on.
    func testLinksSkipTheNetworkOnlyWhileTheJournalIsKnownUnsupported() async throws {
        let api = FakeProjects()
        let (sync, _, markers, _) = try make(api: api)
        api.listError = URLError(.timedOut)
        let transient = await sync.refresh()
        XCTAssertEqual(transient, .failed(MissionsRefreshFailure(URLError(.timedOut))))
        await sync.refreshConversationMissions(convoID: "c1")
        XCTAssertEqual(api.linkCalls, ["c1"], "a transient failure is not the 404 signal")

        api.listError = JournalAPIError.notFound
        let unsupported = await sync.refresh()
        XCTAssertEqual(unsupported, .unsupported)
        await sync.refreshConversationMissions(convoID: "c1")
        await sync.start()
        await sync.beginWatching(convoID: "c2")
        markers.yield((convoID: "c2", marker: marker()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.linkCalls, ["c1"], "no link fetch on an old journal: not direct, not on open, not on a marker")

        api.listError = nil
        let recovered = await sync.refresh()
        XCTAssertEqual(recovered, .succeeded)
        await sync.refreshConversationMissions(convoID: "c1")
        XCTAssertEqual(api.linkCalls, ["c1", "c1"], "a success turns links back on")
        await sync.stop()
    }

    /// Fix round 2: a conversation the journal doesn't know (or an old
    /// journal with no route at all) answers 404 — swallowed, same as
    /// `MissionsSync`'s equivalent, leaving the local derivation in place
    /// rather than throwing or logging it as a failure.
    func testLinksNotFoundIsSwallowed() async throws {
        let api = FakeProjects()
        let (sync, store, _, _) = try make(api: api)
        await sync.refreshConversationMissions(convoID: "c-unknown")
        XCTAssertEqual(api.linkCalls, ["c-unknown"])
        XCTAssertEqual(try store.conversationMissions(convoID: "c-unknown").links, [],
                       "a 404 leaves the local derivation untouched rather than throwing")
    }

    /// Fix round 2: a merge must refresh both the list (the source
    /// disappears from it) and the target's own detail (its counts moved).
    func testMergeRefreshesBothTheListAndTheTarget() async throws {
        let api = FakeProjects()
        api.list = [project("pj_b", num: 2)]
        api.details["pj_b"] = ProjectDetail(project: project("pj_b", num: 2), missions: [],
                                            recentMilestones: [], sessionsByBox: [:])
        let (sync, store, _, _) = try make(api: api)
        try await sync.mergeProject(id: "pj_a", into: "pj_b")
        XCTAssertEqual(api.merged.map(\.1), ["pj_b"])
        XCTAssertEqual(api.listCalls, 1, "merge refreshes the list")
        XCTAssertEqual(api.detailCalls, ["pj_b"], "merge refreshes the target's detail")
        XCTAssertEqual(try store.projects().map(\.id), ["pj_b"])
        await sync.stop()
    }
}
