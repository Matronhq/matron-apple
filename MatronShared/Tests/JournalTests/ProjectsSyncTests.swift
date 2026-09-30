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

    var list: [Project] { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
    var listError: Error? { get { lock.withLock { _listError } } set { lock.withLock { _listError = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var details: [String: ProjectDetail] { get { lock.withLock { _details } } set { lock.withLock { _details = newValue } } }
    var links: [String: [ConversationMissionLink]] { get { lock.withLock { _links } } set { lock.withLock { _links = newValue } } }
    var linkCalls: [String] { lock.withLock { _linkCalls } }
    var created: [(String, String?, String)] { lock.withLock { _created } }
    var merged: [(String, String)] { lock.withLock { _merged } }
    var filed: [(String, String?)] { lock.withLock { _filed } }
    var blockNextList: Bool { get { lock.withLock { _blockNextList } } set { lock.withLock { _blockNextList = newValue } } }
    var isListGated: Bool { lock.withLock { _listGate != nil } }
    func releaseListGate() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { _listGate = nil }; return _listGate }
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
        lock.withLock { _linkCalls.append(convoID) }
        guard let l = links[convoID] else { throw JournalAPIError.notFound }
        return l
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

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition() {
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

    func testStopPreventsLaterWrites() async throws {
        let api = FakeProjects()
        api.list = [project("pj_1", num: 1)]
        api.blockNextList = true
        let (sync, store, _, _) = try make(api: api)
        let run = Task { await sync.refresh() }
        try await waitUntil { api.isListGated }
        let stopping = Task { await sync.stop() }
        try await Task.sleep(for: .milliseconds(50))
        api.releaseListGate()
        _ = await run.value
        await stopping.value
        XCTAssertEqual(try store.projects(), [])
    }
}
