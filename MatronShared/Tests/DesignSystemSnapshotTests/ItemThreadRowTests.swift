import XCTest
import MatronEvents
import MatronModels
@testable import MatronDesignSystem

/// The thread's row list: what `ItemDetailView` draws, top to bottom, and
/// what a host that lays the rows out itself is given.
final class ItemThreadRowTests: XCTestCase {
    private func model(item: TrackerItem, comments: [TrackerComment] = [], pending: [ItemDetailView.PendingComment] = [],
                       consent: ItemSpawnConsent? = nil, actions: [String] = []) -> ItemDetailView.Model {
        .init(item: item, comments: comments, pending: pending, availableResolutions: [.done], isBusy: false,
              spawnConsent: consent, actions: actions)
    }

    private func item(body: String = "", labels: [String] = [], attachments: [TrackerAttachment] = [],
                      state: ItemState = .open) -> TrackerItem {
        TrackerItem(id: "it_1", num: 1, kind: .question, state: state, title: "A question", body: body, labels: labels,
                    attachments: attachments, originConvoID: "c1")
    }

    func test_aBareItem_isItsHeaderAndTheRule() {
        XCTAssertEqual(ItemDetailView.rows(for: model(item: item()), offersActions: true), [.header, .divider])
    }

    func test_rowsComeInReadingOrder() {
        let comments = [TrackerComment(id: "a", itemID: "it_1", author: .agent, body: "One"),
                        TrackerComment(id: "b", itemID: "it_1", author: .user, body: "Two")]
        let pending = [ItemDetailView.PendingComment(id: "p", body: "Three", attachmentCount: 0, attempts: 0, lastError: nil)]
        let rows = ItemDetailView.rows(for: model(item: item(body: "Body", labels: ["x"]), comments: comments,
                                                  pending: pending, actions: ["Go"]),
                                       offersActions: true)
        XCTAssertEqual(rows, [.header, .meta, .body, .actions, .divider, .comment("a"), .comment("b"), .pending("p")])
    }

    func test_theBodyRow_isThereForAttachmentsAlone() {
        let attachment = TrackerAttachment(blobRef: "b", mime: "image/png", name: "shot.png", size: 1)
        XCTAssertTrue(ItemDetailView.rows(for: model(item: item(attachments: [attachment])), offersActions: false)
            .contains(.body))
    }

    /// Buttons wired to nothing are not drawn, and a closed item offers none.
    func test_theActionsRow_needsAHandlerAndAnOpenItem() {
        XCTAssertFalse(ItemDetailView.rows(for: model(item: item(), actions: ["Go"]), offersActions: false).contains(.actions))
        XCTAssertFalse(ItemDetailView.rows(for: model(item: item(state: .closed), actions: ["Go"]), offersActions: true)
            .contains(.actions))
        XCTAssertFalse(ItemDetailView.rows(for: model(item: item()), offersActions: true).contains(.actions))
    }

    func test_rowIDs_areUnique_evenWhenACommentIsNamedLikeAFixedRow() {
        let comments = [TrackerComment(id: "header", itemID: "it_1", author: .agent, body: "One"),
                        TrackerComment(id: "p", itemID: "it_1", author: .agent, body: "Two")]
        let pending = [ItemDetailView.PendingComment(id: "p", body: "Three", attachmentCount: 0, attempts: 0, lastError: nil)]
        let ids = ItemDetailView.rows(for: model(item: item(), comments: comments, pending: pending), offersActions: false).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
