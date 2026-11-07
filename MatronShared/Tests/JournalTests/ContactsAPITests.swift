import XCTest
import MatronModels
@testable import MatronJournal

/// People across journals (journal protocol "Contacts across journals"):
/// the invite link's shape, the routes and bodies, and every refusal in
/// the words the apps share.
final class ContactsAPITests: XCTestCase {
    static let token = String(repeating: "A", count: 42) + "_"
    static let fp = "abcdefghijklmnopqrstuvwxyz"
    static let link = "matron://contact?v=1&j=a.example&u=alice&t=\(token)&fp=\(fp)"

    private func makeStubbedAPI(status: Int, body: [String: Any]) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://b.example")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private var lastBodyJSON: [String: Any]? {
        ItemsStubURLProtocol.lastBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    // MARK: The link

    func testParsesTheJournalsLink() throws {
        let link = try XCTUnwrap(ContactInviteLink(Self.link))
        XCTAssertEqual(link.host, "a.example")
        XCTAssertEqual(link.user, "alice")
        XCTAssertEqual(link.address, "alice@a.example")
        XCTAssertEqual(link.raw, Self.link)
        XCTAssertNotNil(ContactInviteLink("  \(Self.link)\n"), "pasted with whitespace")
        XCTAssertNotNil(ContactInviteLink(Self.link.replacingOccurrences(of: "a.example", with: "localhost:9810")))
    }

    func testRefusesAnyOtherShape() {
        let bad = [
            Self.link + "&x=1",                                   // another field
            Self.link + "&u=bob",                                 // a field twice
            Self.link.replacingOccurrences(of: "v=1", with: "v=2"),
            Self.link.replacingOccurrences(of: "matron://contact", with: "matron://item"),
            Self.link.replacingOccurrences(of: "matron://", with: "https://"),
            Self.link.replacingOccurrences(of: Self.token, with: "short"),
            Self.link.replacingOccurrences(of: Self.fp, with: "abc1"),
            Self.link.replacingOccurrences(of: "u=alice", with: "u=al%40ice"),
            Self.link.replacingOccurrences(of: "u=alice", with: "u="),
            Self.link + "#frag",
            "",
            "alice@a.example",
        ]
        for s in bad { XCTAssertNil(ContactInviteLink(s), s) }
    }

    func testIncomingLinksTakeOnlyInviteLinks() async {
        await MainActor.run {
            let incoming = IncomingInviteLinks()
            XCTAssertFalse(incoming.receive(URL(string: "https://b.example/u/bob/12")!))
            XCTAssertNil(incoming.pending)
            XCTAssertTrue(incoming.receive(URL(string: Self.link)!))
            XCTAssertEqual(incoming.take()?.address, "alice@a.example")
            XCTAssertNil(incoming.take(), "taken once")
        }
    }

    func testFingerprintIsGroupedInFours() {
        XCTAssertEqual(ContactInvitePreview.grouped("abcdefghijklmnopqrstuvwxyz"), "abcd efgh ijkl mnop qrst uvwx yz")
        XCTAssertEqual(ContactInvitePreview.grouped("abcd efgh ijkl"), "abcd efgh ijkl")
    }

    // MARK: Routes

    func testCreateInvitePostsAndReturnsTheLinkOnce() async throws {
        let api = makeStubbedAPI(status: 201, body: [
            "invite": ["id": "inv_1", "state": "open", "created_at": 1_000, "expires_at": 605_800_000],
            "link": Self.link,
        ])
        let minted = try await api.createInvite()
        XCTAssertEqual(minted.link, Self.link)
        XCTAssertEqual(minted.invite?.id, "inv_1")
        XCTAssertEqual(minted.invite?.state, .open)
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/contacts/invites")
    }

