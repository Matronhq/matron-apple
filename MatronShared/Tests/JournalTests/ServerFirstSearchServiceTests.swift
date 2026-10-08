import XCTest
@testable import MatronJournal
import MatronSearch

/// `ServerFirstSearchService`: the journal answers; the local index only
/// when it can't.
final class ServerFirstSearchServiceTests: XCTestCase {
    private struct Down: Error {}

    private final class ScriptedRemote: JournalSearching, @unchecked Sendable {
        var chats: [JournalSearchChat] = []
        var recent: [JournalSearchHit] = []
        var down = false
        private(set) var chatCalls: [(query: String, limit: Int, excludeSubagents: Bool)] = []
        private(set) var recentCalls: [(query: String, convoID: String?, limit: Int)] = []

        func searchChats(_ query: String, limit: Int, excludeSubagents: Bool) async throws -> [JournalSearchChat] {
            chatCalls.append((query, limit, excludeSubagents))
            if down { throw Down() }
            return chats
        }
        func searchRecent(_ query: String, convoID: String?, limit: Int, excludeSubagents: Bool) async throws -> [JournalSearchHit] {
            recentCalls.append((query, convoID, limit))
            if down { throw Down() }
            return recent
        }
    }

    private actor LocalFake: SearchService {
        var grouped: [SearchChatHit] = []
        var flat: [SearchHit] = []
        func set(grouped: [SearchChatHit] = [], flat: [SearchHit] = []) { self.grouped = grouped; self.flat = flat }
        func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] { grouped }
        func query(_ text: String, limit: Int) async throws -> [SearchHit] { flat }
        func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] { flat.filter { $0.roomID == roomID } }
        func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
        func remove(eventID: String) async throws {}
        func wipe() async throws {}
        func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
        func backfillComplete(roomID: String) async throws -> Bool { false }
        func backfillOldestEventID(roomID: String) async throws -> String? { nil }
        func resetBackfill() async throws {}
        func eventCount(roomID: String) async throws -> Int { 0 }
        func contains(eventID: String) async throws -> Bool { false }
    }

    private func hit(_ id: String, room: String) -> SearchHit {
        SearchHit(id: id, roomID: room, sender: "agent:x", timestamp: Date(timeIntervalSince1970: 1), snippet: "")
    }

    func test_grouped_comesFromTheServer_withPreviewCutFromTheExcerpt() async throws {
        let remote = ScriptedRemote()
        remote.chats = [JournalSearchChat(
            convoID: "treadmill", count: 5, isExact: true,
            top: JournalSearchHit(convoID: "treadmill", seq: 1146809, ts: Date(timeIntervalSince1970: 1_790_805_900), sender: "user:alice"),
            excerpt: "Can you buy guns like time crisis guns and use them as a mouse")]
        let service = ServerFirstSearchService(remote: remote, local: LocalFake())
        let groups = try await service.queryGrouped("time crisis", limit: 200)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].roomID, "treadmill")
        XCTAssertEqual(groups[0].count, 5)
        XCTAssertTrue(groups[0].isExact)
        XCTAssertEqual(groups[0].topHit.id, "1146809")
        XCTAssertEqual(groups[0].topHit.sender, "user:alice")
        XCTAssertTrue(groups[0].topHit.snippet.contains("<mark>time crisis</mark>"), groups[0].topHit.snippet)
        XCTAssertEqual(remote.chatCalls.first?.limit, 50, "the server clamps at 50")
        XCTAssertEqual(remote.chatCalls.first?.excludeSubagents, true)
    }

    func test_grouped_fallsBackToTheLocalIndex_withoutSubagentChats() async throws {
        let remote = ScriptedRemote()
        remote.down = true
        let local = LocalFake()
        await local.set(grouped: [
            SearchChatHit(roomID: "main", count: 1, topHit: hit("1", room: "main")),
            SearchChatHit(roomID: "main:sub:a1", count: 3, topHit: hit("2", room: "main:sub:a1")),
        ])
        let service = ServerFirstSearchService(remote: remote, local: local)
        let groups = try await service.queryGrouped("time", limit: 50)
        XCTAssertEqual(groups.map(\.roomID), ["main"])
    }

    func test_withoutALocalIndex_aServerFailureIsThrown() async {
        let remote = ScriptedRemote()
        remote.down = true
        let service = ServerFirstSearchService(remote: remote, local: nil)
        do {
            _ = try await service.queryGrouped("time", limit: 50)
            XCTFail("expected the server error")
        } catch {
            XCTAssertTrue(error is Down)
        }
    }

    func test_inChat_asksTheServerForTheConversation_newestFirstSeqs() async throws {
        let remote = ScriptedRemote()
        remote.recent = [
            JournalSearchHit(convoID: "r", seq: 30, ts: Date(timeIntervalSince1970: 30), sender: "agent:x"),
            JournalSearchHit(convoID: "r", seq: 10, ts: Date(timeIntervalSince1970: 10), sender: "user:alice"),
        ]
        let service = ServerFirstSearchService(remote: remote, local: LocalFake())
        let hits = try await service.query("time ", roomID: "r", limit: 500)
        XCTAssertEqual(hits.map(\.id), ["30", "10"])
        XCTAssertEqual(remote.recentCalls.first?.convoID, "r")
        XCTAssertEqual(remote.recentCalls.first?.limit, 500)
        XCTAssertEqual(remote.recentCalls.first?.query, "time ", "the trailing space finishes the word")
    }

    func test_inChat_fallsBackToTheLocalIndex() async throws {
        let remote = ScriptedRemote()
        remote.down = true
        let local = LocalFake()
        await local.set(flat: [hit("7", room: "r"), hit("8", room: "other")])
        let service = ServerFirstSearchService(remote: remote, local: local)
        let hits = try await service.query("time", roomID: "r", limit: 10)
        XCTAssertEqual(hits.map(\.id), ["7"])
    }

    func test_nothingSearchable_neverAsksTheServer() async throws {
        let remote = ScriptedRemote()
        let service = ServerFirstSearchService(remote: remote, local: nil)
        let groups = try await service.queryGrouped("  ++ ", limit: 50)
        XCTAssertEqual(groups, [])
        XCTAssertTrue(remote.chatCalls.isEmpty)
    }

    func test_parsesTheServersShapes() throws {
        let chat = JournalSearchChat(json: [
            "convo_id": "c", "title": "T", "parent_convo_id": NSNull(), "count": 2, "exact": true, "live": false,
            "top": ["seq": 42, "ts": 1_790_805_900_902, "sender": "user:alice", "excerpt": "…time crisis…"],
        ])
        XCTAssertEqual(chat?.convoID, "c")
        XCTAssertEqual(chat?.top.seq, 42)
        XCTAssertEqual(chat?.top.ts.timeIntervalSince1970 ?? 0, 1_790_805_900.902, accuracy: 0.001)
        XCTAssertEqual(chat?.excerpt, "…time crisis…")
        XCTAssertNil(JournalSearchChat(json: ["convo_id": "c"]), "a row without its top message is dropped")
        XCTAssertNil(JournalSearchHit(json: ["convo_id": "c", "seq": "not a number"]))
    }
}

