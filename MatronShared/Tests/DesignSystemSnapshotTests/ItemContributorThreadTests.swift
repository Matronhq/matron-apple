import XCTest
import MatronModels
@testable import MatronDesignSystem

/// An item's thread when another person writes into the user's mission: a
/// contributor's post or comment is theirs, not the user's, wherever the
/// thread names or tints it — the status line, the card colour and a copied
/// transcript.
final class ItemContributorThreadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    private func closing(author: ItemAuthor, contributor: Contributor? = nil, attribution: String? = nil,
                         from: ItemState = .open, to: ItemState = .closed) -> TrackerComment {
        TrackerComment(id: "c1", itemID: "it_1", author: author, kind: .status, body: "",
                       statusFrom: .init(state: from, resolution: nil, awaiting: .user),
                       statusTo: .init(state: to, resolution: to == .closed ? .done : nil, awaiting: nil),
                       createdAt: t0, contributor: contributor, attribution: attribution)
    }

    func testStatusLineNamesTheContributor() {
        XCTAssertEqual(ItemDetailView.statusLine(closing(author: .user, contributor: Contributor(name: "bob"),
                                                         attribution: "bob")),
                       "bob closed this as done")
        XCTAssertEqual(ItemDetailView.statusLine(closing(author: .agent, contributor: Contributor(name: "bob", via: .agent))),
                       "bob's agent closed this as done")
        let reopen = closing(author: .user, contributor: Contributor(name: "bob"), from: .closed, to: .open)
        XCTAssertEqual(ItemDetailView.statusLine(reopen), "bob reopened this")
    }

    func testStatusLineForTheUsersOwnSideIsUnchanged() {
        XCTAssertEqual(ItemDetailView.statusLine(closing(author: .user)), "You closed this as done")
        XCTAssertEqual(ItemDetailView.statusLine(closing(author: .agent)), "Agent closed this as done")
    }

    func testOnlyTheUsersOwnWritingIsMine() {
        let own = TrackerComment(id: "c1", itemID: "it_1", author: .user, body: "ok", createdAt: t0)
        let bobs = TrackerComment(id: "c2", itemID: "it_1", author: .user, body: "ok", createdAt: t0,
                                  contributor: Contributor(name: "bob"), attribution: "bob")
        let copied = TrackerComment(id: "c3", itemID: "it_1", author: .user, body: "ok", createdAt: t0,
                                    attribution: "alice")
        XCTAssertTrue(own.isMine)
        XCTAssertFalse(bobs.isMine)
        XCTAssertFalse(copied.isMine)
        XCTAssertFalse(TrackerComment(id: "c4", itemID: "it_1", author: .agent, body: "ok", createdAt: t0).isMine)

        let ownItem = TrackerItem(id: "it_1", num: 1, kind: .task, title: "T", originConvoID: "c", createdBy: .user)
        let bobsItem = TrackerItem(id: "it_1", num: 1, kind: .task, title: "T", originConvoID: "c", createdBy: .user,
                                   contributor: Contributor(name: "bob"))
        XCTAssertTrue(ownItem.isMine)
        XCTAssertFalse(bobsItem.isMine)
    }

    #if os(macOS)
    func testTranscriptNamesContributors() {
        let item = TrackerItem(id: "it_1", num: 1, kind: .task, title: "T", body: "The post.", originConvoID: "c",
                               createdBy: .agent, createdAt: t0, contributor: Contributor(name: "bob", via: .agent))
        let reply = TrackerComment(id: "c1", itemID: "it_1", author: .user, body: "Yes.", createdAt: t0.addingTimeInterval(60),
                                   contributor: Contributor(name: "bob"), attribution: "bob")
        let spans = [SelectedSpan(id: ItemDetailView.bodySelectionID(for: "it_1"), text: "The post."),
                     SelectedSpan(id: "c1", text: "Yes.")]
        let text = ItemDetailView.transcript(item: item, comments: [reply], spans: spans, locale: gb, timeZone: utc).text
        XCTAssertTrue(text.contains("] bob's agent: The post."), text)
        XCTAssertTrue(text.contains("] bob: Yes."), text)
        XCTAssertFalse(text.contains("Me:"), text)
    }
    #endif
}
