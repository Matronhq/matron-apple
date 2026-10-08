import Foundation

/// `GET` / `PUT /coordinator` (Coordinator redesign contract): the user's one
/// Coordinator conversation, `nil` for none. A protocol so `CoordinatorSync`
/// tests fake it.
public protocol CoordinatorProviding: Sendable {
    func coordinator() async throws -> String?
    /// Returns what the journal stored. Throws `.notFound` for a conversation
    /// the user does not own.
    func setCoordinator(_ convoID: String?) async throws -> String?
}

extension JournalAPI: CoordinatorProviding {
    public func coordinator() async throws -> String? {
        Self.decodeCoordinator(try await request(path: "/coordinator"))
    }

    public func setCoordinator(_ convoID: String?) async throws -> String? {
        let body: [String: Any] = ["convo_id": convoID.map { $0 as Any } ?? NSNull()]
        return Self.decodeCoordinator(try await request(path: "/coordinator", method: "PUT", body: body))
    }

    static func decodeCoordinator(_ obj: [String: Any]) -> String? {
        guard let id = obj["convo_id"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
