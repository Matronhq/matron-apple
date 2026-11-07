import Foundation
import Observation
import MatronModels
import MatronJournal

/// Settings ▸ People: the user's contacts, the invite links they have made,
/// and minting a new one. Loads nothing until the screen calls `load()`.
@MainActor @Observable
public final class PeopleViewModel {
    public private(set) var contacts: [Contact] = []
    public private(set) var invites: [ContactInvite] = []
    public private(set) var isLoading = false
    public private(set) var isMinting = false
    /// Invite ids being withdrawn, so their buttons wait.
    public private(set) var withdrawing: Set<String> = []
    /// The last refusal, in words; cleared by the next successful action.
    public var errorMessage: String?
    /// The journal answered `federation_off`: no invite links here, and the
    /// screen says why instead of offering them.
    public private(set) var federationOff = false
    /// The link just minted, shown once. Never kept anywhere else: dropping
    /// it (`dismissMinted()`) is the last anyone sees of it.
    public var minted: MintedInvite?

    private let api: any ContactsProviding

    public init(api: any ContactsProviding) {
        self.api = api
    }

    /// Open invites, newest first: the ones still waiting to be used.
    public var openInvites: [ContactInvite] { invites.filter { $0.state == .open } }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            contacts = try await api.listContacts()
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            invites = try await api.listInvites()
            federationOff = false
        } catch ContactInviteError.federationOff {
            invites = []
            federationOff = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func createInvite() async {
        guard !isMinting else { return }
        isMinting = true
        defer { isMinting = false }
        do {
            let made = try await api.createInvite()
            minted = made
            errorMessage = nil
            if let invite = made.invite { invites.removeAll { $0.id == invite.id }; invites.insert(invite, at: 0) }
        } catch ContactInviteError.federationOff {
            federationOff = true
            errorMessage = ContactInviteError.federationOff.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func dismissMinted() { minted = nil }

    public func withdraw(_ invite: ContactInvite) async {
        guard !withdrawing.contains(invite.id) else { return }
        withdrawing.insert(invite.id)
        defer { withdrawing.remove(invite.id) }
        do {
            let updated = try await api.withdrawInvite(id: invite.id)
            if let index = invites.firstIndex(where: { $0.id == invite.id }) { invites[index] = updated }
            errorMessage = nil
        } catch JournalAPIError.notFound {
            // Gone already (used or withdrawn elsewhere): show what the
            // journal has now.
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The "Add a contact on another Matron" sheet for one invite link. Opening
/// the link asks the user's own journal who it is from and sends nothing;
/// only `accept()` is consent. Cancel simply drops the model.
@MainActor @Observable
public final class AddContactViewModel: Identifiable {
    public enum Phase: Equatable {
        case opening
        case preview(ContactInvitePreview)
        case accepting(ContactInvitePreview)
        /// The answer is on its way to their journal.
        case accepted(Contact)
        case refused(String)
    }

    public let link: ContactInviteLink
    /// One sheet per link.
    public nonisolated var id: String { link.raw }
    public private(set) var phase: Phase = .opening
    /// A refusal of the accept itself, shown under the preview so the
    /// details stay readable.
    public private(set) var acceptError: String?

    private let api: any ContactsProviding

    public init(link: ContactInviteLink, api: any ContactsProviding) {
        self.link = link
        self.api = api
    }

    public func open() async {
        phase = .opening
        acceptError = nil
        do {
            phase = .preview(try await api.openInvite(link))
        } catch {
            phase = .refused(error.localizedDescription)
        }
    }

    public func accept() async {
        guard case .preview(let preview) = phase else { return }
        phase = .accepting(preview)
        acceptError = nil
        do {
            phase = .accepted(try await api.acceptInvite(link))
        } catch let error as ContactInviteError {
            switch error {
            // The link itself is no good: nothing left to accept.
            case .fingerprintMismatch, .ownJournal, .journalNotAllowed, .journalBlocked, .federationOff, .badLink:
                phase = .refused(error.localizedDescription)
            default:
                phase = .preview(preview)
                acceptError = error.localizedDescription
            }
        } catch {
            phase = .preview(preview)
            acceptError = error.localizedDescription
        }
    }

    public static let title = "Add a contact on another Matron"
    public static let acceptedText = "Added. They'll show as a contact once their journal answers."
}
