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
    /// Which ask was answered, in the form the consent link carries it:
    /// `<room_id>/<target_device_id>` for a chat, the `request_id` for a
    /// spawn — what lets the card the decision is about read it. `nil` when
    /// the payload names no ask.
    public let askID: String?

    public init(kind: Kind, decision: Decision, reason: String? = nil, askID: String? = nil) {
        self.kind = kind; self.decision = decision; self.reason = reason; self.askID = askID
    }

    public static func parse(payload: [String: Any]) -> ConsentDecisionEvent? {
        guard let kind = (payload["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let decision = (payload["decision"] as? String).flatMap(Decision.init(rawValue:))
        else { return nil }
        let askID: String?
        switch kind {
        case .chat:
            if let room = payload["room_id"] as? String, !room.isEmpty,
               let device = (payload["target_device_id"] as? NSNumber)?.int64Value {
                askID = AgentChatRequest.askID(roomID: room, targetDeviceID: device)
            } else {
                askID = nil
            }
        case .spawn:
            askID = (payload["request_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return ConsentDecisionEvent(kind: kind, decision: decision, reason: payload["reason"] as? String, askID: askID)
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
