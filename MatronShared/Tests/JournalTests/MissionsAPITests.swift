import XCTest
import MatronModels
@testable import MatronJournal

final class MissionsAPITests: XCTestCase {
    /// Builds a `JournalAPI` wired to `ItemsStubURLProtocol` (defined in
    /// `ItemsAPITests.swift`, same target) — copied verbatim rather than
    /// invented anew, per the brief.
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

    func testMissionsListQueryBuildsStateAndSince() {
        var q = MissionsListQuery()
        XCTAssertEqual(q.queryItems, [])
        q.state = .open
        q.since = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(q.queryItems, [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "since", value: "1700000000000"),
        ])
    }

    func testDecodeMissionsListDropsMalformedRowsButKeepsTheRest() throws {
        let obj: [String: Any] = ["missions": [
            MissionModelTests.missionJSON,
            ["id": "ms_broken"],                       // no num/state/title — skipped
        ]]
        let missions = JournalAPI.decodeMissions(obj)
        XCTAssertEqual(missions.map(\.id), ["ms_a1"])
    }

    func testDecodeMissionDetail() throws {
        let obj: [String: Any] = [
            "mission": MissionModelTests.missionJSON,
            "milestones": [MissionModelTests.milestoneJSON],
            "items": [ItemsAPITests.itemJSON],
            "conversations": [["id": "c1", "title": "Session", "box": "dev-2", "state": "running"]],
        ]
        let detail = try JournalAPI.decodeMissionDetail(obj)
        XCTAssertEqual(detail.mission.id, "ms_a1")
        XCTAssertEqual(detail.milestones.map(\.id), ["ml_b2"])
        XCTAssertEqual(detail.items.map(\.id), ["it_1"])
        XCTAssertEqual(detail.conversations.map(\.id), ["c1"])
    }

    func testDecodeMissionDetailWithoutAMissionIsATransportError() {
        XCTAssertThrowsError(try JournalAPI.decodeMissionDetail(["milestones": []])) { error in
            guard case JournalAPIError.transport = error else { return XCTFail("expected .transport, got \(error)") }
        }
    }

    func testMissionPathSegmentEncodesANumberReference() {
        // `:id` accepts `ms_…` or a bare number; a `#61` reference must be
        // percent-encoded or the `#` truncates the URL into a fragment.
        XCTAssertEqual(JournalAPI.pathSegment("#61"), "%2361")
        XCTAssertEqual(JournalAPI.pathSegment("ms_a1"), "ms_a1")
    }

    // MARK: - JournalAPI missions routes

    func testListMissionsBuildsQueryAndDecodes() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["missions": [MissionModelTests.missionJSON]])
        var q = MissionsListQuery(); q.state = .open
        let missions = try await api.listMissions(q)
        XCTAssertEqual(missions.map(\.id), ["ms_a1"])
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/missions")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(URLQueryItem(name: "state", value: "open")))
    }

    func testMissionDetailFetchesByEncodedID() async throws {
        let obj: [String: Any] = [
            "mission": MissionModelTests.missionJSON,
            "milestones": [MissionModelTests.milestoneJSON],
            "items": [ItemsAPITests.itemJSON],
            "conversations": [["id": "c1", "title": "Session", "box": "dev-2", "state": "running"]],
        ]
        let (api, recorder) = makeStubbedAPI(status: 200, body: obj)
        let detail = try await api.mission(id: "#61")
        XCTAssertEqual(detail.mission.id, "ms_a1")
        XCTAssertTrue(recorder.lastRequest?.url?.absoluteString.hasSuffix("/missions/%2361") == true)
    }

    func testMilestonesFetchesByConvoQuery() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["milestones": [MissionModelTests.milestoneJSON]])
        let milestones = try await api.milestones(convoID: "c1")
        XCTAssertEqual(milestones.map(\.id), ["ml_b2"])
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/milestones")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(URLQueryItem(name: "convo", value: "c1")))
    }

    func testCloseMissionPostsSummaryAndDecodesMission() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["mission": MissionModelTests.missionJSON])
        let mission = try await api.closeMission(id: "ms_a1", summary: "Done.")
        XCTAssertEqual(mission.id, "ms_a1")
        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(req.url?.absoluteString.hasSuffix("/missions/ms_a1/close") == true)
        let sent = try JSONSerialization.jsonObject(with: recorder.lastBody!) as! [String: Any]
        XCTAssertEqual(sent["summary"] as? String, "Done.")
    }
}
