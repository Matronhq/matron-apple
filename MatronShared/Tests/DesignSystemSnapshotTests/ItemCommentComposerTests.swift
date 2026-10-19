import XCTest
@testable import MatronDesignSystem

/// Pins `ItemCommentComposer.canSubmit(_:hasAttachments:)` — the single
/// predicate shared by the send button's enabled state and plain Return's send
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

    /// A recording note is something to send on its own: send is live
    /// with nothing typed, and it is the one send for text and note alike.
    func test_isSendable_whileANoteRecords_evenWithNothingTyped() {
        XCTAssertTrue(ItemCommentComposer.isSendable("", hasAttachments: false, voiceNote: .recording))
        XCTAssertTrue(ItemCommentComposer.isSendable("pasted text", hasAttachments: false, voiceNote: .recording))
    }

    /// While the microphone starts, send holds, so the text can't go
    /// without the note that is about to record.
    func test_isSendable_false_whileTheMicStarts() {
        XCTAssertFalse(ItemCommentComposer.isSendable("pasted text", hasAttachments: true, voiceNote: .starting))
    }

    func test_isSendable_withNoNote_isCanSubmit() {
        XCTAssertFalse(ItemCommentComposer.isSendable(" ", hasAttachments: false, voiceNote: .none))
        XCTAssertTrue(ItemCommentComposer.isSendable("hi", hasAttachments: false, voiceNote: .none))
        XCTAssertTrue(ItemCommentComposer.isSendable("", hasAttachments: true, voiceNote: .none))
    }
}
