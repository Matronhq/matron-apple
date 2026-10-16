import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

/// Writes by another person in the user's mission carry who wrote them:
/// `contributor: {name, via}` on items, comments and milestones,
/// `attribution` on comments (a contributor's, and every comment a
/// hand-over copied), and `status_contributor` on the mission. Each is
/// absent on everything else, and must read as nothing.
final class ContributorAttributionTests: XCTestCase {
    private let itemJSON: [String: Any] = [
        "id": "it_1", "num": 12, "kind": "question", "state": "open", "title": "Which proof?",
        "origin_convo_id": "c-people", "created_at": 1_700_000_000_000, "updated_at": 1_700_000_001_000,
    ]
    private let commentJSON: [String: Any] = [
        "id": "ic_1", "item_id": "it_1", "author": "agent", "device_id": 0, "kind": "comment",
        "body": "The second one.", "created_at": 1_700_000_002_000, "convo_id": NSNull(),
    ]

    func testContributorReadsNameAndVia() {
        XCTAssertEqual(Contributor(json: ["name": "bob", "via": "agent"]), Contributor(name: "bob", via: .agent))
        XCTAssertEqual(Contributor(json: ["name": "bob", "via": "user"])?.label, "bob")
        XCTAssertEqual(Contributor(json: ["name": "bob", "via": "agent"])?.label, "bob's agent")
        XCTAssertEqual(Contributor(json: ["name": "bob", "via": "agent"])?.byline, "by bob's agent")
        // An unknown `via` keeps the name.
        XCTAssertEqual(Contributor(json: ["name": "bob", "via": "robot"])?.via, .user)
        XCTAssertNil(Contributor(json: ["name": "  "]))
        XCTAssertNil(Contributor(json: NSNull()))
        XCTAssertNil(Contributor(json: nil))
    }

    func testAContributorsItemIsHeadedWithTheirName() throws {
        var json = itemJSON
        json["contributor"] = ["name": "bob", "via": "agent"]
        let item = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertEqual(item.contributor, Contributor(name: "bob", via: .agent))
        XCTAssertEqual(item.filerName, "bob's agent")
        let own = try XCTUnwrap(TrackerItem(json: itemJSON))
        XCTAssertNil(own.contributor)
        XCTAssertEqual(own.filerName, "Agent")
    }

    func testAContributorsCommentIsHeadedWithTheirName() throws {
        var json = commentJSON
        json["contributor"] = ["name": "bob", "via": "user"]
        json["attribution"] = "bob"
        let comment = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(comment.contributor, Contributor(name: "bob"))
        XCTAssertEqual(comment.attribution, "bob")
        XCTAssertEqual(comment.authorName, "bob")
        XCTAssertNil(comment.authorConversation)
    }

    func testACopiedCommentCarriesOnlyItsAttribution() throws {
        var json = commentJSON
        json["attribution"] = "alice's agent"
        let comment = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertNil(comment.contributor)
        XCTAssertEqual(comment.authorName, "alice's agent")
    }

    func testAnOwnCommentIsUnchanged() throws {
        let comment = try XCTUnwrap(TrackerComment(json: commentJSON))
        XCTAssertNil(comment.personAttribution)
        XCTAssertEqual(comment.authorName, "Agent")
        var blank = commentJSON
        blank["attribution"] = "  "
        XCTAssertNil(try XCTUnwrap(TrackerComment(json: blank)).attribution)
    }

