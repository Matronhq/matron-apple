import Foundation

extension JournalAPI {
    /// Internal so `RosterAPITests` pins the decoding without an HTTP stub
    /// per shape. Reads only `conversations[].id` and `.summary` — the
    /// Missions dashboard's "what's happening now" line (spec 2026-09-28
    /// §3.5). The roster's other fields (agents, capacity, titles) are
    /// deliberately not decoded here.
    static func decodeRosterSummaries(_ obj: [String: Any]) throws -> [String: String] {
        guard let rows = obj["conversations"] as? [[String: Any]] else {
            throw JournalAPIError.transport("malformed roster response")
        }
        var summaries: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String,
                  let summary = (row["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else { continue }
            summaries[id] = summary
        }
        return summaries
    }

    /// `GET /roster` reduced to conversation id → the bridge-written
    /// summary. Top-level conversations only (the journal omits children).
    public func roster() async throws -> [String: String] {
        try Self.decodeRosterSummaries(try await request(path: "/roster"))
    }
}
