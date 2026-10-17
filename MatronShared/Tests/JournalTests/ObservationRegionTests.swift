import GRDB
import XCTest
import os
@testable import MatronJournal
import MatronModels

/// The region each store observation tracks, pinned on a pool, and where
/// its re-fetches run.
///
/// An observation whose tables and rows do not depend on what it reads is
/// a constant-region one (`trackingConstantRegion`): on a `DatabasePool`
/// GRDB re-fetches it on a reader, concurrently with the next write. A
/// plain `tracking` observation is re-fetched on the writer, inside the
/// commit that invalidated it. Each test here inserts a row into every
/// table the observation does not read (it must not fetch) and then into
/// each table it does (it must fetch once per commit), and watches the
/// writer connection's statements throughout: a re-fetch on the writer
/// shows up there as a `SELECT`.
final class ObservationRegionTests: XCTestCase {
    /// Every table in the store's schema, with an insert that adds a fresh
    /// row. An insert reaches every region on its table, whatever columns
    /// the region reads, so it is the one write that must fire an
    /// observation of that table.
    enum Table: String, CaseIterable {
        case conversation, event, meta, outbox
        case summaryEntry = "summary_entry"
        case agent, item
        case itemComment = "item_comment"
        case itemOutbox = "item_outbox"
        case mission, milestone
        case missionConversation = "mission_conversation"
        case project

        func insert(_ db: Database, key n: Int) throws {
            let k = "\(rawValue)-\(n)"
            switch self {
            case .conversation:
                try db.execute(sql: "INSERT INTO conversation(id) VALUES(?)", arguments: [k])
            case .event:
                try db.execute(sql: """
                    INSERT INTO event(seq, convo_id, ts, sender, type, payload)
                    VALUES(?, 'c-other', 0, 'agent:box-a', 'text', x'7B7D')
                    """, arguments: [n])
            case .meta:
                try db.execute(sql: "INSERT INTO meta(key, value) VALUES(?, '1')", arguments: [k])
            case .outbox:
                try db.execute(sql: "INSERT INTO outbox(local_id, convo_id, body, created_at) VALUES(?, 'c-other', 'b', 0)",
                               arguments: [k])
            case .summaryEntry:
                try db.execute(sql: "INSERT INTO summary_entry(convo_id, seq, toc, detail, created_at) VALUES(?, 1, 't', 'd', 0)",
                               arguments: [k])
            case .agent:
                try db.execute(sql: "INSERT INTO agent(id, name) VALUES(?, 'box')", arguments: [n])
            case .item:
                try db.execute(sql: """
                    INSERT INTO item(id, num, kind, state, rank, title, origin_convo_id, created_by, created_at, updated_at)
                    VALUES(?, ?, 'task', 'open', 0, 't', 'c-other', 'user:alice', 0, 0)
                    """, arguments: [k, n])
            case .itemComment:
                try db.execute(sql: "INSERT INTO item_comment(id, item_id, author, kind, created_at) VALUES(?, 'i-other', 'user:alice', 'comment', 0)",
                               arguments: [k])
            case .itemOutbox:
                try db.execute(sql: "INSERT INTO item_outbox(local_id, op, payload_json, created_at) VALUES(?, 'create', '{}', 0)",
                               arguments: [k])
            case .mission:
                try db.execute(sql: """
                    INSERT INTO mission(id, num, state, title, origin_convo_id, created_by, created_at, updated_at)
                    VALUES(?, ?, 'open', 't', 'c-other', 'user:alice', 0, 0)
                    """, arguments: [k, n])
            case .milestone:
                try db.execute(sql: """
                    INSERT INTO milestone(id, mission_id, num, kind, title, convo_id, seq, created_by, created_at)
                    VALUES(?, 'm-other', ?, 'progress', 't', 'c-other', 1, 'user:alice', 0)
                    """, arguments: [k, n])
            case .missionConversation:
                try db.execute(sql: "INSERT INTO mission_conversation(mission_id, convo_id) VALUES(?, 'c-other')", arguments: [k])
            case .project:
                try db.execute(sql: """
                    INSERT INTO project(id, num, state, title, created_by, created_at, updated_at)
                    VALUES(?, ?, 'open', 't', 'user:alice', 0, 0)
                    """, arguments: [k, n])
            }
        }
    }

    /// Fetch counts per observation name, summed across `drain()`s.
    private final class Fires {
        let metrics = StoreMetrics()
        private var totals: [String: Int] = [:]

        func count(_ name: String) -> Int {
            for o in metrics.drain().observations { totals[o.name, default: 0] += o.fires }
            return totals[name] ?? 0
        }

