import Foundation

/// One agent asking the user's permission to talk to another agent — the
/// journal's server-minted consent card (matron-journal `src/ws.js`, the
/// `agent_invite`/`agent_join` park path).
///
/// It arrives as a `permission_request` event whose payload carries
/// `kind: "agent_chat"`, and it is *client-only*: the journal filters it out
/// of every agent-facing replay and refuses to let an agent mint one. Nothing
/// in the timeline answers it — the answer is `POST /agent-chat/answer`, over
/// HTTP, keyed on `roomID` + `targetDeviceID`.
///
/// Deliberately NOT modelled as an `AskUserEvent`: that type's generic
/// Allow/Deny buttons answer over `prompt_reply`, which never reaches the
/// parked row, so the card would render inertly and the ask would sit until
/// its 24h TTL expired. The two facts a consent decision rests on — who is
/// asking and why — have no home in `AskUserEvent` either.
public struct AgentChatRequest: Equatable, Sendable {
    /// Which way round the ask goes. An `invite` is the requesting agent
    /// pulling `targetDeviceID` into a room it owns; a `join` is the
    /// requester asking to be let into someone else's room, in which case
    /// it self-targets (`fromDeviceID == targetDeviceID`).
    public enum Ask: String, Equatable, Sendable {
        case invite
        case join
    }

    public let ask: Ask
    /// The room the decision is about — half the key `POST /agent-chat/answer`
    /// needs.
    public let roomID: String
    public let fromDeviceID: Int64
    /// The requesting agent's device name, already sanitised and capped
    /// server-side. Empty if the journal had no name for it.
    public let fromName: String
    /// The device the parked row is filed under — the other half of the
    /// answer key. For a join this is the joiner itself, not the room owner.
    public let targetDeviceID: Int64
    public let topic: String?
    public let justification: String?

    public init(
        ask: Ask, roomID: String, fromDeviceID: Int64, fromName: String,
        targetDeviceID: Int64, topic: String?, justification: String?
    ) {
        self.ask = ask
        self.roomID = roomID
        self.fromDeviceID = fromDeviceID
        self.fromName = fromName
        self.targetDeviceID = targetDeviceID
        self.topic = topic
        self.justification = justification
    }

    /// Parses a `permission_request` payload, or `nil` if this is not an
    /// agent-chat card. Strict about the four fields an answer needs
    /// (`room_id`, `target_device_id`, `from_device_id`, a known `request`):
    /// a card we cannot answer must fall back to the generic permission
    /// rendering rather than draw buttons that would 400.
    public static func parse(payload: [String: Any]) -> AgentChatRequest? {
        guard payload["kind"] as? String == "agent_chat",
              let roomID = payload["room_id"] as? String, !roomID.isEmpty,
              let ask = (payload["request"] as? String).flatMap(Ask.init(rawValue:)),
              let from = (payload["from_device_id"] as? NSNumber)?.int64Value,
              let target = (payload["target_device_id"] as? NSNumber)?.int64Value
        else { return nil }
        return AgentChatRequest(
            ask: ask,
            roomID: roomID,
            fromDeviceID: from,
            fromName: payload["from_name"] as? String ?? "",
            targetDeviceID: target,
            topic: nonEmpty(payload["topic"]),
            justification: nonEmpty(payload["justification"])
        )
    }

    /// The journal defaults `topic`/`justification` to `""` rather than
    /// omitting them, so "absent" and "empty" arrive identically — collapse
    /// both to nil so the card can drop the row instead of drawing an empty
    /// quote.
    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name to show for the requester, falling back to the device id
    /// when the journal had no name (a revoked device mid-ask).
    public var requesterLabel: String {
        fromName.isEmpty ? "Device \(fromDeviceID)" : fromName
    }

    /// One line stating what is being asked, in the user's terms.
    public var headline: String {
        switch ask {
        case .invite: return "\(requesterLabel) wants to start a chat with another agent."
        case .join: return "\(requesterLabel) wants to join this chat."
        }
    }
}

/// Where one consent card is in its short life.
///
/// Lives in MatronEvents so the view model that owns it and the card that
/// renders it agree on one type. `answered` has to be remembered by the
/// client: answering is an HTTP call, so unlike an ask-user reply it leaves
/// no event in the timeline to read the outcome back from. `expired` is the
/// server's 409 — the row is no longer awaiting anyone, because it timed out
/// or was decided on another device.
public enum AgentChatCardState: Equatable, Sendable {
    case idle
    case sending
    case answered(approved: Bool)
    case expired
    case failed(String)
}
