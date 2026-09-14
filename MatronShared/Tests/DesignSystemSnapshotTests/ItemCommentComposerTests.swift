import XCTest
@testable import MatronDesignSystem

/// Pins `ItemCommentComposer.canSubmit(_:)` — the single predicate shared by
/// the trailing mic/send switch and, on the Mac, the plain-Return
/// send-vs-newline decision (`.onKeyPress(.return)`). Mirrors
/// `ComposerViewModel.canSend`'s own "all-whitespace can't send" rule.
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
}
