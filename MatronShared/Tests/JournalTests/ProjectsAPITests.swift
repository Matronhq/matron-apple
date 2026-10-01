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
            "sessions_by_box": ["greg": 2, "pat": 1],
        ])
        let detail = try await api.project(id: "#4000")
        XCTAssertEqual(detail.project.id, "pj_1")
        XCTAssertEqual(detail.missions.map(\.id), ["ms_a1"])
        XCTAssertEqual(detail.recentMilestones.map(\.id), ["ml_b2"])
        XCTAssertEqual(detail.sessionsByBox, ["greg": 2, "pat": 1])
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/projects/%234000") == true)
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
