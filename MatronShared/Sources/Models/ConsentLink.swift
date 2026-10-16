import Foundation

/// The link the journal puts on a consent ask's tracker item (matron-journal
/// `src/consent-items.js`, `consentLink`): `matron://consent/spawn/<request_id>`
/// for an agent-spawn ask, `matron://consent/chat/<room_id>/<device_id>` for
/// an agent-chat ask, and `matron://consent/<contact|share|room|session|handover>/<id>`
/// for the person-to-person asks (`sharing-events.js`,
/// `person-rooms-events.js`). It is how a client recognises the item as a consent
/// mirror and finds the ask the item stands for — the `consent` label on the
/// same item is decoration.
///
/// Strict by design, like `MatronItemLink.itemNumber`: only the canonical
/// form is accepted — exactly the segments the journal writes, no query, no
/// fragment. Scheme and host compare case-insensitively (RFC 3986); the kind
/// and the ids are matched as written. The path is read off
/// `URLComponents.percentEncodedPath` so a trailing slash or an
/// percent-encoded digit cannot slip past the shape check.
public enum ConsentLink: Equatable, Hashable, Sendable {
    /// One agent asking to start another on a box — answered on
    /// `POST /agent-spawn/answer` with this request id.
    case spawn(requestID: String)
    /// One agent asking to chat with (or join) a session — answered on
    /// `POST /agent-chat/answer` with the room and the target device.
    case chat(roomID: String, deviceID: Int64)
    /// A contact request — answered through the mirror item's own buttons.
    case contact(id: String)
    /// A read-only mission share (the journal's grant id).
    case share(id: String)
    /// A room with another person's agent, talk requests included (the
    /// journal's room link id).
    case room(id: String)
    /// A session made reachable by a contact's agents.
    case session(id: String)
    /// A mission or project hand-over (the journal's grant id).
    case handover(id: String)

    /// The person-to-person kinds as the journal names them — the path
    /// segment of the link, and the `consent` extra on the mirror's markers.
    public static let peopleKinds: Set<String> = ["contact", "share", "room", "session", "handover"]

    /// A person-to-person link from its journal kind and id; `nil` for any
    /// other kind or an empty id.
    public static func people(consentKind: String, id: String) -> ConsentLink? {
        guard !id.isEmpty else { return nil }
        switch consentKind {
        case "contact": return .contact(id: id)
        case "share": return .share(id: id)
        case "room": return .room(id: id)
        case "session": return .session(id: id)
        case "handover": return .handover(id: id)
        default: return nil
        }
    }

    /// The canonical link, exactly as the journal writes it.
    public var url: String {
        switch self {
        case .spawn(let id): return "matron://consent/spawn/\(id)"
        case .chat(let room, let device): return "matron://consent/chat/\(room)/\(device)"
        case .contact(let id): return "matron://consent/contact/\(id)"
        case .share(let id): return "matron://consent/share/\(id)"
        case .room(let id): return "matron://consent/room/\(id)"
        case .session(let id): return "matron://consent/session/\(id)"
        case .handover(let id): return "matron://consent/handover/\(id)"
        }
    }

    public static func parse(_ url: URL) -> ConsentLink? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "matron",
              parts.host?.lowercased() == "consent",
              parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil
        else { return nil }
        let path = parts.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        // Keep empty segments: `/spawn//x` and `/spawn/x/` must both fail the
        // exact-shape check below rather than collapse into a valid link.
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch segments.first {
        case "spawn":
            guard segments.count == 2, !segments[1].isEmpty else { return nil }
            return .spawn(requestID: segments[1])
        case "chat":
            guard segments.count == 3, !segments[1].isEmpty,
                  let device = positiveDeviceID(segments[2]) else { return nil }
            return .chat(roomID: segments[1], deviceID: device)
        case .some(let kind) where peopleKinds.contains(kind):
            guard segments.count == 2 else { return nil }
            return people(consentKind: kind, id: segments[1])
        default:
            return nil
        }
    }

    public static func parse(_ string: String) -> ConsentLink? {
        guard let url = URL(string: string) else { return nil }
        return parse(url)
    }

    /// Plain ASCII digits, greater than zero — `Int64(_:)` alone would take
    /// `+7` and `-7`.
    private static func positiveDeviceID(_ raw: String) -> Int64? {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let id = Int64(raw), id > 0 else { return nil }
        return id
    }
}

public extension TrackerItem {
    /// The consent ask this item mirrors, read from its links — `nil` for an
    /// ordinary item. The first well-formed consent link wins; the journal
    /// writes exactly one.
    var consentLink: ConsentLink? {
        links.lazy.compactMap { ConsentLink.parse($0.url) }.first
    }

    /// The spawn request id this item stands for, when it is the mirror of
    /// an agent-spawn ask — the key `POST /agent-spawn/answer` takes.
    var spawnConsentRequestID: String? {
        if case .spawn(let requestID) = consentLink { return requestID }
        return nil
    }

    /// Whether this item is the journal's mirror of a consent card (spawn,
    /// chat or person-to-person) — decided by the link, never by the `consent` label, which an
    /// agent could put on any item.
    var isConsentAsk: Bool { consentLink != nil }
}
