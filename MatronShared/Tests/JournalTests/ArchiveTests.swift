import GRDB
import XCTest
@testable import MatronJournal

/// The store's side of archived conversations: the chat-list filter, the
/// Archived list, the message rule, the snapshot, the cursor, and the purge
/// of long-archived history.
final class JournalStoreArchiveTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    private func store() throws -> JournalStore { try makeTestStore(.queue) }

    private func message(_ seq: Int64, convo: String, at ts: Date, sender: String = "agent:a",
                         type: String = JournalEventType.text) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: ts, sender: sender, type: type,
                     payloadData: Data(#"{"body":"m\#(seq)"}"#.utf8))
    }

    private func meta(_ seq: Int64, convo: String, parent: String) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: t0, sender: "agent:a", type: JournalEventType.convoMeta,
                     payloadData: Data(#"{"title":"Sub","parent_convo_id":"\#(parent)"}"#.utf8))
    }

    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    func testArchivedConversationsLeaveTheChatListForTheArchivedList() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "a", at: t0))
        try store.applyJournal(message(2, convo: "b", at: t0.addingTimeInterval(1)))
        try store.applyJournal(message(3, convo: "c", at: t0.addingTimeInterval(2)))

        try store.setArchived(["a", "c"], archived: true, now: t0.addingTimeInterval(10))
        XCTAssertEqual(try store.conversations().map(\.id), ["b"])
        XCTAssertEqual(try store.archivedConversations().map(\.id), ["c", "a"], "most recently active first")
        XCTAssertEqual(try store.conversation(id: "a")?.archivedAt, ms(t0.addingTimeInterval(10)))

        try store.setArchived(["a"], archived: false)
        XCTAssertEqual(try store.conversations().map(\.id), ["b", "a"])
        XCTAssertEqual(try store.archivedConversations().map(\.id), ["c"])
    }

    func testArchivingTwiceKeepsTheFirstTime() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "a", at: t0))
        try store.setArchived(["a"], archived: true, now: t0)
        try store.setArchived(["a"], archived: true, now: t0.addingTimeInterval(60))
        XCTAssertEqual(try store.conversation(id: "a")?.archivedAt, ms(t0))
    }

    func testANewerMessageUnarchivesAndAnOlderReplayedOneDoesNot() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "a", at: t0))
        try store.setArchived(["a"], archived: true, now: t0.addingTimeInterval(100))

        // Replayed from before the archive: stays archived.
        try store.applyJournal(message(2, convo: "a", at: t0.addingTimeInterval(50)))
        XCTAssertTrue(try XCTUnwrap(store.conversation(id: "a")).isArchived)
        // Bookkeeping is not a message.
        try store.applyJournal(JournalEvent(seq: 3, convoID: "a", ts: t0.addingTimeInterval(200), sender: "agent:a",
                                            type: JournalEventType.sessionStatus,
                                            payloadData: Data(#"{"state":"done"}"#.utf8)))
        XCTAssertTrue(try XCTUnwrap(store.conversation(id: "a")).isArchived)
        // The user's own message brings it back too.
        try store.applyJournal(message(4, convo: "a", at: t0.addingTimeInterval(300), sender: "user:alice"))
        XCTAssertFalse(try XCTUnwrap(store.conversation(id: "a")).isArchived)
        XCTAssertEqual(try store.conversations().map(\.id), ["a"])
    }

    func testAMessageInASubChatLeavesItsArchiveAlone() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "p", at: t0))
        try store.applyJournal(meta(2, convo: "p:sub:x", parent: "p"))
        try store.setArchived(["p", "p:sub:x"], archived: true, now: t0)
        try store.applyJournal(message(3, convo: "p:sub:x", at: t0.addingTimeInterval(60)))
        XCTAssertTrue(try XCTUnwrap(store.conversation(id: "p:sub:x")).isArchived)
        XCTAssertTrue(try XCTUnwrap(store.conversation(id: "p")).isArchived)
    }

    func testTheSnapshotArchivesOnlyRowsItCreates() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "known", at: t0))
        try store.refreshSummaries([
            ConvoSummaryDTO(id: "known", title: "K", sessionState: "done", lastSeq: 1, snippet: "", createdAt: 0,
                            archivedAt: 500),
            ConvoSummaryDTO(id: "new", title: "N", sessionState: "done", lastSeq: 2, snippet: "", createdAt: 0,
                            archivedAt: 600),
        ])
        XCTAssertNil(try store.conversation(id: "known")?.archivedAt, "an existing row follows the archive feed only")
        XCTAssertEqual(try store.conversation(id: "new")?.archivedAt, 600)
    }

    func testTheCursorMovesOnlyForwardAndOnlyOnceStored() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "a", at: t0))
        XCTAssertNil(try store.archiveSince())
        try store.applyArchiveChanges([ArchiveChange(convoID: "a", archivedAt: 10)], advancingSinceTo: 20)
        XCTAssertTrue(try XCTUnwrap(store.conversation(id: "a")).isArchived)
        XCTAssertNil(try store.archiveSince(), "the first sync stores the cursor itself, after its carry-over")

        try store.setArchiveSince(20)
        try store.applyArchiveChanges([ArchiveChange(convoID: "a", archivedAt: nil)], advancingSinceTo: 30)
        XCTAssertEqual(try store.archiveSince(), 30)
        XCTAssertFalse(try XCTUnwrap(store.conversation(id: "a")).isArchived)
        try store.applyArchiveChanges([], advancingSinceTo: 25)
        XCTAssertEqual(try store.archiveSince(), 30)
        try store.applyArchiveChanges([ArchiveChange(convoID: "unknown", archivedAt: 1)], advancingSinceTo: 31)
        XCTAssertNil(try store.conversation(id: "unknown"), "a change for a conversation not here is skipped")
    }

    func testAdoptingTheJournalSetKeepsWhatIsArchivedOnlyHere() throws {
        let store = try store()
        for (seq, id) in ["mine", "theirs", "both", "neither"].enumerated() {
            try store.applyJournal(message(Int64(seq + 1), convo: id, at: t0))
        }
        try store.setArchived(["mine", "both"], archived: true, now: t0)
        let toImport = try store.adoptArchiveSet([
            ArchiveChange(convoID: "theirs", archivedAt: 7),
            ArchiveChange(convoID: "both", archivedAt: 8),
        ])
        XCTAssertEqual(toImport, ["mine"])
        XCTAssertEqual(Set(try store.archivedConversations().map(\.id)), ["mine", "theirs", "both"])
        XCTAssertEqual(try store.conversation(id: "both")?.archivedAt, 8, "the journal's time wins")
    }

    func testTheMigrationMovesHiddenRowsToArchived() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.sqlite")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try JournalStore.migrator().migrate(queue, upTo: "item_outbox_rejected")
            try queue.write { db in
                for (id, hidden) in [("left", true), ("kept", false)] {
                    try db.execute(sql: """
                        INSERT INTO conversation (id, title, session_state, last_seq, snippet, created_at, muted, hidden,
                                                  read_up_to_seq, unread_count)
                        VALUES (?, ?, 'done', 1, '', 0, 0, ?, 0, 0)
                        """, arguments: [id, id, hidden])
                }
            }
        }
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let store = try JournalStore(databaseURL: url, ownSender: "user:alice")
        let left = try XCTUnwrap(store.conversation(id: "left"))
        XCTAssertFalse(left.hidden)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(left.archivedAt), before)
        XCTAssertNil(try store.conversation(id: "kept")?.archivedAt)
        XCTAssertEqual(try store.conversations().map(\.id), ["kept"])
        XCTAssertEqual(try store.archivedConversations().map(\.id), ["left"])
        XCTAssertNil(try store.archiveSince(), "the carry-over to the journal is still to do")
    }

    func testThePurgeDropsLongArchivedHistoryAndKeepsTheRows() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "old", at: t0))
        try store.applyJournal(meta(2, convo: "old:sub:x", parent: "old"))
        try store.applyJournal(message(3, convo: "old:sub:x", at: t0))
        try store.applyJournal(message(4, convo: "recent", at: t0))
        try store.applyJournal(message(5, convo: "live", at: t0))
        try store.setArchived(["old"], archived: true, now: t0)
        try store.setArchived(["recent"], archived: true, now: t0.addingTimeInterval(80 * 86_400))

        let now = t0.addingTimeInterval(91 * 86_400)

        XCTAssertEqual(try store.archivedHistoryPurgeCandidates(now: now), ["old"])

        XCTAssertEqual(try store.conversationIDsIncludingSubChats(["old"]), ["old", "old:sub:x"])
        XCTAssertEqual(try store.purgeArchivedHistory(["old"], now: now), ["old", "old:sub:x"])

        XCTAssertEqual(try store.events(convoID: "old"), [])
        XCTAssertEqual(try store.events(convoID: "old:sub:x"), [])
        XCTAssertEqual(try store.events(convoID: "recent").map(\.seq), [4])
        XCTAssertEqual(try store.events(convoID: "live").map(\.seq), [5])
        let old = try XCTUnwrap(store.conversation(id: "old"))
        XCTAssertEqual(old.snippet, "m1", "the row keeps its summary")
        XCTAssertEqual(old.historyPurgedAt, ms(now))
        XCTAssertNotNil(try store.conversation(id: "old:sub:x"))
        XCTAssertEqual(try store.archivedHistoryPurgeCandidates(now: now), [], "purged once")

        // Unarchived and archived again: purged again in its turn.
        try store.setArchived(["old"], archived: false)
        XCTAssertNil(try store.conversation(id: "old")?.historyPurgedAt)
        try store.setArchived(["old"], archived: true, now: now)
        XCTAssertEqual(try store.archivedHistoryPurgeCandidates(now: now.addingTimeInterval(91 * 86_400)),
                       ["recent", "old"], "oldest archive first")

    }

    func testThePurgeSkipsAConversationUnarchivedSinceItWasPicked() throws {
        let store = try store()
        try store.applyJournal(message(1, convo: "a", at: t0))
        try store.setArchived(["a"], archived: true, now: t0)
        let now = t0.addingTimeInterval(91 * 86_400)
        let picked = try store.archivedHistoryPurgeCandidates(now: now)
        try store.setArchived(["a"], archived: false)
        XCTAssertEqual(try store.purgeArchivedHistory(picked, now: now), [])
        XCTAssertEqual(try store.events(convoID: "a").map(\.seq), [1])
    }
}