    func testListAndWithdrawInvites() async throws {
        var api = makeStubbedAPI(status: 200, body: ["invites": [
            ["id": "inv_2", "state": "open", "created_at": 2_000, "expires_at": 9_000],
            ["id": "inv_1", "state": "used", "created_at": 1_000, "expires_at": 9_000, "used_by": "bob@b.example"],
            ["id": "broken"],
        ]])
        let invites = try await api.listInvites()
        XCTAssertEqual(invites.map(\.id), ["inv_2", "inv_1"])
        XCTAssertEqual(invites[1].usedBy, "bob@b.example")

        api = makeStubbedAPI(status: 200, body: ["invite": ["id": "inv_2", "state": "revoked", "created_at": 2_000, "expires_at": 9_000]])
        let withdrawn = try await api.withdrawInvite(id: "inv_2")
        XCTAssertEqual(withdrawn.state, .revoked)
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/contacts/invites/inv_2")
    }

    func testOpenSendsTheLinkAndReadsWhoItIsFrom() async throws {
        let api = makeStubbedAPI(status: 200, body: [
            "inviter": ["address": "alice@a.example", "name": "alice", "journal": "a.example",
                        "fingerprint": "abcd efgh ijkl mnop qrst uvwx yz"],
            "key_changed": false, "contact": NSNull(),
        ])
        let preview = try await api.openInvite(XCTUnwrap(ContactInviteLink(Self.link)))
        XCTAssertEqual(preview.address, "alice@a.example")
        XCTAssertEqual(preview.journal, "a.example")
        XCTAssertEqual(preview.fingerprint, "abcd efgh ijkl mnop qrst uvwx yz")
        XCTAssertNil(preview.contact)
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/contacts/invites/open")
        XCTAssertEqual(lastBodyJSON?["link"] as? String, Self.link)
    }

