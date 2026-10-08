import Foundation

/// The journal's `coordinator` event (Coordinator redesign spec §1a, §3e):
/// appended into the conversation that gained the role (`assigned`) and the
/// one that lost it (`released`). The timeline draws it as a one-line
/// marker; `CoordinatorSync` also reads it to keep the cached setting live.
public struct CoordinatorMarkerEvent: Equatable, Sendable {
    public enum Role: String, Sendable { case assigned, released }

    public let role: Role

    public init(role: Role) { self.role = role }

    public static func parse(payload: [String: Any]) -> CoordinatorMarkerEvent? {
        guard let role = (payload["role"] as? String).flatMap(Role.init(rawValue:)) else { return nil }
        return CoordinatorMarkerEvent(role: role)
    }

    /// The marker's one line — contract copy.
    public var text: String {
        switch role {
        case .assigned: return "This chat is now the Coordinator"
        case .released: return "This chat is no longer the Coordinator"
        }
    }
}
