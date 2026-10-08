import Foundation
import MatronSearch
import os

/// One match from `GET /search?mode=recent`.
public struct JournalSearchHit: Equatable, Sendable {
    public let convoID: String
    public let seq: Int64
    public let ts: Date
    public let sender: String

    public init(convoID: String, seq: Int64, ts: Date, sender: String) {
        self.convoID = convoID; self.seq = seq; self.ts = ts; self.sender = sender
    }

    init?(json: [String: Any]) {
        guard let convoID = json["convo_id"] as? String,
              let seq = (json["seq"] as? NSNumber)?.int64Value,
              let ts = (json["ts"] as? NSNumber)?.doubleValue,
              let sender = json["sender"] as? String else { return nil }
        self.init(convoID: convoID, seq: seq, ts: Date(timeIntervalSince1970: ts / 1000), sender: sender)
    }
}

/// One conversation from `GET /search?mode=chats`.
public struct JournalSearchChat: Equatable, Sendable {
    public let convoID: String
    public let count: Int
    public let isExact: Bool
    public let top: JournalSearchHit
    /// Up to ~1 KB of the top message around the first occurrence of the
    /// query; the preview is cut and highlighted from it on the device.
    public let excerpt: String

    public init(convoID: String, count: Int, isExact: Bool, top: JournalSearchHit, excerpt: String) {
        self.convoID = convoID; self.count = count; self.isExact = isExact; self.top = top; self.excerpt = excerpt
    }

    init?(json: [String: Any]) {
        guard let convoID = json["convo_id"] as? String,
              let count = (json["count"] as? NSNumber)?.intValue,
              var topJSON = json["top"] as? [String: Any] else { return nil }
        topJSON["convo_id"] = convoID
        guard let top = JournalSearchHit(json: topJSON) else { return nil }
        self.init(convoID: convoID, count: count, isExact: json["exact"] as? Bool ?? false,
                  top: top, excerpt: topJSON["excerpt"] as? String ?? "")
    }
}

/// The journal's search, as the service needs it. `JournalAPI` conforms;
/// tests script it.
public protocol JournalSearching: Sendable {
    func searchChats(_ query: String, limit: Int, excludeSubagents: Bool) async throws -> [JournalSearchChat]
    func searchRecent(_ query: String, convoID: String?, limit: Int, excludeSubagents: Bool) async throws -> [JournalSearchHit]
}

extension JournalAPI: JournalSearching {}

/// The apps' `SearchService`: queries go to the journal server, which
/// holds every message and answers the same on every device; the local
/// index answers only when the server can't be reached. Writes and
/// bookkeeping go to the local index, so the sync engine and maintenance
/// keep feeding the fallback through this same object.
///
/// Why server first: each device used to build its own
/// index by walking every conversation's history, and the phone's copy had
/// holes — "time crisis", said on 30 Sep, was on the server and the Mac but
/// not findable on the phone. Subagent chats are excluded on both paths;
/// they are most of the history and almost never what a person wants.
public final class ServerFirstSearchService: SearchService, Sendable {
    private let remote: any JournalSearching
    /// `nil` when the index could not be opened: search still works, from
    /// the server alone.
    private let local: (any SearchService)?
    private static let logger = os.Logger(subsystem: "chat.matron", category: "search-server-first")

    public init(remote: any JournalSearching, local: (any SearchService)?) {
        self.remote = remote
        self.local = local
    }

    private func isSubagent(_ roomID: String) -> Bool {
        roomID.contains(JournalEventType.childConvoInfix)
    }

    // MARK: Queries

    public func queryGrouped(_ text: String, limit: Int) async throws -> [SearchChatHit] {
        guard let parsed = SearchQuery(text) else { return [] }
        do {
            let chats = try await remote.searchChats(text, limit: min(limit, 50), excludeSubagents: true)
            return chats.map { chat in
                SearchChatHit(
                    roomID: chat.convoID, count: chat.count,
                    topHit: SearchHit(id: String(chat.top.seq), roomID: chat.convoID, sender: chat.top.sender,
                                      timestamp: chat.top.ts,
                                      snippet: SearchSnippet.make(body: chat.excerpt, query: parsed)),
                    isExact: chat.isExact)
            }
        } catch {
            guard let local else { throw error }
            Self.logger.notice("server search unavailable (\(error.localizedDescription, privacy: .public)); answering from the local index")
            return try await local.queryGrouped(text, limit: limit).filter { !isSubagent($0.roomID) }
        }
    }

    public func query(_ text: String, roomID: String, limit: Int) async throws -> [SearchHit] {
        try await recent(text, convoID: roomID, limit: limit)
    }

    public func query(_ text: String, limit: Int) async throws -> [SearchHit] {
        try await recent(text, convoID: nil, limit: limit)
    }

    private func recent(_ text: String, convoID: String?, limit: Int) async throws -> [SearchHit] {
        guard SearchQuery(text) != nil else { return [] }
        do {
            let hits = try await remote.searchRecent(text, convoID: convoID, limit: limit, excludeSubagents: true)
            // No snippet: find-in-chat only steps through seqs, with the
            // messages already on screen.
            return hits.map { SearchHit(id: String($0.seq), roomID: $0.convoID, sender: $0.sender,
                                        timestamp: $0.ts, snippet: "") }
        } catch {
            guard let local else { throw error }
            Self.logger.notice("server search unavailable (\(error.localizedDescription, privacy: .public)); answering from the local index")
            if let convoID { return try await local.query(text, roomID: convoID, limit: limit) }
            return try await local.query(text, limit: limit).filter { !isSubagent($0.roomID) }
        }
    }

    // MARK: Writes and bookkeeping — the local index's

    public func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        try await local?.index(roomID: roomID, eventID: eventID, sender: sender, timestamp: timestamp, body: body)
    }
    public func indexBatch(_ entries: [SearchIndexEntry]) async throws { try await local?.indexBatch(entries) }
    public func remove(eventID: String) async throws { try await local?.remove(eventID: eventID) }
    public func removeAll(eventIDs: [String]) async throws { try await local?.removeAll(eventIDs: eventIDs) }
    public func pruneRooms(containing infix: String) async throws { try await local?.pruneRooms(containing: infix) }
    public func wipe() async throws { try await local?.wipe() }
    public func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {
        try await local?.recordBackfillProgress(roomID: roomID, indexedCount: indexedCount,
                                                oldestEventID: oldestEventID, complete: complete)
    }
    public func backfillComplete(roomID: String) async throws -> Bool {
        try await local?.backfillComplete(roomID: roomID) ?? false
    }
    public func backfillOldestEventID(roomID: String) async throws -> String? {
        try await local?.backfillOldestEventID(roomID: roomID)
    }
    public func resetBackfill() async throws { try await local?.resetBackfill() }
    public func eventCount(roomID: String) async throws -> Int { try await local?.eventCount(roomID: roomID) ?? 0 }
    public func contains(eventID: String) async throws -> Bool { try await local?.contains(eventID: eventID) ?? false }
}
