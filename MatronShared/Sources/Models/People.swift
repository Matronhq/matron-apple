import Foundation
import Observation

// People: the user's contacts, and contacts on other journals made by
// invite link (journal protocol "Contacts" and "Contacts across journals").

private func date(_ raw: Any?) -> Date? {
    (raw as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
}

private func nonEmpty(_ raw: Any?) -> String? {
    guard let s = raw as? String else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// One of the user's contact rows (`GET /contacts`). `address` is the
/// person's name on this journal, and `name@host` for someone on another
/// journal.
public struct Contact: Identifiable, Equatable, Hashable, Sendable {
    public enum State: String, Equatable, Sendable {
        case awaitingUser = "awaiting_user"
        case pendingOut = "pending_out"
        case pendingIn = "pending_in"
        case active, blocked, declined, removed, expired
    }

    public let id: String
    public let address: String
    /// The other journal's host; `nil` for someone on this journal.
    public let peerJournal: String?
    public let displayName: String?
    public let state: State
    /// Their journal now serves a different key from the one pinned for
    /// this contact: nothing crosses until they send a new invite link.
    public let keyChanged: Bool
    /// When their journal stopped answering; `nil` while it answers, and on
    /// a journal too old to send the field.
    public let unreachableSince: Date?

    public init(id: String, address: String, peerJournal: String? = nil, displayName: String? = nil,
                state: State, keyChanged: Bool = false, unreachableSince: Date? = nil) {
        self.id = id; self.address = address; self.peerJournal = peerJournal
        self.displayName = displayName; self.state = state; self.keyChanged = keyChanged
        self.unreachableSince = unreachableSince
    }

    /// `nil` when the row lacks an id, an address or a state this build knows.
    public init?(json: [String: Any]) {
        guard let id = nonEmpty(json["id"]), let address = nonEmpty(json["address"]),
              let state = (json["state"] as? String).flatMap(State.init(rawValue:))
        else { return nil }
        self.init(id: id, address: address, peerJournal: nonEmpty(json["peer_journal"]),
                  displayName: nonEmpty(json["display_name"]), state: state,
                  keyChanged: json["key_changed"] as? Bool ?? false,
                  unreachableSince: date(json["unreachable_since"]))
    }

    /// Someone on another journal: their address is always shown in full.
    public var isOnAnotherJournal: Bool { peerJournal != nil || address.contains("@") }

    public static let keyChangedNotice = "Their journal's key changed. Ask them for a new invite link."

    /// "Their journal hasn't answered since …", when it has stopped answering.
    public var unreachableLine: String? {
        unreachableSince.map { "Their journal hasn't answered since \($0.formatted(date: .abbreviated, time: .shortened))." }
    }

    /// The row's second line: where the contact stands, when it isn't simply
    /// active.
    public var stateLine: String? {
        switch state {
        case .active: return nil
        case .pendingOut: return "Waiting for them"
        case .pendingIn: return "Waiting for you to accept"
        case .awaitingUser: return "Waiting for your approval"
        case .blocked: return "Blocked"
        case .declined: return "Declined"
        case .removed: return "Removed"
        case .expired: return "Expired"
        }
    }
}

/// An invite link the user made (`GET /contacts/invites`). The link itself
/// is never listed: the journal keeps only its hash.
public struct ContactInvite: Identifiable, Equatable, Hashable, Sendable {
    public enum State: String, Equatable, Sendable { case open, used, expired, revoked }

    public let id: String
    public let state: State
    public let createdAt: Date
    public let expiresAt: Date
    public let usedBy: String?

    public init(id: String, state: State, createdAt: Date, expiresAt: Date, usedBy: String? = nil) {
        self.id = id; self.state = state; self.createdAt = createdAt; self.expiresAt = expiresAt; self.usedBy = usedBy
    }

    public init?(json: [String: Any]) {
        guard let id = nonEmpty(json["id"]),
              let state = (json["state"] as? String).flatMap(State.init(rawValue:)),
              let createdAt = date(json["created_at"]), let expiresAt = date(json["expires_at"])
        else { return nil }
        self.init(id: id, state: state, createdAt: createdAt, expiresAt: expiresAt, usedBy: nonEmpty(json["used_by"]))
    }
}

/// A freshly minted invite and its link, which the journal returns once.
/// Kept in memory only: never written to disk, a store or the tracker.
public struct MintedInvite: Identifiable, Equatable, Sendable {
    public let invite: ContactInvite?
    /// The `matron://` form, which older apps share.
    public let link: String
    /// The https form, from a journal that makes one.
    public let webLink: String?
    /// Minted by Approve on an agent's invite ask, rather than by the
    /// user's own Invite button.
    public let fromAgentAsk: Bool
    public var id: String { invite?.id ?? link }

    public init(invite: ContactInvite?, link: String, webLink: String? = nil, fromAgentAsk: Bool = false) {
        self.invite = invite; self.link = link; self.webLink = webLink; self.fromAgentAsk = fromAgentAsk
    }

    /// The link to send: the https one, which chat apps and mail make
    /// tappable, when the journal made one.
    public var shareLink: String { webLink ?? link }

    public static let lifetimeNote = "Send this link to them yourself. It is shown only now, works once and lasts 7 days. Nobody becomes a contact until they open it and accept."
    public static let agentAskNote = "Shown only on this device, this once."
}

/// A parsed invite link, in either of its forms:
/// `https://<host>/contact#v=1&j=<host>&u=<name>&t=<token>&fp=<fingerprint>`,
/// the one to send (chat apps and mail make it tappable), or
/// `matron://contact?v=1&j=…`, which older apps share. As strict as the
/// journal's own parser: exactly those five fields, once each, in their own
/// shapes; an https link must be on the journal it names, at `/contact`,
/// with nothing but the fragment. The journal checks the link again; this
/// parse only decides that a link is an invite, and names the host for the
/// refusals that mention it.
public struct ContactInviteLink: Equatable, Hashable, Sendable {
    public let host: String
    public let user: String
    /// The whole link as received, sent to the journal unchanged.
    public let raw: String
    /// The https form, rather than `matron://`.
    public let isWebLink: Bool

    public var address: String { "\(user)@\(host)" }

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 1024, let parts = URLComponents(string: trimmed),
              parts.user == nil, parts.password == nil
        else { return nil }
        let items: [URLQueryItem]
        switch parts.scheme?.lowercased() {
        case "matron":
            guard parts.host?.lowercased() == "contact", parts.path.isEmpty || parts.path == "/",
                  parts.port == nil, parts.fragment == nil, let query = parts.queryItems
            else { return nil }
            items = query
        case "https":
            guard parts.path == "/contact", (parts.percentEncodedQuery ?? "").isEmpty,
                  let fragment = parts.percentEncodedFragment, !fragment.isEmpty
            else { return nil }
            var fields = URLComponents()
            fields.percentEncodedQuery = fragment
            guard let query = fields.queryItems else { return nil }
            items = query
        default:
            return nil
        }
        var fields: [String: String] = [:]
        for item in items {
            guard ["v", "j", "u", "t", "fp"].contains(item.name), fields[item.name] == nil else { return nil }
            fields[item.name] = item.value ?? ""
        }
        guard fields["v"] == "1",
              let host = fields["j"]?.lowercased(), Self.isHost(host),
              let user = fields["u"], Self.isName(user),
              let token = fields["t"], token.count == 43,
              token.unicodeScalars.allSatisfy({ Self.base64url.contains($0) }),
              let fp = fields["fp"]?.lowercased(), fp.count == 26,
              fp.unicodeScalars.allSatisfy({ Self.base32.contains($0) })
        else { return nil }
        // An https link is on the journal it names, compared as a URL writes
        // a host: lower case, the default port (`:443`) dropped. A port that
        // can't exist is no link.
        if parts.scheme?.lowercased() == "https" {
            guard let named = URLComponents(string: "https://\(host)").flatMap(Self.authority),
                  let linked = Self.authority(parts), named == linked
            else { return nil }
        }
        self.isWebLink = parts.scheme?.lowercased() == "https"
        self.host = host
        self.user = user
        self.raw = trimmed
    }

    public init?(url: URL) { self.init(url.absoluteString) }

    /// `host[:port]` as a URL writes it, or nil for a port that can't exist.
    private static func authority(_ parts: URLComponents) -> String? {
        guard let host = parts.host, !host.isEmpty else { return nil }
        let lower = host.lowercased()
        guard let port = parts.port else { return lower }
        guard (0...65535).contains(port) else { return nil }
        return port == 443 ? lower : "\(lower):\(port)"
    }

    private static let base64url = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let base32 = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz234567")
    private static let hostChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:[]")

    private static func isHost(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 253 && s.unicodeScalars.allSatisfy { hostChars.contains($0) }
    }

    /// A login name: no `@`, slash, control character or bidirectional
    /// override, so it can't smuggle anything into the sheet's text.
    private static func isName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        return !s.unicodeScalars.contains { scalar in
            scalar == "@" || scalar == "/" || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
        }
    }
}

