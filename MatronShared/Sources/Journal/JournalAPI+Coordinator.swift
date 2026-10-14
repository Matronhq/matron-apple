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

/// The Coordinator's consent-approval switch (protocol: "Coordinator →
/// Consent approval → Off switch"): `consent` on `GET` / `PUT /coordinator`,
/// on by default. Off, the Coordinator cannot answer chat or spawn cards;
/// the user's own taps are unaffected. Its own slice so the settings row
/// does not need the whole Coordinator contract.
public protocol CoordinatorConsentProviding: Sendable {
    /// `nil` from a journal that predates the switch (no `consent` key).
    func coordinatorConsent() async throws -> Bool?
    /// Returns what the journal stored.
    func setCoordinatorConsent(_ enabled: Bool) async throws -> Bool?
}

extension JournalAPI: CoordinatorConsentProviding {
    public func coordinatorConsent() async throws -> Bool? {
        Self.decodeCoordinatorConsent(try await request(path: "/coordinator"))
    }

    public func setCoordinatorConsent(_ enabled: Bool) async throws -> Bool? {
        Self.decodeCoordinatorConsent(try await request(path: "/coordinator", method: "PUT", body: ["consent": enabled]))
    }

    static func decodeCoordinatorConsent(_ obj: [String: Any]) -> Bool? {
        obj["consent"] as? Bool
    }
}
