import Foundation
import MatronModels

/// One of the journal's person-to-person consent cards: a contact request, a
/// read-only mission share, a session made reachable by a contact's agents,
/// or a room with another person's agent (talk requests included).
///
/// They arrive as `permission_request` events (matron-journal
/// `sharing-events.js`, `person-rooms-events.js`), each with a tracker item
/// filed beside it — the mirror — and the mirror's own buttons are the only
/// way to answer. So unlike the agent-chat and agent-spawn cards this one is
/// inert: it says who is asking, which way and about what, and points at the
/// mirror. Before it existed these payloads fell through to the generic
/// Allow/Deny prompt, whose taps went out as `prompt_reply`, which nothing
/// reads.
///
/// Lenient by design: any payload of a known kind becomes a card, however
/// little else it carries, because the alternative is the dead prompt. Extra
/// fields (a talk card's `contact_pending`, `choices`) are ignored.
public struct PersonConsentCard: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case contactRequest = "contact_request"
        case missionShare = "mission_share"
        case sessionShare = "session_share"
        case personRoom = "person_room"
    }

    /// `out`: the user's own agent asked, and the user approves it going out.
    /// `in`: another person asks the user.
    public enum Direction: Equatable, Sendable {
        case outgoing
        case incoming
    }

    /// The tracker item that answers this card, as far as the timeline knows.
    public enum Mirror: Equatable, Sendable {
        /// Not found in the loaded timeline — the card shows a plain hint.
        case unknown
        case open(itemID: String)
        /// The ask is settled (answered, expired or withdrawn).
        case closed(itemID: String)

        public var itemID: String? {
            switch self {
            case .unknown: return nil
            case .open(let id), .closed(let id): return id
            }
        }
    }

    public let kind: Kind
    public let direction: Direction
    /// The other person, as the journal names them. Empty when the payload
    /// named nobody.
    public let personName: String
    /// The ask's id in the journal (contact, grant, session share or room
    /// link id) — the tail of the mirror's consent link.
    public let askID: String?
    public let topic: String?
    public let missionTitle: String?
    public let sessionTitle: String?
    /// A talk request: one card per person, the session chosen on accept.
    public let talk: Bool
    public let mirror: Mirror

    public init(kind: Kind, direction: Direction, personName: String, askID: String?,
                topic: String? = nil, missionTitle: String? = nil, sessionTitle: String? = nil,
                talk: Bool = false, mirror: Mirror = .unknown) {
        self.kind = kind
        self.direction = direction
        self.personName = personName
        self.askID = askID
        self.topic = topic
        self.missionTitle = missionTitle
        self.sessionTitle = sessionTitle
        self.talk = talk
        self.mirror = mirror
    }

    /// `nil` unless `payload.kind` is one of the four people kinds.
    public static func parse(payload: [String: Any]) -> PersonConsentCard? {
        guard let kind = (payload["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        let direction: Direction = payload["direction"] as? String == "out" ? .outgoing : .incoming
        let person: String
        let askID: String?
        var missionTitle: String?
        switch kind {
        case .contactRequest:
            person = name(payload["peer"])
            askID = nonEmpty(payload["contact_id"])
        case .missionShare:
            // The grantee for the owner's own card, the owner for the grantee's.
            person = name(direction == .outgoing ? payload["grantee"] : payload["owner"])
            askID = nonEmpty(payload["grant_id"])
            missionTitle = nonEmpty((payload["mission"] as? [String: Any])?["title"])
        case .sessionShare:
            person = name(payload["person"])
            askID = nonEmpty(payload["session_share_id"])
        case .personRoom:
            person = name(payload["person"])
            askID = nonEmpty(payload["room_link_id"])
            missionTitle = nonEmpty((payload["mission"] as? [String: Any])?["title"])
        }
        return PersonConsentCard(
            kind: kind, direction: direction, personName: person, askID: askID,
            topic: nonEmpty(payload["topic"]), missionTitle: missionTitle,
            sessionTitle: nonEmpty(payload["session_title"]),
            talk: payload["talk"] as? Bool ?? false)
    }

    public func withMirror(_ mirror: Mirror) -> PersonConsentCard {
        PersonConsentCard(kind: kind, direction: direction, personName: personName, askID: askID,
                          topic: topic, missionTitle: missionTitle, sessionTitle: sessionTitle,
                          talk: talk, mirror: mirror)
    }

    /// The journal's name for this kind of ask: the `consent` extra on the
    /// mirror's item markers, and the kind segment of its consent link.
    public var consentKind: String {
        switch kind {
        case .contactRequest: return "contact"
        case .missionShare: return "share"
        case .sessionShare: return "session"
        case .personRoom: return "room"
        }
    }

    /// The mirror's consent link, when the payload carried the ask's id.
    public var consentLink: ConsentLink? {
        askID.flatMap { ConsentLink.people(consentKind: consentKind, id: $0) }
    }

    // MARK: Words

    public var title: String {
        switch kind {
        case .contactRequest: return "Contact request"
        case .missionShare: return "Mission share"
        case .sessionShare: return "Session share"
        case .personRoom: return talk ? "Talk request" : "Room with another person"
        }
    }

    /// The person's name, or a stand-in when the journal named nobody.
    public var personLabel: String {
        personName.isEmpty ? "Another person" : personName
    }

    private var personObject: String {
        personName.isEmpty ? "another person" : personName
    }

    /// One line: who asks, and which way.
    public var headline: String {
        switch (kind, direction) {
        case (.contactRequest, .outgoing):
            return "Your agent asks to add \(personObject) as a contact."
        case (.contactRequest, .incoming):
            return "\(personLabel) wants to add you as a contact."
        case (.missionShare, .outgoing):
            return "Your agent asks to share a mission with \(personObject), read-only."
        case (.missionShare, .incoming):
            return "\(personLabel) wants to share a mission with you, read-only."
        case (.sessionShare, .outgoing):
            return "Your agent asks to let \(possessive(personObject)) agents reach this session."
        case (.sessionShare, .incoming):
            return "\(personLabel) offers a session for your agents to reach."
        case (.personRoom, .outgoing):
            return talk ? "Your agent asks to talk with \(personObject)."
                        : "Your agent asks to talk with \(possessive(personObject)) agent."
        case (.personRoom, .incoming):
            return talk ? "\(possessive(personLabel)) agent wants to talk."
                        : "\(possessive(personLabel)) agent wants to talk with your agent."
        }
    }

    private func possessive(_ name: String) -> String { "\(name)'s" }

    // MARK: Parsing helpers

    private static func name(_ raw: Any?) -> String {
        nonEmpty((raw as? [String: Any])?["name"]) ?? ""
    }

    /// Absent, JSON null, non-string and blank all read as nil.
    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
