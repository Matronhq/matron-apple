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
    /// columns plus the empty `project` table. The NULL-handling in
    /// `MissionRecord.mission`, `MissionConversationRecord.conversation`
    /// and `ConversationRecord` only runs when an old row is decoded back
    /// through the store — a raw-SQL column check alone would miss a
    /// force-unwrap or a wrong fallback in those computed properties — so
    /// this seeds a real file-backed database at v13, opens it as a
    /// `JournalStore` (which migrates it to head on init, like a real
    /// upgrade), and reads the old rows back through `store.mission`,
    /// `store.missionConversations` and `store.conversation`.
    func testV14MigratesUpFromV13() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            let seedQueue = try DatabaseQueue(path: url.path)
            try JournalStore.migrator().migrate(seedQueue, upTo: "v13")
            try seedQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversation(id, title, session_state, last_seq, snippet, created_at)
                    VALUES('c1', 'Session', 'running', 1, '', 1);
                    INSERT INTO mission(id, num, state, title, origin_convo_id, created_by, created_at, updated_at)
                    VALUES('ms_1', 61, 'open', 'Existing', 'c1', 'agent', 1, 2);
                    INSERT INTO mission_conversation(mission_id, convo_id, title, box, state)
                    VALUES('ms_1', 'c1', 'Session', 'dev-2', 'running');
                    """)
            }
        }

        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")

        try store.dbQueue.read { db in
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

        // Same rows, decoded through the store's read APIs.
        let mission = try XCTUnwrap(store.mission(id: "ms_1"))
        XCTAssertEqual(mission.title, "Existing")
        XCTAssertNil(mission.projectID)
        XCTAssertNil(mission.projectNum)
        XCTAssertNil(mission.activity)
        XCTAssertNil(mission.lastActivityAt)

        let link = try XCTUnwrap(store.missionConversations(missionID: "ms_1").first)
        XCTAssertEqual(link.title, "Session")
        XCTAssertFalse(link.isCurrent, "a pre-v14 row has no is_current value and reads as false")
        XCTAssertEqual(link.subchatCount, 0)
        XCTAssertNil(link.endedAt)
        XCTAssertNil(link.parentConvoID)
        XCTAssertTrue(link.otherMissions.isEmpty)

        let convo = try XCTUnwrap(store.conversation(id: "c1"))
        XCTAssertNil(convo.missionID)
        XCTAssertNil(convo.missionCount)
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
                              projectID: "pj_1", projectNum: 4000, activity: .quiet,
                              lastActivityAt: Date(timeIntervalSince1970: 50))
        try store.upsertMissions([mission])
        XCTAssertEqual(try store.mission(id: "ms_1"), mission)
        // R3: the server's own last-activity timestamp must round-trip
        // like every other mission column.
        XCTAssertEqual(try store.mission(id: "ms_1")?.lastActivityAt, Date(timeIntervalSince1970: 50))
        let link = MissionConversation(id: "c1", title: "S", box: "greg", state: "running", isCurrent: true,
                                       joinedAt: Date(timeIntervalSince1970: 3), endedAt: nil, how: "origin",
                                       parentConvoID: nil, subchatCount: 6,
                                       otherMissions: [
                                           MissionOtherLink(id: "ms_2", num: 62, title: "Other", isCurrent: true,
                                                            joinedAt: Date(timeIntervalSince1970: 4)),
                                           // An ended link must round-trip too: isActive is derived
                                           // from endedAt, not stored separately.
                                           MissionOtherLink(id: "ms_3", num: 63, title: "Done", isCurrent: false,
                                                            isActive: false, joinedAt: Date(timeIntervalSince1970: 5),
                                                            endedAt: Date(timeIntervalSince1970: 6)),
                                       ])
        try store.replaceMissionConversations(missionID: "ms_1", [link])
        XCTAssertEqual(try store.missionConversations(missionID: "ms_1"), [link], "other_missions survives the cache")
    }

    func testConversationMissionFieldsRoundTrip() throws {
        let store = try makeStore()
        try store.dbQueue.write { db in
            let convo = ConversationRecord(id: "c1", title: "T", sessionState: "running", lastSeq: 1, snippet: "",
                                           createdAt: 1, muted: false, hidden: false, readUpToSeq: 0, unreadCount: 0,
                                           missionID: "ms_1", missionCount: 3)
            try convo.insert(db)
        }
        let back = try XCTUnwrap(store.conversation(id: "c1"))
        XCTAssertEqual(back.missionID, "ms_1")
        XCTAssertEqual(back.missionCount, 3)
    }

    func testWipeMissionsClearsProjects() throws {
        let store = try makeStore()
        try store.dbQueue.write { db in try ProjectRecord(Self.project("pj_1", num: 1)).insert(db) }
        try store.wipeMissions()
        XCTAssertEqual(try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") }, 0)
    }

    private func dto(_ id: String, missionID: String?, known: Bool, count: Int?) -> ConvoSummaryDTO {
        ConvoSummaryDTO(id: id, title: "T", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 1,
                        missionID: missionID, missionIDKnown: known, missionCount: count)
    }

    /// Review Focus: null clears the pointer, absent leaves it.
    func testSnapshotMissionPointerNullClearsAbsentKeeps() throws {
        let store = try makeStore()
        try store.refreshSummaries([dto("c1", missionID: "ms_1", known: true, count: 2),
                                    dto("c2", missionID: "ms_2", known: true, count: 1)])
        XCTAssertEqual(try store.conversation(id: "c1")?.missionID, "ms_1")
        XCTAssertEqual(try store.conversation(id: "c1")?.missionCount, 2)

        try store.refreshSummaries([dto("c1", missionID: nil, known: true, count: 2),
                                    dto("c2", missionID: nil, known: false, count: nil)])
        XCTAssertNil(try store.conversation(id: "c1")?.missionID, "null: the conversation left its last mission")
        XCTAssertEqual(try store.conversation(id: "c2")?.missionID, "ms_2", "absent: an old journal says nothing")
        XCTAssertEqual(try store.conversation(id: "c2")?.missionCount, 1)
    }
}