    func testAcceptReturnsThePendingRow() async throws {
        let api = makeStubbedAPI(status: 202, body: [
            "contact": ["id": "ct_1", "address": "alice@a.example", "peer_user": "alice", "peer_journal": "a.example",
                        "state": "pending_out", "key_changed": false],
            "pending": "peer",
        ])
        let contact = try await api.acceptInvite(XCTUnwrap(ContactInviteLink(Self.link)))
        XCTAssertEqual(contact.state, .pendingOut)
        XCTAssertTrue(contact.isOnAnotherJournal)
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.url?.path, "/contacts/invites/accept")
    }

    func testContactsListKeepsTheFullAddressAndKeyChange() async throws {
        let api = makeStubbedAPI(status: 200, body: ["contacts": [
            ["id": "ct_1", "address": "alice@a.example", "peer_journal": "a.example", "state": "active", "key_changed": true],
            ["id": "ct_2", "address": "carol", "peer_journal": NSNull(), "state": "active", "key_changed": false],
            ["id": "ct_3", "address": "bob@b.example", "peer_journal": "b.example", "state": "active",
             "unreachable_since": 1_700_000_000_000],
        ]])
        let contacts = try await api.listContacts()
        XCTAssertEqual(contacts.map(\.address), ["alice@a.example", "carol", "bob@b.example"])
        XCTAssertNil(contacts[0].unreachableSince, "no line when the journal doesn't send the field")
        XCTAssertNil(contacts[0].unreachableLine)
        XCTAssertEqual(contacts[2].unreachableSince, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(contacts[2].unreachableLine?.hasPrefix("Their journal hasn't answered since ") == true)
        XCTAssertTrue(contacts[0].keyChanged)
        XCTAssertTrue(contacts[0].isOnAnotherJournal)
        XCTAssertFalse(contacts[1].isOnAnotherJournal)
        XCTAssertEqual(Contact.keyChangedNotice, "Their journal's key changed. Ask them for a new invite link.")
    }

    // MARK: Refusals

    private func refusal(_ status: Int, _ body: [String: Any]) async -> String? {
        let api = makeStubbedAPI(status: status, body: body)
        do {
            _ = try await api.openInvite(ContactInviteLink(Self.link)!)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testRefusalsUseTheSharedWords() async {
        let fingerprint = await refusal(409, ["error": "conflict", "blocked_by": "fingerprint_mismatch"])
        XCTAssertEqual(fingerprint, "This link's fingerprint does not match their journal. Do not accept it; ask them for a new link.")
        let notAllowed = await refusal(409, ["error": "conflict", "blocked_by": "journal_not_allowed"])
        XCTAssertEqual(notAllowed, "Your journal doesn't allow contacts on a.example.")
        let own = await refusal(409, ["error": "conflict", "blocked_by": "own_journal"])
        XCTAssertEqual(own, "This link is from your own journal. Add people here by name instead.")
        let unreachable = await refusal(502, ["error": "unreachable"])
        XCTAssertEqual(unreachable, "Their journal could not be reached. Try again later.")
        let off = await refusal(409, ["error": "conflict", "blocked_by": "federation_off"])
        XCTAssertEqual(off, "Contacts on other Matrons are turned off on your journal.")
    }

    // MARK: An agent's invite ask

    func testAnApprovedAskHandsTheLinkToThisDevice() async throws {
        let api = makeStubbedAPI(status: 200, body: [
            "item": ItemsAPITests.itemJSON,
            "comment": NSNull(),
            "ask": ["id": "ia_1", "state": "approved"],
            "invite": ["id": "inv_1", "state": "open", "created_at": 1_000, "expires_at": 9_000],
            "link": Self.link,
        ])
        await MainActor.run { while MintedInviteLinks.shared.take() != nil {} }
        _ = try await api.commentItem(id: "it_1", body: "Approve", attachments: [], action: "Approve", replyTo: nil, idempotencyKey: nil)
        let shown = await MainActor.run { MintedInviteLinks.shared.take() }
        XCTAssertEqual(shown?.link, Self.link)
        XCTAssertEqual(shown?.invite?.id, "inv_1")
        XCTAssertEqual(shown?.fromAgentAsk, true, "says it is shown only on this device")
    }

    func testMintedLinksQueueSoNoneIsLost() async {
        await MainActor.run {
            let links = MintedInviteLinks()
            links.receive(MintedInvite(invite: nil, link: "first"))
            links.receive(MintedInvite(invite: nil, link: "second"))
            XCTAssertEqual(links.pending?.link, "first")
            XCTAssertEqual(links.take()?.link, "first")
            XCTAssertEqual(links.pending?.link, "second", "the next waits its turn")
            XCTAssertEqual(links.take()?.link, "second")
            XCTAssertNil(links.take())
        }
    }

    func testClosingTheLinksSheetKeepsLinksItNeverShowed() async {
        await MainActor.run {
            let shown = ShownInviteLinks()
            shown.add(MintedInvite(invite: nil, link: "first"))
            shown.markDisplayed(shown.links.map(\.id))
            shown.add(MintedInvite(invite: nil, link: "late"))  // arrives during the close
            XCTAssertTrue(shown.closed(), "the sheet comes back")
            XCTAssertEqual(shown.links.map(\.link), ["late"])
            shown.markDisplayed(shown.links.map(\.id))
            XCTAssertFalse(shown.closed())
            XCTAssertTrue(shown.links.isEmpty)
        }
    }

    func testA400OnlyMeansABadLinkWhereALinkWasSent() async {
        let open = await refusal(400, ["error": "bad_request"])
        XCTAssertEqual(open, "This isn't a Matron invite link.")
        let api = makeStubbedAPI(status: 400, body: ["error": "bad_request"])
        do {
            _ = try await api.createInvite()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertNotEqual(error.localizedDescription, "This isn't a Matron invite link.")
        }
    }

    func testDecodeMintedIgnoresAnythingButAnInviteLink() {
        XCTAssertNil(JournalAPI.decodeMinted([:]))
        XCTAssertNil(JournalAPI.decodeMinted(["link": "https://a.example/u/alice/1"]))
        XCTAssertEqual(JournalAPI.decodeMinted(["link": Self.link])?.link, Self.link)
        XCTAssertEqual(JournalAPI.decodeMinted(["link": Self.link])?.fromAgentAsk, false)
    }
}
