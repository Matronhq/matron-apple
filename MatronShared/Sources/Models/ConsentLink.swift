import Foundation

/// The link the journal puts on a consent ask's tracker item (matron-journal
/// `src/consent-items.js`, `consentLink`): `matron://consent/spawn/<request_id>`
/// for an agent-spawn ask, `matron://consent/chat/<room_id>/<device_id>` for
/// an agent-chat ask. It is how a client recognises the item as a consent
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

    /// Whether this item is the journal's mirror of a consent card (spawn or
    /// chat) — decided by the link, never by the `consent` label, which an
    /// agent could put on any item.
    var isConsentAsk: Bool { consentLink != nil }
}
