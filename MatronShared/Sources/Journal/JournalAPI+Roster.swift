import Foundation
import MatronModels

/// What the apps read of `GET /roster`: per conversation, the bridge-written
/// summary (the Missions dashboard's "what's happening now" line, spec
/// 2026-09-28 §3.5) and the persisted session header (model, context
/// gauge, stall — the project page's session rows).
public struct RosterSnapshot: Equatable, Sendable {
    public var summaries: [String: String]
    public var headers: [String: SessionHeader]
    public init(summaries: [String: String] = [:], headers: [String: SessionHeader] = [:]) {
        self.summaries = summaries; self.headers = headers
    }
}

extension JournalAPI {
    /// Internal so `RosterAPITests` pins the decoding without an HTTP stub
    /// per shape. Reads `conversations[].id`, `.summary` and `.status`. The
    /// roster's other fields (agents, capacity, titles) are deliberately
    /// not decoded here.
    static func decodeRoster(_ obj: [String: Any]) throws -> RosterSnapshot {
        guard let rows = obj["conversations"] as? [[String: Any]] else {
            throw JournalAPIError.transport("malformed roster response")
        }
        var snapshot = RosterSnapshot()
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if let summary = (row["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                snapshot.summaries[id] = summary
            }
            if let header = (row["status"] as? [String: Any]).flatMap(SessionHeader.parse(statusObject:)) {
                snapshot.headers[id] = header
            }
        }
        return snapshot
    }

    /// `GET /roster` reduced to `RosterSnapshot`. Top-level conversations
    /// only (the journal omits children).
    public func roster() async throws -> RosterSnapshot {
        try Self.decodeRoster(try await request(path: "/roster"))
    }
}