/// `POST /contacts/invites/open`: who an invite link is from, before the
/// user consents to anything.
public struct ContactInvitePreview: Equatable, Sendable {
    public let address: String
    public let name: String
    public let journal: String
    /// Grouped in fours by the journal, for reading out.
    public let fingerprint: String
    /// The journal is known here under another key; accepting this link
    /// pins the new one.
    public let keyChanged: Bool
    /// The user's existing live row for that address, if any.
    public let contact: Contact?

    public init(address: String, name: String, journal: String, fingerprint: String,
                keyChanged: Bool = false, contact: Contact? = nil) {
        self.address = address; self.name = name; self.journal = journal
        self.fingerprint = Self.grouped(fingerprint); self.keyChanged = keyChanged; self.contact = contact
    }

    public init?(json: [String: Any]) {
        guard let inviter = json["inviter"] as? [String: Any],
              let address = nonEmpty(inviter["address"]), let journal = nonEmpty(inviter["journal"]),
              let fingerprint = nonEmpty(inviter["fingerprint"])
        else { return nil }
        self.init(address: address, name: nonEmpty(inviter["name"]) ?? address, journal: journal,
                  fingerprint: fingerprint, keyChanged: json["key_changed"] as? Bool ?? false,
                  contact: (json["contact"] as? [String: Any]).flatMap(Contact.init(json:)))
    }