/// What the local index is fed (see SearchIndexing.swift).
final class SearchIndexingTests: XCTestCase {
    private func event(convo: String = "c1", type: String = JournalEventType.text,
                       payload: [String: Any], ts: Date = Date()) -> JournalEvent {
        JournalEvent(seq: 7, convoID: convo, ts: ts, sender: "agent:x", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func test_textInATopLevelChat_isIndexed() {
        let entry = event(payload: ["body": "time crisis"]).searchIndexEntry()
        XCTAssertEqual(entry?.roomID, "c1")
        XCTAssertEqual(entry?.eventID, "7")
        XCTAssertEqual(entry?.body, "time crisis")
    }

    func test_subagentChats_areNotIndexed() {
        XCTAssertNil(event(convo: "c1:sub:a1", payload: ["body": "time crisis"]).searchIndexEntry())
    }

    func test_toolOutput_isNotIndexed() {
        XCTAssertNil(event(type: JournalEventType.toolOutput, payload: ["snippet": "SECRET=hunter2"]).searchIndexEntry())
    }

    func test_diffs_areIndexedInsideTheRetentionWindowOnly() {
        XCTAssertEqual(event(type: JournalEventType.diff, payload: ["diff": "-a\n+b"]).searchIndexEntry()?.body, "-a\n+b")
        let old = Date().addingTimeInterval(-EventTombstone.retentionWindow - 1)
        XCTAssertNil(event(type: JournalEventType.diff, payload: ["diff": "-a\n+b"], ts: old).searchIndexEntry())
    }
}
