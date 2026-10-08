import Foundation

/// `GET` / `PUT /defaults`: the user's default model and effort for new
/// chats. A protocol so `NewChatDefaultsStore` tests fake it.
public protocol NewChatDefaultsProviding: Sendable {
    /// Throws `.notFound` on a journal that predates per-user defaults.
    func newChatDefaults() async throws -> NewChatDefaults
    /// Sets one key (`nil` = Box default) and returns both as the journal
    /// stored them (trimmed and lowercased). The other key is left as is.
    func setNewChatDefault(_ key: NewChatDefaults.Key, to value: String?) async throws -> NewChatDefaults
}

extension JournalAPI: NewChatDefaultsProviding {
    public func newChatDefaults() async throws -> NewChatDefaults {
        try Self.decodeDefaults(try await request(path: "/defaults"))
    }

    public func setNewChatDefault(_ key: NewChatDefaults.Key, to value: String?) async throws -> NewChatDefaults {
        let body: [String: Any] = [key.rawValue: value.map { $0 as Any } ?? NSNull()]
        return try Self.decodeDefaults(try await request(path: "/defaults", method: "PUT", body: body))
    }

    static func decodeDefaults(_ obj: [String: Any]) throws -> NewChatDefaults {
        guard let defaults = NewChatDefaults.decode(obj) else {
            throw JournalAPIError.transport("malformed /defaults response")
        }
        return defaults
    }
}