    func testChoosingKeepsTheAttribution() {
        let comment = TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, body: "?", actions: ["Yes"],
                                     contributor: Contributor(name: "bob"), attribution: "bob")
        XCTAssertEqual(comment.choosing("Yes").authorName, "bob")
    }

    func testMissionAndMilestoneContributors() throws {
        let mission = try XCTUnwrap(Mission(json: [
            "id": "ms_1", "num": 3, "state": "open", "title": "Cover editor", "origin_convo_id": "c1",
            "created_at": 1_700_000_000_000, "updated_at": 1_700_000_000_000,
            "status": "Proofs are in.", "status_by": "agent", "status_contributor": "bob",
            "status_updated_at": 1_700_000_000_000,
        ]))
        XCTAssertEqual(mission.statusContributor, "bob")
        let milestone = try XCTUnwrap(Milestone(json: [
            "id": "ml_1", "mission_id": "ms_1", "num": 7, "kind": "progress", "title": "Proofs in",
            "convo_id": "c-people", "seq": 0, "created_at": 1_700_000_000_000,
            "contributor": ["name": "bob", "via": "agent"],
        ]))
        XCTAssertEqual(milestone.contributor, Contributor(name: "bob", via: .agent))
    }

    func testTheCacheKeepsEveryAttribution() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        var json = itemJSON
        json["contributor"] = ["name": "bob", "via": "user"]
        try store.upsertItems([try XCTUnwrap(TrackerItem(json: json))])
        XCTAssertEqual(try store.item(id: "it_1")?.contributor, Contributor(name: "bob"))

        try store.replaceComments(itemID: "it_1", [
            TrackerComment(id: "ic_1", itemID: "it_1", author: .agent, body: "one", createdAt: Date(timeIntervalSince1970: 1),
                           contributor: Contributor(name: "bob", via: .agent), attribution: "bob's agent"),
            TrackerComment(id: "ic_2", itemID: "it_1", author: .user, body: "two", createdAt: Date(timeIntervalSince1970: 2)),
        ])
        let comments = try store.comments(itemID: "it_1")
        XCTAssertEqual(comments.map(\.authorName), ["bob's agent", "You"])
        XCTAssertEqual(comments.first?.contributor, Contributor(name: "bob", via: .agent))

        let mission = Mission(id: "ms_1", num: 3, title: "Cover editor", originConvoID: "c1",
                              status: "Proofs are in.", statusContributor: "bob")
        try store.upsertMissions([mission])
        XCTAssertEqual(try store.mission(id: "ms_1")?.statusContributor, "bob")

        try store.upsertMilestones([
            Milestone(id: "ml_1", missionID: "ms_1", num: 7, kind: .progress, title: "Proofs in", convoID: "c-people",
                      seq: 0, contributor: Contributor(name: "bob", via: .agent)),
            Milestone(id: "ml_2", missionID: "ms_1", num: 8, kind: .progress, title: "Mine", convoID: "c1", seq: 5),
        ])
        let milestones = try store.milestones(missionID: "ms_1").sorted { $0.num < $1.num }
        XCTAssertEqual(milestones.map(\.contributor), [Contributor(name: "bob", via: .agent), nil])
    }

    func testTheGrantAnswerBody() {
        XCTAssertEqual(JournalAPI.grantAnswerBody(approve: false, excludeMedia: ["md_1"]) as NSDictionary,
                       ["decision": "decline"])
        XCTAssertEqual(JournalAPI.grantAnswerBody(approve: true, excludeMedia: []) as NSDictionary,
                       ["decision": "approve"])
        XCTAssertEqual(JournalAPI.grantAnswerBody(approve: true, excludeMedia: ["md_2"]) as NSDictionary,
                       ["decision": "approve", "exclude_media": ["md_2"]])
    }

    func testAnswerGrantPostsToTheGrant() async throws {
        ItemsStubURLProtocol.status = 200
        ItemsStubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["grant": ["id": "gr_9"]])
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")
        try await api.answerGrant(grantID: "gr_9", approve: true, excludeMedia: ["md_2"])
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/grants/gr_9/answer") == true)
        let body = try XCTUnwrap(ItemsStubURLProtocol.lastBody)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? NSDictionary)
        XCTAssertEqual(sent, ["decision": "approve", "exclude_media": ["md_2"]])
    }

    /// A grant id is one path segment: a `/` in it is encoded, never a
    /// second route component.
    func testAnswerGrantEncodesTheGrantID() async throws {
        ItemsStubURLProtocol.status = 200
        ItemsStubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["grant": ["id": "gr_9"]])
        ItemsStubURLProtocol.lastRequest = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")
        try await api.answerGrant(grantID: "gr/../x", approve: false)
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/grants/gr%2F..%2Fx/answer") == true,
                      ItemsStubURLProtocol.lastRequest?.url?.absoluteString ?? "no request")
    }

    /// Items cached before the contributor column carry none, and an
    /// incremental refresh skips them while their `updated_at` stands: the
    /// migration clears the item watermarks so the next refresh refetches
    /// every item.
    func testTheContributorMigrationForcesAFullItemRefresh() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "item_outbox_rejected")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES('items_watermark_all', '1000')")
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES('items_watermark_convo_c1', '1000')")
            try db.execute(sql: "INSERT INTO meta(key, value) VALUES('unrelated_key', 'keep-me')")
        }
        try JournalStore.migrator().migrate(queue, upTo: "contributors")
        let keys = try queue.read { db in try String.fetchAll(db, sql: "SELECT key FROM meta") }
        XCTAssertFalse(keys.contains("items_watermark_all"))
        XCTAssertFalse(keys.contains("items_watermark_convo_c1"))
        XCTAssertTrue(keys.contains("unrelated_key"))
    }
}