        /// Waits until `name` has fetched at least `n` times, then returns
        /// the count; gives up after `timeout`.
        func wait(_ name: String, atLeast n: Int, timeout: Duration = .seconds(5)) async throws -> Int {
            let deadline = ContinuousClock.now + timeout
            while count(name) < n, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            return count(name)
        }
    }

    /// Every statement the writer connection runs from the moment it is
    /// installed. A pool's writer is one connection, so a `SELECT` logged
    /// here is a fetch the writer ran.
    private final class WriterTrace: @unchecked Sendable {
        private let statements = OSAllocatedUnfairLock(initialState: [String]())

        init(_ writer: any DatabaseWriter) throws {
            try writer.writeWithoutTransaction { db in
                db.trace(options: .statement) { [statements] event in
                    guard case let .statement(s) = event else { return }
                    statements.withLock { $0.append(s.sql) }
                }
            }
        }

        func reset() { statements.withLock { $0.removeAll() } }

        var selects: [String] {
            statements.withLock { $0 }.filter {
                let sql = $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return sql.hasPrefix("SELECT") || sql.hasPrefix("WITH")
            }
        }
    }

    private var nextKey = 0

    private func insert(_ table: Table, in store: JournalStore) throws {
        nextKey += 1
        let n = nextKey
        try store.db.write { db in try table.insert(db, key: n) }
    }

    /// Synchronous on purpose: inside an async test, `db.write` resolves
    /// to GRDB's async overload.
    private func execute(_ sql: String, in store: JournalStore) throws {
        try store.db.write { db in try db.execute(sql: sql) }
    }