/// `ArchiveSync` against a real store and a fake journal.
final class ArchiveSyncTests: XCTestCase {
    private actor FakeWriter: ArchiveWriting {
        var calls: [(ids: [String], archived: Bool)] = []
        var failing = false
        var gate: CheckedContinuation<Void, Never>?
        var holds = false

        func setFailing(_ value: Bool) { failing = value }
        func hold() { holds = true }
        func release() {
            holds = false
            gate?.resume()
            gate = nil
        }

        func setArchived(_ convoIDs: [String], archived: Bool) async throws {
            calls.append((convoIDs, archived))
            if holds { await withCheckedContinuation { gate = $0 } }
            if failing { throw JournalAPIError.transport("offline") }
        }
    }

    private func seeded(_ ids: [String]) throws -> JournalStore {
        let store = try makeTestStore(.queue)
        try store.applyColdSnapshot(ids.map {
            ConvoSummaryDTO(id: $0, title: $0, sessionState: "done", lastSeq: 0, snippet: "", createdAt: 0)
        }, headSeq: 0)
        return store
    }

    private func archived(_ store: JournalStore) throws -> Set<String> {
        Set(try store.archivedConversations().map(\.id))
    }

    func testWithoutAJournalArchiveTheArchiveStaysLocal() async throws {
        let store = try seeded(["a"])
        let writer = FakeWriter()
        let sync = ArchiveSync(store: store, writer: writer)
        await sync.applyHello(nil)
        await sync.setArchived(["a"], archived: true)
        await sync.waitUntilIdle()
        XCTAssertEqual(try archived(store), ["a"])
        let calls = await writer.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(sync.helloArchiveSince(), 0)
    }

