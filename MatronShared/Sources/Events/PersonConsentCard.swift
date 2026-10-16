import Foundation
import MatronModels

/// One of the journal's person-to-person consent cards: a contact request, a
/// mission share (read-only, or as a contributor), a session made reachable
/// by a contact's agents, a room with another person's agent (talk requests
/// included), or a mission or project hand-over.
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
///
/// The hand-over card is the exception to "inert": it carries the brief and
/// what would cross (`handover`), and the app answers it itself on
/// `POST /grants/:id/answer` — the owner leaving files behind, which the
/// mirror's one-tap Approve cannot.
public struct PersonConsentCard: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case contactRequest = "contact_request"
        case missionShare = "mission_share"
        case sessionShare = "session_share"
        case personRoom = "person_room"
        case missionHandover = "mission_handover"
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
    /// The grant level a mission share asks for: `read` (also when absent)
    /// or `contribute`. A hand-over is always `owner`.
    public let level: String?
    /// A hand-over's brief, subject and preview; `nil` on every other kind.
    public let handover: MissionHandoverDetails?
    public let mirror: Mirror

    public init(kind: Kind, direction: Direction, personName: String, askID: String?,
                topic: String? = nil, missionTitle: String? = nil, sessionTitle: String? = nil,
                talk: Bool = false, level: String? = nil, handover: MissionHandoverDetails? = nil,
                mirror: Mirror = .unknown) {
        self.kind = kind
        self.direction = direction
        self.personName = personName
        self.askID = askID
        self.topic = topic
        self.missionTitle = missionTitle
        self.sessionTitle = sessionTitle
        self.talk = talk
        self.level = level
        self.handover = handover
        self.mirror = mirror
    }

    /// A mission share that lets the other person write into the mission.
    public var canContribute: Bool { kind == .missionShare && level == "contribute" }

    /// `nil` unless `payload.kind` is one of the four people kinds.
    public static func parse(payload: [String: Any]) -> PersonConsentCard? {
        guard let kind = (payload["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        let direction: Direction = payload["direction"] as? String == "out" ? .outgoing : .incoming
        let person: String
        let askID: String?
        var missionTitle: String?
        var handover: MissionHandoverDetails?
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
        case .missionHandover:
            // Who receives it on the owner's card, who gives it on theirs.
            person = name(direction == .outgoing ? payload["grantee"] : payload["owner"])
            askID = nonEmpty(payload["grant_id"])
            let details = MissionHandoverDetails.parse(payload: payload)
            missionTitle = details.subjectTitle
            handover = details
        }
        return PersonConsentCard(
            kind: kind, direction: direction, personName: person, askID: askID,
            topic: nonEmpty(payload["topic"]), missionTitle: missionTitle,
            sessionTitle: nonEmpty(payload["session_title"]),
            talk: payload["talk"] as? Bool ?? false,
            level: nonEmpty(payload["level"]), handover: handover)
    }

    public func withMirror(_ mirror: Mirror) -> PersonConsentCard {
        PersonConsentCard(kind: kind, direction: direction, personName: personName, askID: askID,
                          topic: topic, missionTitle: missionTitle, sessionTitle: sessionTitle,
                          talk: talk, level: level, handover: handover, mirror: mirror)
    }

    /// The journal's name for this kind of ask: the `consent` extra on the
    /// mirror's item markers, and the kind segment of its consent link.
    public var consentKind: String {
        switch kind {
        case .contactRequest: return "contact"
        case .missionShare: return "share"
        case .sessionShare: return "session"
        case .personRoom: return "room"
        case .missionHandover: return "handover"
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
        case .missionHandover:
            return handover?.subjectKind == .project ? "Project hand-over" : "Mission hand-over"
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
            return canContribute
                ? "Your agent asks to share a mission with \(personObject), who can contribute."
                : "Your agent asks to share a mission with \(personObject), read-only."
        case (.missionShare, .incoming):
            return canContribute
                ? "\(personLabel) wants to share a mission with you. You can contribute."
                : "\(personLabel) wants to share a mission with you, read-only."
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
        case (.missionHandover, .outgoing):
            return "Your agent asks to hand this \(subjectNoun) over to \(personObject)."
        case (.missionHandover, .incoming):
            return "\(personLabel) wants to hand a \(subjectNoun) over to you."
        }
    }

    private var subjectNoun: String { handover?.subjectKind == .project ? "project" : "mission" }

    /// The level line a mission share shows: "Can contribute" or
    /// "Read-only". `nil` on every other kind.
    public var accessLine: String? {
        guard kind == .missionShare else { return nil }
        return canContribute ? "Can contribute" : "Read-only"
    }

    /// What the owner keeps once the recipient takes it over, on the
    /// recipient's hand-over card. `nil` on every other card.
    public var keepLine: String? {
        guard kind == .missionHandover, direction == .incoming, let handover else { return nil }
        switch handover.keepLevel {
        case .contribute: return "\(personLabel) stays on as a contributor; you can end that any time."
        case .read: return "\(personLabel) keeps read access."
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

/// What a hand-over card carries beyond who and which way: the subject, the
/// agent-written brief, and what will cross on accept.
public struct MissionHandoverDetails: Equatable, Sendable {
    public enum SubjectKind: String, Equatable, Sendable { case mission, project }

    /// What the owner keeps on the recipient's copy once it is handed over
    /// (`keep_level`): read access, or the right to keep contributing.
    public enum KeepLevel: String, Equatable, Sendable { case read, contribute }

    /// One file that would be copied, on the owner's card. The recipient's
    /// card only gets the count.
    public struct Attachment: Equatable, Sendable, Identifiable {
        public let mediaID: String
        public let name: String
        public let mime: String
        public let size: Int64
        /// The owner's item the file hangs off, for a "on #12" hint.
        public let itemNum: Int?
        public var id: String { mediaID }

        public init(mediaID: String, name: String, mime: String = "", size: Int64 = 0, itemNum: Int? = nil) {
            self.mediaID = mediaID; self.name = name; self.mime = mime; self.size = size; self.itemNum = itemNum
        }
    }

    public let subjectKind: SubjectKind
    public let subjectTitle: String?
    /// The owner's number for it, on the owner's card only.
    public let subjectNum: Int?
    public let brief: String
    public let missions: Int
    public let milestones: Int
    public let items: Int
    public let comments: Int
    /// The files listed one by one — the owner's card.
    public let attachments: [Attachment]
    /// How many files will arrive: the list's length on the owner's card,
    /// the journal's count on the recipient's.
    public let attachmentCount: Int
    /// What the ask proposes the owner keeps. The owner's card can change
    /// it; on the recipient's card it is what they are agreeing to.
    public let keepLevel: KeepLevel

    public init(subjectKind: SubjectKind = .mission, subjectTitle: String? = nil, subjectNum: Int? = nil,
                brief: String = "", missions: Int = 1, milestones: Int = 0, items: Int = 0, comments: Int = 0,
                attachments: [Attachment] = [], attachmentCount: Int? = nil, keepLevel: KeepLevel = .read) {
        self.subjectKind = subjectKind; self.subjectTitle = subjectTitle; self.subjectNum = subjectNum
        self.brief = brief; self.missions = missions; self.milestones = milestones; self.items = items
        self.comments = comments; self.attachments = attachments
        self.attachmentCount = attachmentCount ?? attachments.count
        self.keepLevel = keepLevel
    }

    /// The owner's switch as the ask left it: on when it says `contribute`.
    public var keepContributing: Bool { keepLevel == .contribute }

    public static let keepSwitchLabel = "Keep contributing after the hand-over"

    /// The line under the owner's switch.
    public static func keepHint(keepContributing: Bool) -> String {
        keepContributing ? "You can keep adding milestones, items and comments"
                         : "You keep read access to their copy"
    }

    static func parse(payload: [String: Any]) -> MissionHandoverDetails {
        let subject = payload["subject"] as? [String: Any] ?? [:]
        let preview = payload["preview"] as? [String: Any] ?? [:]
        let count = { (key: String) in (preview[key] as? NSNumber)?.intValue ?? 0 }
        let rawAttachments = preview["attachments"]
        let list = (rawAttachments as? [[String: Any]] ?? []).compactMap { a -> Attachment? in
            guard let id = a["media_id"] as? String, !id.isEmpty else { return nil }
            return Attachment(mediaID: id, name: (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "File",
                              mime: a["mime"] as? String ?? "", size: (a["size"] as? NSNumber)?.int64Value ?? 0,
                              itemNum: (a["item_num"] as? NSNumber)?.intValue)
        }
        let title = (subject["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MissionHandoverDetails(
            subjectKind: (subject["kind"] as? String).flatMap(SubjectKind.init(rawValue:)) ?? .mission,
            subjectTitle: title.flatMap { $0.isEmpty ? nil : $0 },
            subjectNum: (subject["num"] as? NSNumber)?.intValue,
            brief: (payload["brief"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            missions: max(1, (preview["missions"] as? NSNumber)?.intValue ?? 1),
            milestones: count("milestones"), items: count("items"), comments: count("comments"),
            attachments: list,
            attachmentCount: (rawAttachments as? NSNumber)?.intValue ?? list.count,
            // Anything but `contribute` (absent, unknown) is read access,
            // as the journal reads it.
            keepLevel: payload["keep_level"] as? String == "contribute" ? .contribute : .read)
    }

    /// "1 mission · 4 milestones · 6 items · 12 comments · 3 files" — the
    /// missions part only for a project, zero counts left out.
    public func countsLine(includedAttachments: Int? = nil) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String? {
            count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
        }
        let files = includedAttachments ?? attachmentCount
        let parts = [
            subjectKind == .project ? n(missions, "mission", "missions") : nil,
            n(milestones, "milestone", "milestones"),
            n(items, "item", "items"),
            n(comments, "comment", "comments"),
            n(files, "file", "files"),
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing but the brief" : parts.joined(separator: " · ")
    }

    /// The ids to leave behind: every listed file not in `included`, in the
    /// card's order. Empty when everything goes.
    public func excludedMediaIDs(included: Set<String>) -> [String] {
        attachments.map(\.mediaID).filter { !included.contains($0) }
    }
}

/// Where a hand-over card's own Approve / Accept stands. In memory only,
/// like the spawn card's transient states: the durable word is the mirror
/// item, which the journal closes once the ask is answered.
public enum PersonHandoverCardState: Equatable, Sendable {
    /// Answerable.
    case idle
    case sending
    case failed(String)
    /// Answered from this device, this launch.
    case answered(approved: Bool)
    /// No longer waiting: answered elsewhere, expired, withdrawn — or there
    /// is nothing wired to answer it with.
    case settled

    public var isAnswerable: Bool {
        switch self {
        case .idle, .sending, .failed: return true
        case .answered, .settled: return false
        }
    }
}