    /// Pins `name`'s region to `reads` on a pool: inserting into every
    /// other table fetches nothing, inserting into each of `reads` fetches
    /// once, and none of those fetches runs on the writer.
    private func assertConstantRegion<V: Sendable>(
        _ name: String, reads: Set<Table>,
        file: StaticString = #filePath, line: UInt = #line,
        _ subscribe: (JournalStore) -> AsyncStream<V>
    ) async throws {
        let fires = Fires()
        let store = try makeTestStore(.pool, metrics: fires.metrics)
        let trace = try WriterTrace(store.db)
        let stream = subscribe(store)
        let consumer = Task { for await _ in stream {} }
        defer { consumer.cancel() }
        let own = Table.allCases.filter(reads.contains)
        XCTAssertFalse(own.isEmpty, "no tables to read", file: file, line: line)

        // The initial fetch, then one write it reads: once that has
        // fetched, the observer is on the writer. (Had the write landed
        // before the observer, GRDB's catch-up fetch at install counts
        // instead, and runs on the writer whatever the mode.)
        let initial = try await fires.wait(name, atLeast: 1)
        XCTAssertEqual(initial, 1, "\(name) initial fetch", file: file, line: line)
        try insert(own[0], in: store)
        let warm = try await fires.wait(name, atLeast: 2)
        XCTAssertEqual(warm, 2, "\(name) warm-up", file: file, line: line)
        trace.reset()

        for table in Table.allCases where !reads.contains(table) {
            try insert(table, in: store)
        }
        for (i, table) in own.enumerated() {
            try insert(table, in: store)
            let seen = try await fires.wait(name, atLeast: 2 + i + 1)
            XCTAssertGreaterThanOrEqual(seen, 2 + i + 1, "\(name) did not fetch for \(table.rawValue)", file: file, line: line)
        }
        // A fetch for an unrelated insert would still be in flight or
        // queued behind the last one: let it land before counting.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fires.count(name) - 2, own.count,
                       "\(name) fetched for a table outside \(reads.map(\.rawValue).sorted())",
                       file: file, line: line)
        XCTAssertEqual(trace.selects, [], "\(name) fetched on the writer", file: file, line: line)
    }

    // MARK: The table list

    func testTheTableListCoversTheSchema() throws {
        let store = try makeTestStore(.pool)
        let tables = try store.db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                """)
        }
        XCTAssertEqual(Set(tables), Set(Table.allCases.map(\.rawValue)),
                       "a table the region tests do not write would go unpinned")
    }

    // MARK: Where fetches run

    /// The control for every `trace.selects == []` below: on a queue there
    /// is one connection, so a converted observation still fetches inside
    /// the commit, and the trace sees it.
    func testOnAQueueTheFetchStillRunsInsideTheCommit() async throws {
        let fires = Fires()
        let store = try makeTestStore(.queue, metrics: fires.metrics)
        let trace = try WriterTrace(store.db)
        let stream = store.outboxStream(convoID: "c1")
        let consumer = Task { for await _ in stream {} }
        defer { consumer.cancel() }
        _ = try await fires.wait("outboxStream", atLeast: 1)
        trace.reset()
        try insert(.outbox, in: store)
        // Synchronous on a queue: fetched by the time the write returns.
        XCTAssertEqual(fires.count("outboxStream"), 2)
        XCTAssertEqual(trace.selects.count, 1, "\(trace.selects)")
    }

    /// `missionsStream(convoID:)` reads missions by the keys it has just
    /// read, so its region is not constant and it stays `tracking`: on a
    /// pool GRDB re-fetches it on the writer.
    func testTheDataDependentMissionsStreamStillFetchesOnTheWriter() async throws {
        let fires = Fires()
        let store = try makeTestStore(.pool, metrics: fires.metrics)
        let trace = try WriterTrace(store.db)
        let stream = store.missionsStream(convoID: "c1")
        let consumer = Task { for await _ in stream {} }
        defer { consumer.cancel() }
        _ = try await fires.wait("missionsStream.convo", atLeast: 1)
        try insert(.missionConversation, in: store)
        _ = try await fires.wait("missionsStream.convo", atLeast: 2)
        trace.reset()
        try insert(.missionConversation, in: store)
        XCTAssertEqual(fires.count("missionsStream.convo"), 3, "fetched inside the commit")
        XCTAssertFalse(trace.selects.isEmpty)
    }

    /// `missionsStream(convoID:)` by value: the link and its mission land
    /// in separate commits, and the mission still appears. (This one alone
    /// does not need `tracking`: the fetch reads the `mission` table on
    /// every run, even with no keys to look up.)
    func testTheDataDependentMissionsStreamSeesAMissionThatArrivesAfterItsLink() async throws {
        let fires = Fires()
        let store = try makeTestStore(.pool, metrics: fires.metrics)
        let latest = OSAllocatedUnfairLock(initialState: [String]?.none)
        let stream = store.missionsStream(convoID: "c1")
        let consumer = Task { for await m in stream { latest.withLock { $0 = m.links.map(\.id) } } }
        defer { consumer.cancel() }
        _ = try await fires.wait("missionsStream.convo", atLeast: 1)
        try execute("INSERT INTO mission_conversation(mission_id, convo_id) VALUES('m1', 'c1')", in: store)
        _ = try await fires.wait("missionsStream.convo", atLeast: 2)
        try execute("""
            INSERT INTO mission(id, num, state, title, origin_convo_id, created_by, created_at, updated_at)
            VALUES('m1', 1, 'open', 't', 'c-other', 'user:alice', 0, 0)
            """, in: store)
        let deadline = ContinuousClock.now + .seconds(5)
        while latest.withLock({ $0 }) != ["m1"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(latest.withLock { $0 }, ["m1"])
    }

    /// What does need `tracking`: a conversation whose snapshot fields are
    /// known never reads `milestone`; once they are not (an old journal),
    /// the legacy derivation does. A region recorded on the first fetch
    /// would miss the milestone that later names the current mission.
    func testTheDataDependentMissionsStreamFollowsItsLegacyBranchIntoMilestones() async throws {
        let fires = Fires()
        let store = try makeTestStore(.pool, metrics: fires.metrics)
        try execute("INSERT INTO conversation(id, mission_count) VALUES('c1', 0)", in: store)
        try execute("""
            INSERT INTO mission(id, num, state, title, origin_convo_id, created_by, created_at, updated_at)
            VALUES('m1', 1, 'open', 't', 'c-other', 'user:alice', 0, 0)
            """, in: store)
        let latest = OSAllocatedUnfairLock(initialState: [String]?.none)
        let stream = store.missionsStream(convoID: "c1")
        let consumer = Task { for await m in stream { latest.withLock { $0 = m.links.map(\.id) } } }
        defer { consumer.cancel() }
        _ = try await fires.wait("missionsStream.convo", atLeast: 1)
        try execute("UPDATE conversation SET mission_count = NULL WHERE id = 'c1'", in: store)
        _ = try await fires.wait("missionsStream.convo", atLeast: 2)
        try execute("""
            INSERT INTO milestone(id, mission_id, num, kind, title, convo_id, seq, created_by, created_at)
            VALUES('ms1', 'm1', 2, 'progress', 't', 'c1', 1, 'user:alice', 0)
            """, in: store)
        let deadline = ContinuousClock.now + .seconds(2)
        while latest.withLock({ $0 }) != ["m1"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(latest.withLock { $0 }, ["m1"], "the milestone's mission never reached the stream")
    }

    /// The point of the conversion: a commit's re-fetch no longer holds
    /// the writer. The observation still delivers the committed value,
    /// fetched on a reader while the writer runs nothing but the write.
    func testAConstantRegionFetchRunsOnAReaderAndStillDelivers() async throws {
        let fires = Fires()
        let store = try makeTestStore(.pool, metrics: fires.metrics)
        let trace = try WriterTrace(store.db)
        let latest = OSAllocatedUnfairLock(initialState: [String]?.none)
        let stream = store.outboxStream(convoID: "c1")
        let consumer = Task { for await rows in stream { latest.withLock { $0 = rows.map(\.localID) } } }
        defer { consumer.cancel() }
        _ = try await fires.wait("outboxStream", atLeast: 1)
        try insert(.outbox, in: store)
        _ = try await fires.wait("outboxStream", atLeast: 2)
        trace.reset()

        try execute("INSERT INTO outbox(local_id, convo_id, body, created_at) VALUES('o1', 'c1', 'b', 0)", in: store)
        let deadline = ContinuousClock.now + .seconds(5)
        while latest.withLock({ $0 }) != ["o1"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(latest.withLock { $0 }, ["o1"])
        XCTAssertEqual(fires.count("outboxStream"), 3)
        XCTAssertEqual(trace.selects, [], "the writer ran the fetch")
    }

    // MARK: JournalStore

    func testConsentEventsStream() async throws {
        try await assertConstantRegion("consentEventsStream", reads: [.event]) { $0.consentEventsStream(convoID: "c1") }
    }

    func testQueuedReleaseEventsStream() async throws {
        try await assertConstantRegion("queuedReleaseEventsStream", reads: [.event]) { $0.queuedReleaseEventsStream(convoID: "c1") }
    }

    func testConversationsStream() async throws {
        try await assertConstantRegion("conversationsStream", reads: [.conversation]) { $0.conversationsStream() }
    }

    func testAgentNamesStream() async throws {
        try await assertConstantRegion("agentNamesStream", reads: [.agent]) { $0.agentNamesStream() }
    }

    func testAgentRosterStream() async throws {
        try await assertConstantRegion("agentRosterStream", reads: [.agent]) { $0.agentRosterStream() }
    }

    func testChildrenStream() async throws {
        try await assertConstantRegion("childrenStream", reads: [.conversation]) { $0.childrenStream(of: "c1") }
    }

    func testSessionStateStream() async throws {
        try await assertConstantRegion("sessionStateStream", reads: [.conversation]) { $0.sessionStateStream(convoID: "c1") }
    }

    func testMissionRoomsStream() async throws {
        try await assertConstantRegion("missionRoomsStream", reads: [.conversation]) { $0.missionRoomsStream() }
    }

    func testSessionStatesStream() async throws {
        try await assertConstantRegion("sessionStatesStream", reads: [.conversation]) { $0.sessionStatesStream() }
    }

    func testOutboxStream() async throws {
        try await assertConstantRegion("outboxStream", reads: [.outbox]) { $0.outboxStream(convoID: "c1") }
    }

    func testEventsStream() async throws {
        try await assertConstantRegion("eventsStream", reads: [.event]) { $0.eventsStream(convoID: "c1", sinceSeq: 0) }
    }

    func testSummaryEntriesStream() async throws {
        try await assertConstantRegion("summaryEntriesStream", reads: [.summaryEntry]) { $0.summaryEntriesStream(convoID: "c1") }
    }

    func testArchivedConversationsStream() async throws {
        try await assertConstantRegion("archivedConversationsStream", reads: [.conversation]) { $0.archivedConversationsStream() }
    }

    // MARK: JournalStore+Items

    func testConversationOriginStream() async throws {
        try await assertConstantRegion("conversationOriginStream", reads: [.conversation, .agent]) { $0.conversationOriginStream(id: "c1") }
    }

    func testKnownConversationIDsStream() async throws {
        try await assertConstantRegion("knownConversationIDsStream", reads: [.conversation]) { $0.knownConversationIDsStream(among: ["c1", "c2"]) }
    }

    func testItemsStreamAll() async throws {
        try await assertConstantRegion("itemsStream.all", reads: [.item]) { $0.itemsStream(scope: .all) }
    }

    func testItemsStreamConvo() async throws {
        try await assertConstantRegion("itemsStream.convo", reads: [.item]) { $0.itemsStream(scope: .convo("c1")) }
    }

    func testItemStream() async throws {
        try await assertConstantRegion("itemStream", reads: [.item]) { $0.itemStream(id: "i1") }
    }

    func testCommentsStream() async throws {
        try await assertConstantRegion("commentsStream", reads: [.itemComment]) { $0.commentsStream(itemID: "i1") }
    }

    func testNeedsUserCountsStream() async throws {
        try await assertConstantRegion("needsUserCountsStream", reads: [.item]) { $0.needsUserCountsStream() }
    }

    func testItemOutboxStream() async throws {
        try await assertConstantRegion("itemOutboxStream", reads: [.itemOutbox]) { $0.itemOutboxStream(itemID: "i1") }
    }

    func testItemOutboxCreatesStream() async throws {
        try await assertConstantRegion("itemOutboxCreatesStream", reads: [.itemOutbox]) { $0.itemOutboxCreatesStream() }
    }

    func testItemsStreamMission() async throws {
        try await assertConstantRegion("itemsStream.mission", reads: [.item]) { $0.itemsStream(missionID: "m1") }
    }

    func testClosedItemsCountStream() async throws {
        try await assertConstantRegion("closedItemsCountStream", reads: [.item]) { $0.closedItemsCountStream(missionID: "m1") }
    }

    func testClosedItemsStream() async throws {
        try await assertConstantRegion("closedItemsStream", reads: [.item]) { $0.closedItemsStream(missionID: "m1", limit: 50) }
    }

    // MARK: JournalStore+Missions

    func testMissionsStreamByState() async throws {
        for state in [nil, MissionState.open, .closed] {
            try await assertConstantRegion("missionsStream.state", reads: [.mission]) { $0.missionsStream(state: state) }
        }
    }

    func testMissionStream() async throws {
        try await assertConstantRegion("missionStream", reads: [.mission]) { $0.missionStream(id: "m1") }
    }

    func testMilestonesStream() async throws {
        try await assertConstantRegion("milestonesStream", reads: [.milestone]) { $0.milestonesStream(missionID: "m1") }
    }

    func testMissionConversationsStream() async throws {
        try await assertConstantRegion("missionConversationsStream", reads: [.missionConversation]) { $0.missionConversationsStream(missionID: "m1") }
    }

    func testAllMissionConversationsStream() async throws {
        try await assertConstantRegion("allMissionConversationsStream", reads: [.missionConversation]) { $0.allMissionConversationsStream() }
    }

    func testLatestMilestonesStream() async throws {
        try await assertConstantRegion("latestMilestonesStream", reads: [.milestone]) { $0.latestMilestonesStream() }
    }

    func testNeedsYouItemsByMissionStream() async throws {
        try await assertConstantRegion("needsYouItemsByMissionStream", reads: [.item]) { $0.needsYouItemsByMissionStream() }
    }

    func testLatestSummaryTOCsStream() async throws {
        try await assertConstantRegion("latestSummaryTOCsStream", reads: [.summaryEntry]) { $0.latestSummaryTOCsStream() }
    }

    // MARK: JournalStore+Projects

    func testProjectsStream() async throws {
        try await assertConstantRegion("projectsStream", reads: [.project]) { $0.projectsStream() }
    }

    func testProjectStream() async throws {
        try await assertConstantRegion("projectStream", reads: [.project]) { $0.projectStream(id: "p1") }
    }

    func testProjectSessionsByBoxStream() async throws {
        try await assertConstantRegion("projectSessionsByBoxStream", reads: [.project]) { $0.projectSessionsByBoxStream(id: "p1") }
    }

    func testProjectFeedStream() async throws {
        try await assertConstantRegion("projectFeedStream", reads: [.project]) { $0.projectFeedStream(id: "p1") }
    }

    func testMissionsStreamByProject() async throws {
        try await assertConstantRegion("missionsStream.project", reads: [.mission]) { $0.missionsStream(projectID: "p1") }
    }

    func testUnfiledOpenMissionsStream() async throws {
        try await assertConstantRegion("unfiledOpenMissionsStream", reads: [.mission]) { $0.unfiledOpenMissionsStream() }
    }

    func testNeedsYouItemsStream() async throws {
        try await assertConstantRegion("needsYouItemsStream", reads: [.item, .mission]) { $0.needsYouItemsStream(projectID: "p1") }
    }

    func testOpenItemsStream() async throws {
        try await assertConstantRegion("openItemsStream", reads: [.item, .mission]) { $0.openItemsStream(projectID: "p1") }
    }

    func testRecentMilestonesStream() async throws {
        try await assertConstantRegion("recentMilestonesStream", reads: [.milestone, .mission]) { $0.recentMilestonesStream(projectID: "p1", limit: 5) }
    }
}
