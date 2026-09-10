import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreMissionsTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }

    private func mission(_ id: String, num: Int, state: MissionState = .open, convo: String = "c1",
                         lastMilestoneAt: TimeInterval? = 10, needsYou: Int = 0,
                         closedAt: TimeInterval? = nil) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", body: "goal", originConvoID: convo,
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: lastMilestoneAt.map { Date(timeIntervalSince1970: $0) },
                closedAt: closedAt.map { Date(timeIntervalSince1970: $0) },
                openItems: needsYou, needsYou: needsYou, conversationCount: 1, milestoneCount: 1,
                lastMilestone: MissionLastMilestone(num: num + 1, title: "step", kind: .progress,
                                                    createdAt: Date(timeIntervalSince1970: lastMilestoneAt ?? 0)))
    }

    private func milestone(_ id: String, mission: String, num: Int, convo: String = "c1",
                           seq: Int64, kind: MilestoneKind = .progress, created: TimeInterval) -> Milestone {
        Milestone(id: id, missionID: mission, num: num, kind: kind, title: "T\(num)", body: "b",
                  convoID: convo, seq: seq, createdAt: Date(timeIntervalSince1970: created))
    }

    func testMigrationV10CreatesTablesAndItemColumns() throws {
        let store = try makeStore()
        let names = try store.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        XCTAssertTrue(names.contains("mission"))
        XCTAssertTrue(names.contains("milestone"))
        XCTAssertTrue(names.contains("mission_conversation"))
        let itemCols = try store.dbQueue.read { db in try Row.fetchAll(db, sql: "PRAGMA table_info(item)").map { $0["name"] as String } }
        XCTAssertTrue(itemCols.contains("mission_id"))
        XCTAssertTrue(itemCols.contains("mission_num"))
    }

    /// The migration is additive: a database already at v9 with real item
    /// rows must gain the columns without losing anything.
    func testV10MigratesUpFromV9WithExistingItems() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "v9")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO item(id, num, kind, state, rank, title, body, labels_json, links_json,
                                 attachments_json, origin_convo_id, created_by, created_at, updated_at,
                                 comment_count, has_image)
                VALUES('it_1', 5, 'task', 'open', 1024, 'Existing', '', '[]', '[]', '[]', 'c1', 'agent', 1, 2, 0, 0)
                """)
        }
        try JournalStore.migrator().migrate(queue)   // up to the head, i.e. v10
        let row = try queue.read { db in try Row.fetchOne(db, sql: "SELECT title, mission_id, mission_num FROM item WHERE id='it_1'") }
        XCTAssertEqual(row?["title"], "Existing")
        XCTAssertNil(row?["mission_id"] as String?)
        XCTAssertNil(row?["mission_num"] as Int?)
    }

    func testMissionsRoundTripAndSortByLatestMilestone() throws {
        let store = try makeStore()
        try store.upsertMissions([
            mission("ms_1", num: 61, lastMilestoneAt: 10),
            mission("ms_2", num: 62, convo: "c2", lastMilestoneAt: 30, needsYou: 2),
            mission("ms_3", num: 63, convo: "c3", lastMilestoneAt: nil),
            mission("ms_4", num: 64, state: .closed, convo: "c4", lastMilestoneAt: 20, closedAt: 40),
        ])
        // Open, newest milestone first, a mission with no milestone last.
        XCTAssertEqual(try store.missions(state: .open).map(\.id), ["ms_2", "ms_1", "ms_3"])
        XCTAssertEqual(try store.missions(state: .closed).map(\.id), ["ms_4"])
        XCTAssertEqual(try store.missions(state: nil).count, 4)
        XCTAssertEqual(try store.mission(id: "ms_2")?.needsYou, 2)
        XCTAssertEqual(try store.mission(id: "ms_2")?.lastMilestone?.title, "step")
        XCTAssertEqual(try store.mission(num: 63)?.id, "ms_3")
        XCTAssertNil(try store.mission(num: 999))

        // Upsert replaces in place — the fetched row wins, no duplicates.
        try store.upsertMissions([mission("ms_1", num: 61, state: .closed, lastMilestoneAt: 10, closedAt: 50)])
        XCTAssertEqual(try store.missions(state: nil).count, 4)
        XCTAssertEqual(try store.mission(id: "ms_1")?.state, .closed)
    }

    func testMilestonesAreReplacedWholesaleAndReadNewestFirst() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMilestones(missionID: "ms_1", [
            milestone("ml_1", mission: "ms_1", num: 62, seq: 100, created: 1),
            milestone("ml_2", mission: "ms_1", num: 63, seq: 200, kind: .userInput, created: 5),
        ])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.id), ["ml_2", "ml_1"])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").first?.seq, 200)
        try store.replaceMilestones(missionID: "ms_1", [milestone("ml_2", mission: "ms_1", num: 63, seq: 200, created: 5)])
        XCTAssertEqual(try store.milestones(missionID: "ms_1").map(\.id), ["ml_2"], "a replace drops rows the server no longer returns")
    }

    func testMilestonesByConversationAreNewestFirst() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMilestones(missionID: "ms_1", [
            milestone("ml_1", mission: "ms_1", num: 62, convo: "c1", seq: 100, created: 1),
            milestone("ml_2", mission: "ms_1", num: 63, convo: "c9", seq: 900, created: 9),
            milestone("ml_3", mission: "ms_1", num: 64, convo: "c1", seq: 300, created: 3),
        ])
        XCTAssertEqual(try store.milestones(convoID: "c1").map(\.id), ["ml_3", "ml_1"])
        XCTAssertEqual(try store.milestones(convoID: "nope"), [])
    }

    /// A conversation's mission: origin first, then any milestone posted in
    /// it (the join / inheritance cases, which the snapshot never carries).
    func testMissionIDForConversationPrefersOriginThenMilestone() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61, convo: "c1")])
        try store.replaceMilestones(missionID: "ms_1", [milestone("ml_1", mission: "ms_1", num: 62, convo: "c7", seq: 10, created: 1)])
        XCTAssertEqual(try store.missionID(convoID: "c1"), "ms_1", "origin conversation")
        XCTAssertEqual(try store.missionID(convoID: "c7"), "ms_1", "joined conversation, learned from its milestone")
        XCTAssertNil(try store.missionID(convoID: "c8"))
    }

    func testMissionConversationsAreReplacedWholesale() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMissionConversations(missionID: "ms_1", [
            MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running"),
            MissionConversation(id: "c2", title: "Other", box: nil, state: "idle"),
        ])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1").map(\.id), ["c1", "c2"])
        XCTAssertNil(try store.missionConversations(missionID: "ms_1").last?.box)
        try store.replaceMissionConversations(missionID: "ms_1", [MissionConversation(id: "c2", title: "Other", box: nil, state: "idle")])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1").map(\.id), ["c2"])
    }

    /// The mission page's open items come from the local item cache, with
    /// the ones awaiting the user first.
    func testItemsForMissionPutAwaitingYouFirst() throws {
        let store = try makeStore()
        try store.upsertItems([
            TrackerItem(id: "it_1", num: 1, kind: .task, awaiting: .agent, title: "agent one",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 9), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_2", num: 2, kind: .question, awaiting: .user, title: "needs you",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 1), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_3", num: 3, kind: .task, state: .closed, title: "done",
                        originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: 8), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_4", num: 4, kind: .task, awaiting: .agent, title: "other mission",
                        originConvoID: "c2", updatedAt: Date(timeIntervalSince1970: 7), missionID: "ms_9", missionNum: 99),
        ])
        XCTAssertEqual(try store.items(missionID: "ms_1").map(\.id), ["it_2", "it_1"],
                       "awaiting-you first, then updatedAt desc; closed items are excluded")
    }

    func testMissionsStreamEmitsOnWrite() async throws {
        let store = try makeStore()
        var iterator = store.missionsStream(state: .open).makeAsyncIterator()
        _ = await iterator.next()   // initial (empty) value
        try store.upsertMissions([mission("ms_1", num: 61)])
        let next = await iterator.next()
        XCTAssertEqual(next?.map(\.id) ?? [], ["ms_1"])
    }

    func testWipeClearsTheMissionCache() throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61)])
        try store.replaceMilestones(missionID: "ms_1", [milestone("ml_1", mission: "ms_1", num: 62, seq: 1, created: 1)])
        try store.replaceMissionConversations(missionID: "ms_1", [MissionConversation(id: "c1", title: "S", box: nil, state: "idle")])
        try store.setMissionsWatermark(Date(timeIntervalSince1970: 100))
        try store.wipe()
        XCTAssertEqual(try store.missions(state: nil), [])
        XCTAssertEqual(try store.milestones(missionID: "ms_1"), [])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1"), [])
        XCTAssertNil(try store.missionsWatermark())
    }

    func testMissionsWatermarkRoundTrips() throws {
        let store = try makeStore()
        XCTAssertNil(try store.missionsWatermark())
        try store.setMissionsWatermark(Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(try store.missionsWatermark(), Date(timeIntervalSince1970: 1234))
        try store.wipeMissions()
        XCTAssertNil(try store.missionsWatermark())
    }
}
