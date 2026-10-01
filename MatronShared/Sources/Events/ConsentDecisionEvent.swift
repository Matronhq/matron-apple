import Foundation

/// The journal's `consent_decision` event (protocol: "Coordinator consent →
/// What an answer does"): appended, client-only, on a consent card's
/// conversation when the Coordinator answered it — the parent conversation
/// for a spawn, the room for a chat. A user's own tap appends nothing; the
/// card's resolved state already says it. The timeline draws a one-line
/// row so the user can see who decided and why.
public struct ConsentDecisionEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case chat, spawn }
    public enum Decision: String, Sendable { case approve, decline }

    public let kind: Kind
    public let decision: Decision
    /// The Coordinator's one-line reason, as the user reads it on the card.
    public let reason: String?

    public init(kind: Kind, decision: Decision, reason: String? = nil) {
        self.kind = kind; self.decision = decision; self.reason = reason
    }

    public static func parse(payload: [String: Any]) -> ConsentDecisionEvent? {
        guard let kind = (payload["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let decision = (payload["decision"] as? String).flatMap(Decision.init(rawValue:))
        else { return nil }
        return ConsentDecisionEvent(kind: kind, decision: decision, reason: payload["reason"] as? String)
    }

    /// "Coordinator approved the spawn request — <reason>" /
    /// "Coordinator declined the chat request".
    public var text: String {
        let verb = decision == .approve ? "approved" : "declined"
        let what = kind == .spawn ? "spawn request" : "chat request"
        let line = "Coordinator \(verb) the \(what)"
        let oneLine = (reason ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.isEmpty ? line : "\(line) — \(oneLine)"
    }
}
