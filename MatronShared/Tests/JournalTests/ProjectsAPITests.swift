import XCTest
import MatronModels
@testable import MatronJournal

final class ProjectsAPITests: XCTestCase {
    private func makeStubbedAPI(status: Int, body: [String: Any]) -> (JournalAPI, ItemsStubURLProtocol.Type) {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")
        return (api, ItemsStubURLProtocol.self)
    }

    private func sentBody(_ recorder: ItemsStubURLProtocol.Type) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.lastBody)) as? [String: Any])
    }

    func testListProjectsGetsWithoutAStateAndKeepsDroppedIDs() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["projects": [
            ProjectModelTests.projectJSON, ["id": "pj_broken"],
        ]])
        let decoded = try await api.listProjects()
        XCTAssertEqual(decoded.projects.map(\.id), ["pj_1"])
        XCTAssertEqual(decoded.droppedIDs, ["pj_broken"])
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/projects")
        XCTAssertNil(url.query, "both states: no ?state=")
    }

    func testAMalformedListIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeProjects(["foo": 1])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
        }
    }

    func testListProjects404IsNotFound() async {
        let (api, _) = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do { _ = try await api.listProjects(); XCTFail("expected a throw") }
        catch { XCTAssertEqual(error as? JournalAPIError, .notFound) }
    }

    /// R1: the journal's `needs_you` rows are slim (no `created_at`), so
    /// `ProjectDetail` drops the field entirely rather than decode it
    /// leniently and risk an upsert overwriting a full cached item with a
    /// slim one. The page reads needs-you from the local item cache instead.
    func testProjectDetailDecodesEveryPart() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "project": ProjectModelTests.projectJSON,
            "missions": [MissionModelTests.missionJSON],
            "recent_milestones": [MissionModelTests.milestoneJSON],
            "sessions_by_box": ["slate": 2, "pat": 1],
        ])
        let detail = try await api.project(id: "#4000")
        XCTAssertEqual(detail.project.id, "pj_1")
        XCTAssertEqual(detail.missions.map(\.id), ["ms_a1"])
        XCTAssertEqual(detail.recentMilestones.map(\.id), ["ml_b2"])
        XCTAssertEqual(detail.sessionsByBox, ["slate": 2, "pat": 1])
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/projects/%234000") == true)
    }

    func testListRowsCarryTheCardFields() async throws {
        let row = ProjectModelTests.projectJSON.merging(ProjectModelTests.cardJSON) { $1 }
        let (api, _) = makeStubbedAPI(status: 200, body: ["projects": [row, ProjectModelTests.projectJSON]])
        let decoded = try await api.listProjects()
        XCTAssertEqual(decoded.projects.first?.waitingOn?.itemID, "it_9")
        XCTAssertEqual(decoded.projects.first?.sessionsNow, 3)
        XCTAssertNil(decoded.projects.last?.card, "a row without the fields still decodes")
    }

    func testProjectDetailDecodesTheFeedPages() async throws {
        let (api, _) = makeStubbedAPI(status: 200, body: [
            "project": ProjectModelTests.projectJSON, "missions": [], "recent_milestones": [], "sessions_by_box": [:],
            "decisions": ["total": 8, "rows": [ProjectModelTests.decisionJSON, ProjectModelTests.answeredJSON],
                          "next_before": "1700000001000:000000004130"],
            "files": ["total": 2, "rows": [ProjectModelTests.itemFileJSON, ProjectModelTests.chatFileJSON],
                      "next_before": NSNull()],
            "milestones": ["total": 1, "rows": [ProjectModelTests.milestoneRowJSON], "next_before": NSNull()],
        ])
        let detail = try await api.project(id: "pj_1")
        let feed = try XCTUnwrap(detail.feed)
        XCTAssertEqual(feed.decisions.total, 8)
        XCTAssertEqual(feed.decisions.rows.map(\.id), ["it_d1", "it_q1"])
        XCTAssertEqual(feed.decisions.nextBefore, "1700000001000:000000004130")
        XCTAssertEqual(feed.files.rows.map(\.blobID), ["b_1", "b_2"])
        XCTAssertNil(feed.files.nextBefore)
        XCTAssertEqual(feed.milestones.rows.first?.missionNum, 4001)
    }

    /// A journal without the roll-up: the detail decodes, with no feed.
    func testProjectDetailFromAnOlderJournalHasNoFeed() async throws {
        let (api, _) = makeStubbedAPI(status: 200, body: [
            "project": ProjectModelTests.projectJSON, "missions": [MissionModelTests.missionJSON],
            "recent_milestones": [], "sessions_by_box": ["slate": 1],
        ])
        let detail = try await api.project(id: "pj_1")
        XCTAssertNil(detail.feed)
        XCTAssertEqual(detail.missions.count, 1)
    }

    func testProjectFeedSendsKindCursorAndLimit() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "kind": "files", "total": 5, "rows": [ProjectModelTests.chatFileJSON], "next_before": "1:e:000000000001",
        ])
        let slice = try await api.projectFeed(id: "#4000", kind: .files, before: "1700000002500:e:000000004211", limit: 10)
        guard case .files(let page) = slice else { return XCTFail("got \(slice)") }
        XCTAssertEqual(page.rows.map(\.blobID), ["b_2"]); XCTAssertEqual(page.total, 5)
        XCTAssertEqual(slice.nextBefore, "1:e:000000000001")
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertTrue(url.absoluteString.contains("/projects/%234000/feed?"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "kind" }?.value, "files")
        XCTAssertEqual(items.first { $0.name == "before" }?.value, "1700000002500:e:000000004211")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "10")
    }

    func testProjectFeedFirstPageSendsOnlyTheKind() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "kind": "milestones", "total": 0, "rows": [], "next_before": NSNull(),
        ])
        let slice = try await api.projectFeed(id: "pj_1", kind: .milestones, before: nil, limit: nil)
        XCTAssertEqual(slice, .milestones(ProjectFeedPage()))
        XCTAssertEqual(recorder.lastRequest?.url?.query, "kind=milestones")
    }

    func testAFeedAnswerForAnotherKindOrWithoutRowsIsATransportError() {
        for bad: [String: Any] in [["kind": "files", "total": 0, "rows": []], ["kind": "decisions", "total": 3]] {
            XCTAssertThrowsError(try JournalAPI.decodeProjectFeed(bad, kind: .decisions)) { error in
                guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
            }
        }
    }

    /// A journal without the feed route answers 404.
    func testProjectFeed404IsNotFound() async {
        let (api, _) = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do { _ = try await api.projectFeed(id: "pj_1", kind: .decisions, before: nil, limit: nil); XCTFail("expected a throw") }
        catch { XCTAssertEqual(error as? JournalAPIError, .notFound) }
    }

    func testCreateProjectPostsTitleBodyAndIdempotencyKey() async throws {
        let (api, recorder) = makeStubbedAPI(status: 201, body: ["project": ProjectModelTests.projectJSON])
        let project = try await api.createProject(title: "Promo launch", body: "Site and blog", idempotencyKey: "k-1")
        XCTAssertEqual(project.id, "pj_1")
        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/projects")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Idempotency-Key"), "k-1")
        let sent = try sentBody(recorder)
        XCTAssertEqual(sent["title"] as? String, "Promo launch")
        XCTAssertEqual(sent["body"] as? String, "Site and blog")
    }

    func testCreateProjectOmitsAnEmptyBody() async throws {
        let (api, recorder) = makeStubbedAPI(status: 201, body: ["project": ProjectModelTests.projectJSON])
        _ = try await api.createProject(title: "T", body: "  ", idempotencyKey: "k")
        XCTAssertNil(try sentBody(recorder)["body"])
    }

    func testMergePostsInto() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["project": ProjectModelTests.projectJSON])
        try await api.mergeProject(id: "pj_1", into: "pj_2")
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/projects/pj_1/merge") == true)
        XCTAssertEqual(try sentBody(recorder)["into"] as? String, "pj_2")
    }

    func testSetMissionProjectPatchesAnIdOrNull() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["mission": MissionModelTests.missionJSON])
        _ = try await api.setMissionProject(missionID: "ms_a1", project: "pj_1")
        XCTAssertEqual(recorder.lastRequest?.httpMethod, "PATCH")
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/missions/ms_a1") == true)
        XCTAssertEqual(try sentBody(recorder)["project"] as? String, "pj_1")
        _ = try await api.setMissionProject(missionID: "ms_a1", project: nil)
        XCTAssertTrue(try sentBody(recorder)["project"] is NSNull, "null takes the mission out of its project")
    }

    func testConversationMissionsDecodesLinks() async throws {
        var row = MissionModelTests.missionJSON
        row["current"] = true; row["joined_at"] = 1_700_000_001_000; row["how"] = "joined"
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["missions": [row]])
        let links = try await api.conversationMissions(convoID: "c1:sub:a")
        XCTAssertEqual(links.map(\.id), ["ms_a1"])
        XCTAssertTrue(links[0].isCurrent)
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/conversations/c1%3Asub%3Aa/missions") == true)
    }

    /// PR 278 review: the links response feeds an AUTHORITATIVE replace, so
    /// a row that fails to decode must fail the whole response — dropping it
    /// would read as "the server unlinked this mission" and delete the
    /// cached link (with or without an id to protect it by).
    func testAnUndecodableLinkRowFailsTheWholeResponse() {
        var row = MissionModelTests.missionJSON
        row["current"] = true
        var slim = MissionModelTests.missionJSON
        slim["id"] = "ms_slim"; slim.removeValue(forKey: "title")
        for bad: [String: Any] in [slim, ["current": true]] {
            XCTAssertThrowsError(try JournalAPI.decodeConversationMissions(["missions": [row, bad]])) { error in
                guard case JournalAPIError.transport = error else { return XCTFail("got \(error)") }
            }
        }
    }
}
