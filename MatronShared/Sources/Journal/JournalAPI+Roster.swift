import Foundation
import MatronModels

/// What the apps read of `GET /roster`: per conversation, the bridge-written
/// summary (the Missions dashboard's "what's happening now" line, spec
/// 2026-09-28 §3.5) and the persisted session header (model, context
/// gauge, stall — the project page's session rows).
public struct RosterSnapshot: Equatable, Sendable {
    public var summaries: [String: String]
    public var headers: [String: SessionHeader]
    /// Disconnected boxes the journal can start again. A disconnected box
    /// missing from this set is really offline, not asleep.
    public var wakeableBoxes: Set<Int64>
    /// Each box's top-level conversations that are still open.
    public var sessionsByBox: [Int64: [RosterSession]]
    public init(summaries: [String: String] = [:], headers: [String: SessionHeader] = [:],
                wakeableBoxes: Set<Int64> = [], sessionsByBox: [Int64: [RosterSession]] = [:]) {
        self.summaries = summaries; self.headers = headers
        self.wakeableBoxes = wakeableBoxes; self.sessionsByBox = sessionsByBox
    }
}

/// One open conversation on a box, as the roster lists it.
public struct RosterSession: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// True while a turn is running; false when it waits for its next one.
    public let isRunning: Bool
    public let lastActivity: Date?

    public init(id: String, title: String, isRunning: Bool, lastActivity: Date?) {
        self.id = id; self.title = title; self.isRunning = isRunning; self.lastActivity = lastActivity
    }
}

extension JournalAPI {
    /// Internal so `RosterAPITests` pins the decoding without an HTTP stub
    /// per shape. Reads each conversation's `id`, `summary`, `status`,
    /// `title`, `session_state`, `agent_device_id` and `last_ts`, and each
    /// agent's `wakeable`.
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
            let state = row["session_state"] as? String
            if state == "running" || state == "waiting",
               let box = (row["agent_device_id"] as? NSNumber)?.int64Value {
                let lastActivity = (row["last_ts"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue / 1000)
                }
                snapshot.sessionsByBox[box, default: []].append(RosterSession(
                    id: id, title: row["title"] as? String ?? "",
                    isRunning: state == "running", lastActivity: lastActivity))
            }
        }
        for agent in obj["agents"] as? [[String: Any]] ?? [] where agent["wakeable"] as? Bool == true {
            if let box = (agent["device_id"] as? NSNumber)?.int64Value { snapshot.wakeableBoxes.insert(box) }
        }
        return snapshot
    }

    /// `GET /roster` reduced to `RosterSnapshot`. Top-level conversations
    /// only (the journal omits children).
    public func roster() async throws -> RosterSnapshot {
        try Self.decodeRoster(try await request(path: "/roster"))
    }
}
