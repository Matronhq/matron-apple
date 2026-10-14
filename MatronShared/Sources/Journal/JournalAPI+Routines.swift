import Foundation
import os
import MatronModels

private let routinesAPILogger = Logger(subsystem: "chat.matron", category: "routines-api")

/// Why a routines request failed, in the words the Routines screen shows.
/// `unsupported` is the journal answering 404 on the collection — it
/// predates `/routines` — which the screen shows as its own empty state.
public enum RoutinesError: Error, Equatable, Sendable, LocalizedError {
    case unsupported
    /// 409 `blocked_by: name`: a create whose name is taken.
    case nameTaken
    /// 409 `blocked_by: cap`: a create past the journal's per-user cap.
    case tooMany
    /// 404 on one routine: deleted elsewhere since the list loaded.
    case notFound
    /// 400: the journal refused a field. It doesn't say which, so the
    /// message names the rules the editor can't check itself.
    case rejected
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This journal doesn't have routines yet. Update the journal to use them."
        case .nameTaken:
            return "A routine with that name already exists. Choose another name."
        case .tooMany:
            return "You already have \(RoutineRules.maxRoutines) routines, the most the journal keeps. Delete one first."
        case .notFound:
            return "That routine no longer exists. It may have been deleted on another device."
        case .rejected:
            return "The journal refused that routine. A schedule must fire at least \(RoutineRules.minGapMinutes) minutes apart and keep firing, the zone must be a real time zone, and a routine has either a schedule or a trigger, never both."
        case .other(let message):
            return message
        }
    }
}

/// `POST /routines/:key/run`'s answer: fired, or why not.
public enum RoutineRunResult: Equatable, Sendable {
    case accepted
    /// `no_coordinator`, `busy` or `no_firer`.
    case notDelivered(reason: String)

    public var message: String? {
        switch self {
        case .accepted: return nil
        case .notDelivered("no_coordinator"): return "Not sent: there is no Coordinator to run it."
        case .notDelivered("busy"): return "Not sent: the journal is busy firing other routines. Try again in a moment."
        case .notDelivered(let reason): return "Not sent (\(reason))."
        }
    }
}

/// The journal routines surface the apps use (protocol "Coordinator
/// routines"). The app writes with its client token, so no `convo_id`.
public protocol RoutinesProviding: Sendable {
    func listRoutines() async throws -> [Routine]
    /// `POST /routines`. Throws `nameTaken` / `tooMany` on 409.
    func createRoutine(name: String, draft: RoutineDraft) async throws -> Routine
    /// `PATCH /routines/:key`.
    func updateRoutine(id: String, draft: RoutineDraft) async throws -> Routine
    /// `PATCH /routines/:key` with `enabled` alone: pause or resume.
    func setRoutineEnabled(id: String, enabled: Bool) async throws -> Routine
    /// `DELETE /routines/:key`.
    func deleteRoutine(id: String) async throws
    /// `POST /routines/:key/run` (202).
    func runRoutine(id: String) async throws -> RoutineRunResult
}

extension JournalAPI: RoutinesProviding {
    /// Internal so `RoutinesAPITests` can pin decoding directly. Lenient on
    /// single rows (a trigger kind this build doesn't know is logged and
    /// dropped); a missing `routines` key is a malformed response.
    static func decodeRoutines(_ obj: [String: Any]) throws -> [Routine] {
        guard let rows = obj["routines"] as? [Any] else {
            throw RoutinesError.other("The journal sent a malformed routines list.")
        }
        return rows.compactMap { element in
            let row = element as? [String: Any]
            if let row, let routine = Routine(json: row) { return routine }
            routinesAPILogger.error("dropped malformed routine row id=\(row?["id"] as? String ?? "?", privacy: .public)")
            return nil
        }
    }

    static func decodeRoutine(_ obj: [String: Any]) throws -> Routine {
        guard let routine = (obj["routine"] as? [String: Any]).flatMap(Routine.init(json:)) else {
            throw RoutinesError.other("The journal sent a malformed routine.")
        }
        return routine
    }

    /// The statuses the routines contract names become `RoutinesError`;
    /// the rest go through the shared mapping. `404` means "no such route"
    /// on the collection and "no such routine" on one.
    static func routinesError(status: Int, data: Data, collection: Bool) -> Error {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 404: return collection ? RoutinesError.unsupported : RoutinesError.notFound
        case 409 where obj?["blocked_by"] as? String == "cap": return RoutinesError.tooMany
        case 409: return RoutinesError.nameTaken
        case 400: return RoutinesError.rejected
        default: return RoutinesError.other(Self.error(status: status, data: data).localizedDescription)
        }
    }

    private func routinesRequest(path: String, method: String, body: [String: Any]? = nil,
                                 accept: Set<Int> = [200], collection: Bool) async throws -> [String: Any] {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await rawRequest(path: path, method: method, body: body)
        } catch {
            throw RoutinesError.other(error.localizedDescription)
        }
        guard accept.contains(response.statusCode) else {
            throw Self.routinesError(status: response.statusCode, data: data, collection: collection)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RoutinesError.other("The journal sent a malformed answer.")
        }
        return obj
    }

    private static func routinePath(_ id: String) -> String { "/routines/\(pathSegment(id))" }

    public func listRoutines() async throws -> [Routine] {
        try Self.decodeRoutines(try await routinesRequest(path: "/routines", method: "GET", collection: true))
    }

    public func createRoutine(name: String, draft: RoutineDraft) async throws -> Routine {
        var body = draft.requestBody
        body["name"] = name
        // A triggered routine still names a zone on create (the journal
        // defaults it); sending it keeps the row's zone the user's choice.
        if body["tz"] == nil { body["tz"] = draft.tz }
        return try Self.decodeRoutine(try await routinesRequest(path: "/routines", method: "POST", body: body,
                                                                accept: [201], collection: true))
    }

    public func updateRoutine(id: String, draft: RoutineDraft) async throws -> Routine {
        try Self.decodeRoutine(try await routinesRequest(path: Self.routinePath(id), method: "PATCH",
                                                         body: draft.requestBody, collection: false))
    }

    public func setRoutineEnabled(id: String, enabled: Bool) async throws -> Routine {
        try Self.decodeRoutine(try await routinesRequest(path: Self.routinePath(id), method: "PATCH",
                                                         body: ["enabled": enabled], collection: false))
    }

    public func deleteRoutine(id: String) async throws {
        _ = try await routinesRequest(path: Self.routinePath(id), method: "DELETE", body: [:], collection: false)
    }

    public func runRoutine(id: String) async throws -> RoutineRunResult {
        let obj = try await routinesRequest(path: Self.routinePath(id) + "/run", method: "POST", body: [:],
                                            accept: [202], collection: false)
        return Self.decodeRunResult(obj)
    }

    static func decodeRunResult(_ obj: [String: Any]) -> RoutineRunResult {
        if obj["accepted"] as? Bool == true { return .accepted }
        return .notDelivered(reason: obj["reason"] as? String ?? "unknown")
    }
}
