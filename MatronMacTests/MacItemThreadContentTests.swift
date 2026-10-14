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
}
#endif
