import Foundation
import os
import MatronModels

private let memoriesAPILogger = Logger(subsystem: "chat.matron", category: "memories-api")

/// Why a memories request failed, in the words the Memories screen shows.
/// `unsupported` is the journal answering 404 on the collection — it
/// predates `/memories` — which the screen shows as its own empty state
/// rather than an error banner.
public enum MemoriesError: Error, Equatable, Sendable, LocalizedError {
    case unsupported
    /// 409 `too_many`: a create past the journal's 200-per-user cap.
    case tooMany
    /// 404 on one memory: deleted elsewhere since the list loaded.
    case notFound
    /// 400 `bad_request`: the journal refused a field (the editor's own
    /// checks should have caught it first).
    case rejected(String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This journal doesn't have memories yet. Update the journal to use them."
        case .tooMany:
            return "You already have \(MemoryRules.maxMemories) memories, the most the journal keeps. Delete one first."
        case .notFound:
            return "That memory no longer exists. It may have been deleted on another device."
        case .rejected(let message):
            return message.isEmpty ? "The journal refused that memory." : "The journal refused that memory: \(message)"
        case .other(let message):
            return message
        }
    }
}

/// The journal memories surface the apps use (protocol "Memories"). The
/// per-memory `GET` is not needed: the list carries every field.
public protocol MemoriesProviding: Sendable {
    func listMemories() async throws -> [Memory]
    /// `PUT /memories/:name` — an upsert by name, and the whole memory: the
    /// body is always sent, since an omitted body CLEARS the stored one.
    /// 201 (created) and 200 (updated) both answer the stored memory.
    @discardableResult
    func saveMemory(name: String, description: String, body: String, type: MemoryType) async throws -> Memory
    /// `DELETE /memories/:name` — the deleted row comes back.
    @discardableResult
    func deleteMemory(name: String) async throws -> Memory
}

extension JournalAPI: MemoriesProviding {
    /// Internal so `MemoriesAPITests` can pin decoding directly. Lenient on
    /// single rows (a type this build doesn't know is logged and dropped);
    /// a missing or non-array `memories` key is a malformed response.
    static func decodeMemories(_ obj: [String: Any]) throws -> [Memory] {
        guard let rows = obj["memories"] as? [Any] else {
            throw MemoriesError.other("The journal sent a malformed memories list.")
        }
        return rows.compactMap { element in
            let row = element as? [String: Any]
            if let row, let memory = Memory(json: row) { return memory }
            memoriesAPILogger.error("dropped malformed memory row id=\(row?["id"] as? String ?? "?", privacy: .public)")
            return nil
        }
    }

    static func decodeMemory(_ obj: [String: Any]) throws -> Memory {
        guard let memory = (obj["memory"] as? [String: Any]).flatMap(Memory.init(json:)) else {
            throw MemoriesError.other("The journal sent a malformed memory.")
        }
        return memory
    }

    /// Maps the transport's error onto the Memories screen's words. `404`
    /// means "no such route" on the collection and "no such memory" on one.
    static func memoriesError(_ error: Error, collection: Bool) -> Error {
        guard let error = error as? JournalAPIError else { return error }
        switch error {
        case .notFound: return collection ? MemoriesError.unsupported : MemoriesError.notFound
        case .conflict: return MemoriesError.tooMany
        case .http(400, let message): return MemoriesError.rejected(message == "bad_request" ? "" : message)
        default: return MemoriesError.other(error.localizedDescription)
        }
    }

    public func listMemories() async throws -> [Memory] {
        let obj: [String: Any]
        do { obj = try await request(path: "/memories") } catch { throw Self.memoriesError(error, collection: true) }
        return try Self.decodeMemories(obj)
    }

    @discardableResult
    public func saveMemory(name: String, description: String, body: String, type: MemoryType) async throws -> Memory {
        let obj: [String: Any]
        do {
            obj = try await request(path: "/memories/\(Self.pathSegment(name))", method: "PUT",
                                    body: ["description": description, "body": body, "type": type.rawValue],
                                    accept: [200, 201])
        } catch {
            // A 404 on a PUT is never "no such memory" (it's an upsert): it
            // is a journal without the route.
            throw Self.memoriesError(error, collection: true)
        }
        return try Self.decodeMemory(obj)
    }

    @discardableResult
    public func deleteMemory(name: String) async throws -> Memory {
        let obj: [String: Any]
        do {
            obj = try await request(path: "/memories/\(Self.pathSegment(name))", method: "DELETE")
        } catch {
            throw Self.memoriesError(error, collection: false)
        }
        return try Self.decodeMemory(obj)
    }
}
