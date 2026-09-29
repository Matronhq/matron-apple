import XCTest
@testable import MatronDesignSystem

/// Pins `ItemCommentComposer.canSubmit(_:hasAttachments:)` — the single
/// predicate shared by the trailing mic/send switch and plain Return's send
/// decision. Mirrors `ComposerViewModel.canSend`: all-whitespace can't send,
/// a staged attachment on its own can.
final class ItemCommentComposerTests: XCTestCase {
    func test_canSubmit_false_forEmptyDraft() {
        XCTAssertFalse(ItemCommentComposer.canSubmit(""))
    }

    func test_canSubmit_false_forWhitespaceOnlyDraft() {
        XCTAssertFalse(ItemCommentComposer.canSubmit("   \n\t  "))
    }

    func test_canSubmit_true_forNonBlankDraft() {
        XCTAssertTrue(ItemCommentComposer.canSubmit("fix the tests"))
    }

    func test_canSubmit_true_whenSurroundedByWhitespace() {
        // Trimmed, not rejected outright — matches `ComposerViewModel`'s
        // own predicate (leading/trailing whitespace around real content
        // is still a sendable message).
        XCTAssertTrue(ItemCommentComposer.canSubmit("  hi  "))
    }

    func test_canSubmit_true_forAStagedAttachmentWithNoText() {
        XCTAssertTrue(ItemCommentComposer.canSubmit("", hasAttachments: true))
        XCTAssertTrue(ItemCommentComposer.canSubmit("  \n ", hasAttachments: true))
    }

    func test_canSubmit_true_forTextAndAttachments() {
        XCTAssertTrue(ItemCommentComposer.canSubmit("see attached", hasAttachments: true))
    }
}