    func testTheFirstSyncCarriesOverLocalArchivesThenStoresTheCursor() async throws {
        let store = try seeded(["mine", "theirs"])
        try store.setArchived(["mine"], archived: true)
        let writer = FakeWriter()
        let sync = ArchiveSync(store: store, writer: writer)
        await sync.applyHello(ArchiveDelta(changes: [ArchiveChange(convoID: "theirs", archivedAt: 5)], at: 50))
        await sync.waitUntilIdle()
        let calls = await writer.calls
        XCTAssertEqual(calls.map(\.ids), [["mine"]])
        XCTAssertEqual(calls.map(\.archived), [true])
        XCTAssertEqual(try archived(store), ["mine", "theirs"])
        XCTAssertEqual(try store.archiveSince(), 50)
        XCTAssertEqual(sync.helloArchiveSince(), 50)
    }

    func testAFailedCarryOverStoresNoCursorSoTheNextHelloAsksAgain() async throws {
        let store = try seeded(["mine"])
        try store.setArchived(["mine"], archived: true)
        let writer = FakeWriter()
        await writer.setFailing(true)
        let sync = ArchiveSync(store: store, writer: writer)
        await sync.applyHello(ArchiveDelta(changes: [], at: 50))
        await sync.waitUntilIdle()
        XCTAssertNil(try store.archiveSince())
        XCTAssertEqual(try archived(store), ["mine"], "kept here while the carry-over waits")

        await writer.setFailing(false)
        await sync.applyHello(ArchiveDelta(changes: [], at: 60))
        await sync.waitUntilIdle()
        XCTAssertEqual(try store.archiveSince(), 60)
    }

