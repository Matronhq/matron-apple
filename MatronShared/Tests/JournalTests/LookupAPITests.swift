import XCTest
@testable import MatronJournal

/// `GET /lookup`: what a number names in the user's number space.
final class LookupAPITests: XCTestCase {
    /// Same stub wiring as `RosterAPITests.makeStubbedAPI` —
    /// `ItemsStubURLProtocol` lives in `ItemsAPITests.swift`, same target.
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

    func testLookupAsksForTheUsersNumberAndDecodesIt() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: [
            "kind": "item", "id": "it_1", "num": 412, "title": "Fix the parser",
            "owner": ["user_id": 1, "name": "alice"],
        ])
        let found = try await api.lookup(user: "alice", num: 412)
        XCTAssertEqual(found, NumberLookup(kind: .item, id: "it_1", num: 412, title: "Fix the parser", ownerName: "alice"))

        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/lookup")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "user", value: "alice"), URLQueryItem(name: "num", value: "412")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testNoSuchNumberIsNotFound() async {
        let (api, _) = makeStubbedAPI(status: 404, body: ["error": "not_found"])
        do {
            _ = try await api.lookup(user: "alice", num: 412)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }

    /// A milestone names the mission it belongs to; a merged row names the
    /// id the number used to stand for.
    func testDecodeReadsAMilestonesMissionAndAMerge() throws {
        let milestone = try JournalAPI.decodeLookup([
            "kind": "milestone", "id": "ml_1", "num": 30, "title": "Parser landed",
            "mission": ["id": "ms_1", "num": 7],
        ])
        XCTAssertEqual(milestone.kind, .milestone)
        XCTAssertEqual(milestone.mission, NumberLookup.MissionRef(id: "ms_1", num: 7))

        let merged = try JournalAPI.decodeLookup([
            "kind": "project", "id": "pj_2", "num": 12, "title": "Promo", "merged_from": "pj_1",
        ])
        XCTAssertEqual(merged, NumberLookup(kind: .project, id: "pj_2", num: 12, title: "Promo", mergedFrom: "pj_1"))
    }

    /// Another person's number names its owner.
    func testDecodeReadsTheOwnersName() throws {
        let hit = try JournalAPI.decodeLookup([
            "kind": "item", "id": "it_1", "num": 4, "owner": ["user_id": "u_2", "name": "bob"],
        ])
        XCTAssertEqual(hit.ownerName, "bob")
        XCTAssertNil(try JournalAPI.decodeLookup(["kind": "item", "id": "it_1"]).ownerName)
    }

    /// An older journal sends the kind and the id alone.
    func testDecodeToleratesTheOptionalFieldsMissing() throws {
        let bare = try JournalAPI.decodeLookup(["kind": "mission", "id": "ms_1"])
        XCTAssertEqual(bare, NumberLookup(kind: .mission, id: "ms_1"))
        let blank = try JournalAPI.decodeLookup(["kind": "mission", "id": "ms_1", "title": "  ", "mission": NSNull()])
        XCTAssertNil(blank.title)
        XCTAssertNil(blank.mission)
    }

    /// A kind this app cannot open, or no id, is malformed rather than a
    /// hit on nothing.
    func testDecodeOfAnUnknownKindOrNoIdThrows() {
        XCTAssertThrowsError(try JournalAPI.decodeLookup(["kind": "memory", "id": "m1"]))
        XCTAssertThrowsError(try JournalAPI.decodeLookup(["kind": "item"]))
        XCTAssertThrowsError(try JournalAPI.decodeLookup(["id": "it_1"]))
    }
}