    /// The fingerprint in groups of four, whatever grouping it came in.
    public static func grouped(_ fingerprint: String) -> String {
        let bare = fingerprint.filter { !$0.isWhitespace && $0 != "-" }
        return stride(from: 0, to: bare.count, by: 4).map { start in
            let from = bare.index(bare.startIndex, offsetBy: start)
            let to = bare.index(from, offsetBy: 4, limitedBy: bare.endIndex) ?? bare.endIndex
            return String(bare[from..<to])
        }.joined(separator: " ")
    }

    public static let checkNote = "Compare this fingerprint with them another way, in person or on a call, before you accept."

    public var headline: String { "\(address) invites you to be contacts" }
}

/// Why opening or accepting an invite link was refused, in the words every
/// app uses.
public enum ContactInviteError: Error, Equatable, Sendable, LocalizedError {
    case fingerprintMismatch
    case journalNotAllowed(host: String)
    case ownJournal
    case unreachable(host: String)
    case federationOff
    case journalBlocked(host: String)
    case alreadyContact
    case pending
    case blocked
    case tooManyInvites
    case tooManyContacts
    case badLink
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .fingerprintMismatch:
            return "This link's fingerprint does not match their journal. Do not accept it; ask them for a new link."
        case .journalNotAllowed(let host): return "Your journal doesn't allow contacts on \(host)."
        case .ownJournal: return "This link is from your own journal. Add people here by name instead."
        case .unreachable: return "Their journal could not be reached. Try again later."
        case .federationOff: return "Contacts on other Matrons are turned off on your journal."
        case .journalBlocked(let host): return "Your journal doesn't allow contacts on \(host)."
        case .alreadyContact: return "You're already contacts."
        case .pending: return "You've already accepted an invite from them. Waiting for their journal to answer."
        case .blocked: return "You've blocked this person."
        case .tooManyInvites: return "You have 20 open invites, the most the journal allows. Withdraw one first."
        case .tooManyContacts: return "You have the most contacts on other journals the journal allows."
        case .badLink: return "This isn't a Matron invite link."
        case .other(let message): return message
        }
    }
}

/// A minted invite link waiting to be shown on this device: the answer to
/// the user's Approve tap on an agent's invite ask. The tap may go through
/// the offline outbox, so the link can arrive after the tap's screen is
/// gone; the app shell shows it once and drops it. Never persisted.
/// Several approvals flushing together queue up: each link is shown in
/// turn, since the journal never returns one twice.
@MainActor @Observable
public final class MintedInviteLinks {
    public static let shared = MintedInviteLinks()

    private var queue: [MintedInvite] = []

    public init() {}

    /// The next link to show, if any.
    public var pending: MintedInvite? { queue.first }

    public func receive(_ minted: MintedInvite) { queue.append(minted) }

    /// The next link, once: a second window asking gets the one after it,
    /// or `nil`.
    public func take() -> MintedInvite? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// The minted links one shell is showing in its links sheet. A link that
/// arrives while the sheet is up joins it. The sheet closes only by Done,
/// which drops exactly the links on screen when it was tapped: one that
/// arrives after that stays, and the sheet comes back for it, since the
/// journal never returns it again.
@MainActor @Observable
public final class ShownInviteLinks {
    public private(set) var links: [MintedInvite] = []

    public init() {}

    public func add(_ minted: MintedInvite) { links.append(minted) }

    /// Done was tapped with these links on screen: drop them.
    public func acknowledge(_ ids: [String]) {
        let seen = Set(ids)
        links.removeAll { seen.contains($0.id) }
    }
}

/// An invite link opened from outside the app (the system camera, another
/// app, a tapped link) waiting for a signed-in shell to show its sheet.
@MainActor @Observable
public final class IncomingInviteLinks {
    public static let shared = IncomingInviteLinks()

    public private(set) var pending: ContactInviteLink?

    public init() {}

    /// Keeps `url` when it is an invite link; `false` for anything else.
    @discardableResult
    public func receive(_ url: URL) -> Bool {
        guard let link = ContactInviteLink(url: url) else { return false }
        pending = link
        return true
    }

    public func receive(_ link: ContactInviteLink) { pending = link }

    public func take() -> ContactInviteLink? {
        defer { pending = nil }
        return pending
    }
}
