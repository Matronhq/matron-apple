import Foundation
import os
import MatronModels

private let contactsAPILogger = Logger(subsystem: "chat.matron", category: "contacts-api")

/// The People surface: the user's contacts, and invite links for contacts
/// on other journals (journal protocol "Contacts across journals"). Every
/// route here is for client devices; an agent never sees a link.
public protocol ContactsProviding: Sendable {
    /// `GET /contacts`: the live rows.
    func listContacts() async throws -> [Contact]
    /// `GET /contacts/invites`: the last 30 days, newest first.
    func listInvites() async throws -> [ContactInvite]
    /// `POST /contacts/invites`: the link comes back this once.
    func createInvite() async throws -> MintedInvite
    /// `DELETE /contacts/invites/:id`: withdraw an open invite.
    @discardableResult
    func withdrawInvite(id: String) async throws -> ContactInvite
    /// `POST /contacts/invites/open`: who the link is from. Sends nothing.
    func openInvite(_ link: ContactInviteLink) async throws -> ContactInvitePreview
    /// `POST /contacts/invites/accept`: the user's consent. The row comes
    /// back `pending_out` until the inviter's journal acknowledges.
    func acceptInvite(_ link: ContactInviteLink) async throws -> Contact
}

extension JournalAPI: ContactsProviding {
    /// The journal's refusal in the words every app shows. `host` names the
    /// other journal for the refusals that mention it.
    static func contactInviteError(status: Int, data: Data, host: String?) -> Error {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (obj?["blocked_by"] as? String) ?? (obj?["error"] as? String)
        let host = host ?? "that journal"
        switch (status, code) {
        case (409, "fingerprint_mismatch"): return ContactInviteError.fingerprintMismatch
        case (409, "journal_not_allowed"): return ContactInviteError.journalNotAllowed(host: host)
        case (409, "journal_blocked"): return ContactInviteError.journalBlocked(host: host)
        case (409, "own_journal"): return ContactInviteError.ownJournal
        case (409, "federation_off"): return ContactInviteError.federationOff
        case (409, "already_contact"): return ContactInviteError.alreadyContact
        case (409, "pending"): return ContactInviteError.pending
        case (409, "blocked"): return ContactInviteError.blocked
        case (409, "too_many_invites"): return ContactInviteError.tooManyInvites
        case (409, "too_many_contacts"): return ContactInviteError.tooManyContacts
        case (502, "unreachable"), (502, "bad_journal"): return ContactInviteError.unreachable(host: host)
        case (400, _): return ContactInviteError.badLink
        default: return JournalAPI.error(status: status, data: data)
        }
    }

    private func contactsRequest(path: String, method: String = "GET", body: [String: Any]? = nil,
                                 accept: Set<Int> = [200], host: String? = nil) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: method, body: body)
        guard accept.contains(response.statusCode) else {
            throw Self.contactInviteError(status: response.statusCode, data: data, host: host)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JournalAPIError.transport("non-JSON response for \(path)")
        }
        return obj
    }

    static func decodeContacts(_ obj: [String: Any]) throws -> [Contact] {
        guard let rows = obj["contacts"] as? [Any] else { throw JournalAPIError.transport("malformed contacts list") }
        return rows.compactMap { element in
            if let row = element as? [String: Any], let contact = Contact(json: row) { return contact }
            contactsAPILogger.error("dropped malformed contact row")
            return nil
        }
    }

    static func decodeInvites(_ obj: [String: Any]) throws -> [ContactInvite] {
        guard let rows = obj["invites"] as? [Any] else { throw JournalAPIError.transport("malformed invites list") }
        return rows.compactMap { ($0 as? [String: Any]).flatMap(ContactInvite.init(json:)) }
    }

    /// `{invite?, link}` from a mint, or `nil` when the body carries no
    /// invite link (a decline, an answer to some other ask).
    public static func decodeMinted(_ obj: [String: Any]) -> MintedInvite? {
        guard let link = obj["link"] as? String, ContactInviteLink(link) != nil else { return nil }
        return MintedInvite(invite: (obj["invite"] as? [String: Any]).flatMap(ContactInvite.init(json:)), link: link)
    }

    public func listContacts() async throws -> [Contact] {
        try Self.decodeContacts(try await contactsRequest(path: "/contacts"))
    }

    public func listInvites() async throws -> [ContactInvite] {
        try Self.decodeInvites(try await contactsRequest(path: "/contacts/invites"))
    }

    public func createInvite() async throws -> MintedInvite {
        let obj = try await contactsRequest(path: "/contacts/invites", method: "POST", body: [:], accept: [201])
        guard let minted = Self.decodeMinted(obj) else { throw JournalAPIError.transport("malformed invite") }
        return minted
    }

    @discardableResult
    public func withdrawInvite(id: String) async throws -> ContactInvite {
        let obj = try await contactsRequest(path: "/contacts/invites/\(Self.pathSegment(id))", method: "DELETE")
        guard let invite = (obj["invite"] as? [String: Any]).flatMap(ContactInvite.init(json:)) else {
            throw JournalAPIError.transport("malformed invite")
        }
        return invite
    }

    public func openInvite(_ link: ContactInviteLink) async throws -> ContactInvitePreview {
        let obj = try await contactsRequest(path: "/contacts/invites/open", method: "POST",
                                            body: ["link": link.raw], host: link.host)
        guard let preview = ContactInvitePreview(json: obj) else { throw JournalAPIError.transport("malformed invite preview") }
        return preview
    }

    public func acceptInvite(_ link: ContactInviteLink) async throws -> Contact {
        let obj = try await contactsRequest(path: "/contacts/invites/accept", method: "POST",
                                            body: ["link": link.raw], accept: [202], host: link.host)
        guard let contact = (obj["contact"] as? [String: Any]).flatMap(Contact.init(json:)) else {
            throw JournalAPIError.transport("malformed contact")
        }
        return contact
    }
}
