import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreProjectsTests: XCTestCase {
    func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }

    static func project(_ id: String, num: Int, state: MissionState = .open, title: String? = nil,
                        needsYou: Int = 0, lastActivity: TimeInterval? = 10, mergedInto: String? = nil) -> Project {
        Project(id: id, num: num, state: state, title: title ?? "P\(num)", body: "goal",
                status: "Going well.", statusBy: .agent, statusUpdatedAt: Date(timeIntervalSince1970: 9),
                mergedInto: mergedInto, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                missions: ProjectMissionCounts(running: 1, waiting: 2, idle: 0, quiet: 1, closed: 4),
                needsYou: needsYou, openItems: 7, lastActivityAt: lastActivity.map { Date(timeIntervalSince1970: $0) })
    }

    /// v14 is additive: a cache at v13 keeps every row and gains NULL
    /// columns plus the empty `project` table.
    func testV14MigratesUpFromV13() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "v13")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO mission(id, num, state, title, origin_convo_id, created_by, created_at, updated_at)
                VALUES('ms_1', 61, 'open', 'Existing', 'c1', 'agent', 1, 2);
                INSERT INTO mission_conversation(mission_id, convo_id, title, box, state)
                VALUES('ms_1', 'c1', 'Session', 'dev-2', 'running');
                """)
        }
        try JournalStore.migrator().migrate(queue)
        try queue.read { db in
            let mission = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT title, project_id, project_num, activity FROM mission"))
            XCTAssertEqual(mission["title"], "Existing")
            XCTAssertNil(mission["project_id"] as String?)
            XCTAssertNil(mission["activity"] as String?)
            let link = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT title, joined_at, ended_at, how, is_current, parent_convo_id, subchat_count, other_missions_json
                FROM mission_conversation
                """))
            XCTAssertEqual(link["title"], "Session")
            XCTAssertNil(link["ended_at"] as Int64?)
            XCTAssertNil(link["is_current"] as Bool?)
            XCTAssertNil(link["other_missions_json"] as String?)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project"), 0)
            let convoCols = try db.columns(in: "conversation").map(\.name)
            XCTAssertTrue(convoCols.contains("mission_id"))
            XCTAssertTrue(convoCols.contains("mission_count"))
        }
    }

    func testProjectRecordRoundTrips() throws {
        let store = try makeStore()
        let p = Self.project("pj_1", num: 4000, needsYou: 6, mergedInto: "pj_2")
        try store.dbQueue.write { db in try ProjectRecord(p).insert(db) }
        let back = try store.dbQueue.read { db in try ProjectRecord.fetchOne(db, key: "pj_1")?.project }
        XCTAssertEqual(back, p)
    }

    func testMissionAndLinkColumnsRoundTrip() throws {
        let store = try makeStore()
        let mission = Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1",
                              createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                              projectID: "pj_1", projectNum: 4000, activity: .quiet)
        try store.upsertMissions([mission])
        XCTAssertEqual(try store.mission(id: "ms_1"), mission)
        let link = MissionConversation(id: "c1", title: "S", box: "greg", state: "running", isCurrent: true,
                                       joinedAt: Date(timeIntervalSince1970: 3), endedAt: nil, how: "origin",
                                       parentConvoID: nil, subchatCount: 6,
                                       otherMissions: [MissionOtherLink(id: "ms_2", num: 62, title: "Other", isCurrent: true,
                                                                        joinedAt: Date(timeIntervalSince1970: 4))])
        try store.replaceMissionConversations(missionID: "ms_1", [link])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1"), [link], "other_missions survives the cache")
    }

    func testWipeMissionsClearsProjects() throws {
        let store = try makeStore()
        try store.dbQueue.write { db in try ProjectRecord(Self.project("pj_1", num: 1)).insert(db) }
        try store.wipeMissions()
        XCTAssertEqual(try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") }, 0)
    }
}
