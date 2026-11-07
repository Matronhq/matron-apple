import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class PeopleViewModelTests: XCTestCase {
    static let link = ContactInviteLink("matron://contact?v=1&j=a.example&u=alice&t=\(String(repeating: "A", count: 43))&fp=abcdefghijklmnopqrstuvwxyz")!
    static let preview = ContactInvitePreview(address: "alice@a.example", name: "alice", journal: "a.example",
                                              fingerprint: "abcdefghijklmnopqrstuvwxyz")

    private final class API: ContactsProviding, @unchecked Sendable {
        var contacts: [Contact] = []
        var invites: [ContactInvite] = []
        var listInvitesError: Error?
        var mintError: Error?
        var openResult: Result<ContactInvitePreview, Error> = .success(PeopleViewModelTests.preview)
        var acceptResult: Result<Contact, Error> = .success(Contact(id: "ct_1", address: "alice@a.example",
                                                                     peerJournal: "a.example", state: .pendingOut))
        var accepted = 0
        var withdrawn: [String] = []

        func listContacts() async throws -> [Contact] { contacts }
        func listInvites() async throws -> [ContactInvite] {
            if let listInvitesError { throw listInvitesError }
            return invites
        }
        func createInvite() async throws -> MintedInvite {
            if let mintError { throw mintError }
            return MintedInvite(invite: ContactInvite(id: "inv_new", state: .open, createdAt: .now, expiresAt: .now.addingTimeInterval(7 * 86_400)),
                                link: PeopleViewModelTests.link.raw)
        }
        func withdrawInvite(id: String) async throws -> ContactInvite {
            withdrawn.append(id)
            return ContactInvite(id: id, state: .revoked, createdAt: .now, expiresAt: .now)
        }
        func openInvite(_ link: ContactInviteLink) async throws -> ContactInvitePreview { try openResult.get() }
        func acceptInvite(_ link: ContactInviteLink) async throws -> Contact {
            accepted += 1
            return try acceptResult.get()
        }
    }

    func testMintingShowsTheLinkAndListsTheInvite() async {
        let api = API()
        let model = PeopleViewModel(api: api)
        await model.load()
        await model.createInvite()
        XCTAssertEqual(model.minted?.link, Self.link.raw)
        XCTAssertEqual(model.openInvites.map(\.id), ["inv_new"])
        model.dismissMinted()
        XCTAssertNil(model.minted, "shown once, then gone")
    }

    func testWithdrawLeavesTheOpenList() async {
        let api = API()
        api.invites = [ContactInvite(id: "inv_1", state: .open, createdAt: .now, expiresAt: .now.addingTimeInterval(60)),
                       ContactInvite(id: "inv_0", state: .used, createdAt: .now, expiresAt: .now, usedBy: "bob@b.example")]
        let model = PeopleViewModel(api: api)
        await model.load()
        XCTAssertEqual(model.openInvites.map(\.id), ["inv_1"])
        await model.withdraw(model.openInvites[0])
        XCTAssertEqual(api.withdrawn, ["inv_1"])
        XCTAssertTrue(model.openInvites.isEmpty)
    }

    func testFederationOffHidesInvites() async {
        let api = API()
        api.listInvitesError = ContactInviteError.federationOff
        let model = PeopleViewModel(api: api)
        await model.load()
        XCTAssertTrue(model.federationOff)
        XCTAssertNil(model.errorMessage)
    }

    func testOpeningSendsNothingUntilAccept() async {
        let api = API()
        let model = AddContactViewModel(link: Self.link, api: api)
        await model.open()
        XCTAssertEqual(model.phase, .preview(Self.preview))
        XCTAssertEqual(api.accepted, 0)
        await model.accept()
        XCTAssertEqual(api.accepted, 1)
        guard case .accepted(let contact) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(contact.address, "alice@a.example")
    }

    func testAFingerprintMismatchIsARefusalNotAPreview() async {
        let api = API()
        api.openResult = .failure(ContactInviteError.fingerprintMismatch)
        let model = AddContactViewModel(link: Self.link, api: api)
        await model.open()
        XCTAssertEqual(model.phase, .refused("This link's fingerprint does not match their journal. Do not accept it; ask them for a new link."))
    }

    func testAnUnreachableAcceptKeepsThePreviewToTryAgain() async {
        let api = API()
        api.acceptResult = .failure(ContactInviteError.unreachable(host: "a.example"))
        let model = AddContactViewModel(link: Self.link, api: api)
        await model.open()
        await model.accept()
        XCTAssertEqual(model.phase, .preview(Self.preview))
        XCTAssertEqual(model.acceptError, "Their journal could not be reached. Try again later.")
    }
}
