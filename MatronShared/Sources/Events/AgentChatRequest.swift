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
    /// The device on the far end of the ask, for display only. For an invite
    /// that is `targetDeviceID`; for a join it is the room's *owner*, which
    /// `targetDeviceID` is emphatically not. Never follow `targetDeviceID`
    /// to label the far end.
    public let toName: String
    /// The two sessions, id and title each. The id is the stable handle —
    /// titles are agent-written and change — and the title is what the user
    /// recognises from their conversation list. Empty when the requesting
    /// bridge named no conversation.
    public let fromConvoID: String
    public let fromConvoTitle: String
    public let toConvoID: String
    public let toConvoTitle: String
    public let topic: String?
    public let justification: String?

    public init(
        ask: Ask, roomID: String, fromDeviceID: Int64, fromName: String,
        targetDeviceID: Int64, toName: String = "",
        fromConvoID: String = "", fromConvoTitle: String = "",
        toConvoID: String = "", toConvoTitle: String = "",
        topic: String?, justification: String?
    ) {
        self.ask = ask
        self.roomID = roomID
        self.fromDeviceID = fromDeviceID
        self.fromName = fromName
        self.targetDeviceID = targetDeviceID
        self.toName = toName
        self.fromConvoID = fromConvoID
        self.fromConvoTitle = fromConvoTitle
        self.toConvoID = toConvoID
        self.toConvoTitle = toConvoTitle
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
            // Display-only, and all optional: a journal that predates them
            // still yields an answerable card, just a less specific one.
            toName: payload["to_name"] as? String ?? "",
            fromConvoID: payload["from_convo_id"] as? String ?? "",
            fromConvoTitle: payload["from_convo_title"] as? String ?? "",
            toConvoID: payload["to_convo_id"] as? String ?? "",
            toConvoTitle: payload["to_convo_title"] as? String ?? "",
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

    /// The name to show for the far end, same fallback as `requesterLabel`.
    /// For a join the far end is the room's owner, so this deliberately does
    /// not fall back to `targetDeviceID` — that id is the joiner.
    public var targetLabel: String {
        if !toName.isEmpty { return toName }
        return ask == .invite ? "Device \(targetDeviceID)" : "the room's owner"
    }

    /// A session rendered the way the conversation list renders it: the first
    /// two characters of its id, then its title.
    ///
    /// Bridges seed a session title as `"<box>:<first two of the id> words"`,
    /// which is the string the list shows — so when the title already opens
    /// with those two characters this returns the title untouched rather than
    /// stuttering ("69 · 2:69 text carry…"). Rooms and sub-chats carry no
    /// such prefix, which is why the id is sent alongside and the short form
    /// is derived from it rather than trusted to be in the words.
    ///
    /// `nil` when the journal named no conversation — the card drops the row
    /// rather than showing an empty one.
    public static func sessionLabel(id: String, title: String) -> String? {
        let short = String(id.prefix(2))
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if short.isEmpty { return title.isEmpty ? nil : title }
        if title.isEmpty { return short }
        let firstWord = title.prefix(while: { !$0.isWhitespace })
        let carriesShortID = firstWord == short || firstWord.hasSuffix(":\(short)")
        return carriesShortID ? title : "\(short) · \(title)"
    }

    /// "dan-mac — 2:69 text carry and fitting parity", or just the device
    /// name when no session was named.
    private static func endpointLabel(device: String, convoID: String, convoTitle: String) -> String {
        guard let session = sessionLabel(id: convoID, title: convoTitle) else { return device }
        return "\(device) — \(session)"
    }

    public var fromLabel: String {
        Self.endpointLabel(device: requesterLabel, convoID: fromConvoID, convoTitle: fromConvoTitle)
    }

    public var toLabel: String {
        Self.endpointLabel(device: targetLabel, convoID: toConvoID, convoTitle: toConvoTitle)
    }

    /// One line stating what is being asked, in the user's terms. Names the
    /// far end: "another agent" is not something a user can consent to.
    public var headline: String {
        switch ask {
        case .invite: return "\(requesterLabel) wants to start a chat with \(targetLabel)."
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
