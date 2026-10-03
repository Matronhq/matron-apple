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

    /// v15 adds `conversation.participant_convos`. A pre-v15 row must read
    /// back through the store with no participant conversations (so a
    /// room stays off every mission view until the next snapshot).
    func testV15AddsParticipantConvosColumn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            let seedQueue = try DatabaseQueue(path: url.path)
            try JournalStore.migrator().migrate(seedQueue, upTo: "v14")
            try seedQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversation(id, title, session_state, last_seq, snippet, created_at, participants)
                    VALUES('room', '🔗 room', 'waiting', 1, '', 1, '[7,9]');
                    """)
            }
        }

        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        try store.dbQueue.read { db in
            XCTAssertTrue(try db.columns(in: "conversation").map(\.name).contains("participant_convos"))
        }
        let room = try XCTUnwrap(store.conversation(id: "room"))
        XCTAssertNil(room.participantConvos)
        XCTAssertEqual(room.participantConvoIDs, [])
        XCTAssertEqual(room.participantIDs, [7, 9])
    }

    /// v16 adds `project.card_json` and `project.feed_json`. A project
    /// cached at v15 reads back through the store unchanged, with no card
    /// and no feed, and keeps its detail's sessions.
    func testV16AddsCardAndFeedColumns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("journal.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Sync helpers: inside an async test GRDB's `write`/`read` resolve
        // to their async overloads.
        func seed() throws {
            let seedQueue = try DatabaseQueue(path: url.path)
            try JournalStore.migrator().migrate(seedQueue, upTo: "v15")
            try seedQueue.write { db in
                XCTAssertFalse(try db.columns(in: "project").map(\.name).contains("card_json"))
                try db.execute(sql: """
                    INSERT INTO project(id, num, state, title, created_by, created_at, updated_at, needs_you,
                                        sessions_by_box_json)
                    VALUES('pj_1', 4000, 'open', 'Promo', 'agent', 1000, 2000, 3, '{"greg":2}');
                    """)
            }
        }
        func projectColumns(_ store: JournalStore) throws -> [String] {
            try store.dbQueue.read { db in try db.columns(in: "project").map(\.name) }
        }
        try seed()

        let store = try JournalStore(databaseURL: url, ownSender: "user:dan")
        let cols = try projectColumns(store)
        XCTAssertTrue(cols.contains("card_json"))
        XCTAssertTrue(cols.contains("feed_json"))
        let project = try XCTUnwrap(store.project(id: "pj_1"))
        XCTAssertEqual(project.title, "Promo"); XCTAssertEqual(project.needsYou, 3)
        XCTAssertNil(project.card); XCTAssertEqual(project.sessionsNow, 0)
        let feed = try await firstValue(store.projectFeedStream(id: "pj_1"))
        XCTAssertNil(feed)
        let sessions = try await firstValue(store.projectSessionsByBoxStream(id: "pj_1"))
        XCTAssertEqual(sessions, ["greg": 2])
    }

    static let card = ProjectCardFields(
        waitingOn: ProjectWaitingOn(itemID: "it_9", num: 90, kind: .question, title: "Q", missionNum: 61, more: 1),
        latest: ProjectLatest(title: "Shipped", kind: .progress, at: Date(timeIntervalSince1970: 7), missionNum: 61),
        sessionsNow: 2)

    static let feed = ProjectFeed(
        decisions: ProjectFeedPage(total: 3, rows: [ProjectDecision(id: "it_d", num: 91, kind: .decision, title: "D",
                                                                    createdAt: Date(timeIntervalSince1970: 3))],
                                   nextBefore: "3000:000000000091"),
        files: ProjectFeedPage(total: 1, rows: [ProjectFile(blobID: "b_1", name: "a.png", contentType: "image/png",
                                                            source: .chat(convoID: "c1", seq: 5),
                                                            postedAt: Date(timeIntervalSince1970: 4))]),
        milestones: ProjectFeedPage(total: 1, rows: [ProjectMilestone(
            milestone: Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress, title: "a", convoID: "c1",
                                 seq: 1, createdAt: Date(timeIntervalSince1970: 20)), missionNum: 61)]))

    static func withCard(_ p: Project, _ card: ProjectCardFields?) -> Project {
        Project(id: p.id, num: p.num, state: p.state, title: p.title, body: p.body, status: p.status,
                statusBy: p.statusBy, statusUpdatedAt: p.statusUpdatedAt, mergedInto: p.mergedInto,
                createdAt: p.createdAt, updatedAt: p.updatedAt, missions: p.missions, needsYou: p.needsYou,
                openItems: p.openItems, lastActivityAt: p.lastActivityAt, card: card)
    }

    /// Detail direction: the detail route's project carries no card
    /// fields, so a detail upsert (or a create) must keep the card the
    /// list wrote — while still taking the detail's other columns.
    func testADetailUpsertKeepsTheListsCard() throws {
        let store = try makeStore()
        try store.replaceProjects([Self.withCard(Self.project("pj_1", num: 1), Self.card)])
        XCTAssertEqual(try store.project(id: "pj_1")?.card, Self.card)
        let detailRow = Self.project("pj_1", num: 1, title: "Renamed by detail")
        XCTAssertNil(detailRow.card)
        try store.upsertProjects([detailRow])
        try store.setProjectFeed(id: "pj_1", Self.feed)
        let back = try XCTUnwrap(store.project(id: "pj_1"))
        XCTAssertEqual(back.title, "Renamed by detail")
        XCTAssertEqual(back.card, Self.card, "a detail upsert must not wipe card_json")
        XCTAssertEqual(back.waitingOn?.itemID, "it_9"); XCTAssertEqual(back.sessionsNow, 2)
    }

    /// List direction: a list refresh keeps the detail's feed (and its
    /// sessions), and replaces the card — with an empty one too, since a
    /// row that sends the fields as null means "nothing waiting".
    func testAListRefreshKeepsTheDetailsFeedAndReplacesTheCard() async throws {
        let store = try makeStore()
        try store.upsertProjects([Self.project("pj_1", num: 1)])
        try store.setProjectFeed(id: "pj_1", Self.feed)
        try store.setProjectSessionsByBox(id: "pj_1", ["greg": 1])
        try store.replaceProjects([Self.withCard(Self.project("pj_1", num: 1), Self.card)])
        let feed = try await firstValue(store.projectFeedStream(id: "pj_1"))
        XCTAssertEqual(feed, Self.feed, "a list refresh must not wipe feed_json")
        XCTAssertEqual(try store.project(id: "pj_1")?.card, Self.card)
        try store.upsertProjects([Self.withCard(Self.project("pj_1", num: 1), ProjectCardFields())])
        XCTAssertEqual(try store.project(id: "pj_1")?.card, ProjectCardFields(), "sent empty replaces")
        let kept = try await firstValue(store.projectFeedStream(id: "pj_1"))
        XCTAssertEqual(kept, Self.feed)
        let sessions = try await firstValue(store.projectSessionsByBoxStream(id: "pj_1"))
        XCTAssertEqual(sessions, ["greg": 1])
    }

    /// An older journal's list row carries no card: nothing to replace
    /// with, so the stored one stands (the same absent ≠ null rule).
    func testAListRowWithoutCardFieldsKeepsTheStoredCard() throws {
        let store = try makeStore()
        try store.replaceProjects([Self.withCard(Self.project("pj_1", num: 1), Self.card)])
        try store.replaceProjects([Self.project("pj_1", num: 1)])
        XCTAssertEqual(try store.project(id: "pj_1")?.card, Self.card)
    }

    func testProjectFeedStreamFollowsWrites() async throws {
        let store = try makeStore()
        try store.upsertProjects([Self.project("pj_1", num: 1)])
        var updates = store.projectFeedStream(id: "pj_1").makeAsyncIterator()
        let initial = await updates.next()
        XCTAssertEqual(initial, .some(nil))
        try store.setProjectFeed(id: "pj_1", Self.feed)
        let written = await updates.next()
        XCTAssertEqual(written, .some(Self.feed))
    }

    /// What a tapped `matron://project/<n>` link reads.
    func testProjectLookupByNumber() throws {
        let store = try makeStore()
        try store.upsertProjects([Self.project("pj_1", num: 12), Self.project("pj_2", num: 13)])
        XCTAssertEqual(try store.project(num: 13)?.id, "pj_2")
        XCTAssertNil(try store.project(num: 999))
    }

    func testProjectRecordRoundTrips() throws {
        let store = try makeStore()
        let p = Self.withCard(Self.project("pj_1", num: 4000, needsYou: 6, mergedInto: "pj_2"), Self.card)
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

    private func mission(_ id: String, num: Int, project: String?, state: MissionState = .open,
                         lastMilestoneAt: TimeInterval = 10) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: "c1",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: Date(timeIntervalSince1970: lastMilestoneAt), projectID: project)
    }

    func testReplaceProjectsIsAuthoritativeButKeepsProtectedAndSessions() async throws {
        let store = try makeStore()
        try store.replaceProjects([Self.project("pj_1", num: 1), Self.project("pj_2", num: 2)])
        try store.setProjectSessionsByBox(id: "pj_1", ["greg": 2, "pat": 1])
        try store.upsertProjects([Self.project("pj_3", num: 3)])
        try store.replaceProjects([Self.project("pj_1", num: 1, title: "Renamed")], keeping: ["pj_3"])
        XCTAssertEqual(try store.projects().map(\.id).sorted(), ["pj_1", "pj_3"])
        XCTAssertEqual(try store.project(id: "pj_1")?.title, "Renamed")
        let sessions = try await firstValue(store.projectSessionsByBoxStream(id: "pj_1"))
        XCTAssertEqual(sessions, ["greg": 2, "pat": 1], "a list refresh must not wipe the detail's sessions")
    }

    func testProjectsStreamPutsOpenFirstThenNewestActivity() async throws {
        let store = try makeStore()
        try store.replaceProjects([Self.project("pj_old", num: 1, lastActivity: 5),
                                   Self.project("pj_new", num: 2, lastActivity: 50),
                                   Self.project("pj_closed", num: 3, state: .closed, lastActivity: 99)])
        let projects = try await firstValue(store.projectsStream())
        XCTAssertEqual(projects.map(\.id), ["pj_new", "pj_old", "pj_closed"])
    }

    func testProjectScopedReads() async throws {
        let store = try makeStore()
        try store.upsertMissions([mission("ms_1", num: 61, project: "pj_1", lastMilestoneAt: 20),
                                  mission("ms_2", num: 62, project: "pj_1", lastMilestoneAt: 30),
                                  mission("ms_3", num: 63, project: nil),
                                  mission("ms_4", num: 64, project: nil, state: .closed)])
        try store.upsertItems([
            TrackerItem(id: "it_1", num: 90, kind: .question, awaiting: .user, title: "Q1", originConvoID: "c1",
                        updatedAt: Date(timeIntervalSince1970: 5), missionID: "ms_1", missionNum: 61),
            TrackerItem(id: "it_2", num: 91, kind: .question, awaiting: .user, title: "Q2", originConvoID: "c1",
                        missionID: "ms_3", missionNum: 63),
            TrackerItem(id: "it_3", num: 92, kind: .task, awaiting: .agent, title: "T", originConvoID: "c1",
                        missionID: "ms_2", missionNum: 62),
        ])
        try store.upsertMilestones([
            Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress, title: "a", convoID: "c1", seq: 1,
                      createdAt: Date(timeIntervalSince1970: 20)),
            Milestone(id: "ml_2", missionID: "ms_2", num: 71, kind: .userInput, title: "b", convoID: "c1", seq: 2,
                      createdAt: Date(timeIntervalSince1970: 30)),
            Milestone(id: "ml_3", missionID: "ms_3", num: 72, kind: .progress, title: "c", convoID: "c1", seq: 3,
                      createdAt: Date(timeIntervalSince1970: 40)),
        ])
        let projectMissions = try await firstValue(store.missionsStream(projectID: "pj_1"))
        XCTAssertEqual(projectMissions.map(\.id), ["ms_2", "ms_1"])
        let unfiled = try await firstValue(store.unfiledOpenMissionsStream())
        XCTAssertEqual(unfiled.map(\.id), ["ms_3"])
        let needsYou = try await firstValue(store.needsYouItemsStream(projectID: "pj_1"))
        XCTAssertEqual(needsYou.map(\.id), ["it_1"])
        let openItems = try await firstValue(store.openItemsStream(projectID: "pj_1"))
        XCTAssertEqual(Set(openItems.map(\.id)), ["it_1", "it_3"], "every open item on the project's missions")
        let recent5 = try await firstValue(store.recentMilestonesStream(projectID: "pj_1", limit: 5))
        XCTAssertEqual(recent5.map(\.id), ["ml_2", "ml_1"])
        let recent1 = try await firstValue(store.recentMilestonesStream(projectID: "pj_1", limit: 1))
        XCTAssertEqual(recent1.map(\.id), ["ml_2"])
    }

    private func firstValue<T: Sendable>(_ stream: AsyncStream<T>) async throws -> T {
        for await value in stream { return value }
        throw XCTSkip("stream ended without a value")
    }
}