    func testLaterHellosAndFramesApplyChangesAndMoveTheCursor() async throws {
        let store = try seeded(["a", "b"])
        try store.setArchiveSince(10)
        let sync = ArchiveSync(store: store, writer: FakeWriter())
        let syncs = await sync.syncsWithJournal
        XCTAssertTrue(syncs, "assumed from the stored cursor until the first hello")
        await sync.applyHello(ArchiveDelta(changes: [ArchiveChange(convoID: "a", archivedAt: 11)], at: 20))
        XCTAssertEqual(try archived(store), ["a"])
        await sync.apply(ArchiveDelta(changes: [ArchiveChange(convoID: "a", archivedAt: nil),
                                                ArchiveChange(convoID: "b", archivedAt: 21, auto: true)], at: 30))
        XCTAssertEqual(try archived(store), ["b"])
        XCTAssertEqual(try store.archiveSince(), 30)
    }

    func testWritesGoOutInOrderAndEndOnTheLatestChoice() async throws {
        let store = try seeded(["a", "b"])
        try store.setArchiveSince(1)
        let writer = FakeWriter()
        await writer.hold()
        let sync = ArchiveSync(store: store, writer: writer)
        await sync.setArchived(["a", "b"], archived: true)
        // Changed twice while the first write is out: only the last choice
        // goes next.
        while await writer.calls.isEmpty { await Task.yield() }
        await sync.setArchived(["a"], archived: false)
        await sync.setArchived(["a"], archived: true)
        await sync.setArchived(["b"], archived: false)
        await writer.release()
        await sync.waitUntilIdle()
        let calls = await writer.calls
        XCTAssertEqual(calls.map(\.ids), [["a", "b"], ["b"]])
        XCTAssertEqual(calls.map(\.archived), [true, false])
        XCTAssertEqual(try archived(store), ["a"])
    }

    func testARefusedWritePutsTheRowBack() async throws {
        let store = try seeded(["a"])
        try store.setArchiveSince(1)
        let writer = FakeWriter()
        await writer.setFailing(true)
        let sync = ArchiveSync(store: store, writer: writer)
        await sync.setArchived(["a"], archived: true)
        await sync.waitUntilIdle()
        XCTAssertEqual(try archived(store), [])
    }

    func testAFrameDoesNotOverrideAWriteStillGoingOut() async throws {
        let store = try seeded(["a"])
        try store.setArchiveSince(1)
        let writer = FakeWriter()
        await writer.hold()
        let sync = ArchiveSync(store: store, writer: writer)
        await sync.setArchived(["a"], archived: true)
        while await writer.calls.isEmpty { await Task.yield() }
        // A frame from before the tap lands meanwhile.
        await sync.apply(ArchiveDelta(changes: [ArchiveChange(convoID: "a", archivedAt: nil)], at: 5))
        XCTAssertEqual(try archived(store), ["a"])
        XCTAssertEqual(try store.archiveSince(), 5)
        await writer.release()
        await sync.waitUntilIdle()
    }

    func testAJournalThatStopsAnsweringKeepsTheArchiveLocal() async throws {
        let store = try seeded(["a"])
        try store.setArchiveSince(1)
        let writer = FakeWriter()
        let sync = ArchiveSync(store: store, writer: writer)
        await sync.applyHello(nil)
        await sync.setArchived(["a"], archived: true)
        await sync.waitUntilIdle()
        let calls = await writer.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try store.archiveSince(), 1, "kept for when it syncs again")
    }
}
