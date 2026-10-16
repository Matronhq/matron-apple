#if os(macOS)
import XCTest
import MatronDesignSystem
import MatronModels
@testable import MatronMac

/// The native thread's row model, shared with iOS, as the Mac target sees it.
final class MacItemThreadContentTests: XCTestCase {
    private func contents(_ model: ItemDetailView.Model) -> [ItemThreadRowContent] {
        ItemThreadContentBuilder.contents(rows: ItemDetailView.rows(for: model, offersActions: false), model: model,
                                          answersCommentActions: false)
    }

    func test_bodyAndTextCommentsAreCards() {
        let rows = contents(MacItemThreadFixtures.model(comments: 2))
        let cards = rows.compactMap { content -> ItemThreadRow? in
            if case .card(let card) = content { return card.row }
            return nil
        }
        XCTAssertEqual(cards, [.body, .comment("c0"), .comment("c1")])
    }

    func test_bareStatusCommentIsHosted() {
        let status = MacItemThreadFixtures.comment(9, body: "", kind: .status)
        let rows = contents(MacItemThreadFixtures.model(comments: 0, extra: [status]))
        guard case .hosted(.comment("c9"), _)? = rows.first(where: { $0.row == .comment("c9") }) else {
            return XCTFail("a bare status line should be a hosted row")
        }
    }

    func test_inlineAttachmentSplitsTheBody() {
        let parts = ItemThreadContentBuilder.parts(body: "Before\n\n![shot](attachment:b1)\n\nAfter",
                                                   attachments: [MacItemThreadFixtures.image("b1")])
        XCTAssertEqual(parts.count, 3)
        guard case .markdown = parts[0], case .attachment(let a) = parts[1], case .markdown = parts[2] else {
            return XCTFail("unexpected parts \(parts)")
        }
        XCTAssertEqual(a.blobRef, "b1")
    }

    /// A contributor's post and comment in the user's mission are theirs:
    /// drawn in the other side's colour, never as the user's own.
    func test_contributorCardsAreNotMine() {
        let bob = Contributor(name: "bob")
        let item = TrackerItem(id: "it_fx", num: 1, kind: .task, title: "A thread", body: "Post.", originConvoID: "c1",
                               createdBy: .user, contributor: bob)
        let reply = TrackerComment(id: "c1", itemID: "it_fx", author: .user, body: "Reply.", contributor: bob, attribution: "bob")
        let note = TrackerComment(id: "c2", itemID: "it_fx", author: .user, kind: .status, body: "Closing note.",
                                  statusTo: .init(state: .closed, resolution: .done, awaiting: nil),
                                  contributor: bob, attribution: "bob")
        let own = TrackerComment(id: "c3", itemID: "it_fx", author: .user, body: "Mine.")
        let model = ItemDetailView.Model(item: item, comments: [reply, note, own], pending: [], availableResolutions: [.done],
                                         isBusy: false, loadedCommentCount: 3)
        var mine: [ItemThreadRow: Bool] = [:]
        for case .card(let card) in contents(model) { mine[card.row] = card.mine }
        XCTAssertEqual(mine[.body], false)
        XCTAssertEqual(mine[.comment("c1")], false)
        XCTAssertEqual(mine[.comment("c2")], false)
        XCTAssertEqual(mine[.comment("c3")], true)
    }
}
#endif
