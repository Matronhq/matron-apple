#if os(macOS)
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// The Mac item thread's cross-card selection (tracker #2533): which cards
/// take part, in what order, and what "Copy N Messages" / ⌘C produce from
/// the selected spans. Pure helpers — the drag mechanics themselves are
/// `MessageSelectionController`'s and are tested there.
final class ItemDetailSelectionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func item(body: String = "The original post.") -> TrackerItem {
        TrackerItem(id: "it_1", num: 12, kind: .question, awaiting: .agent, title: "Which?",
                    body: body, originConvoID: "c1", createdBy: .agent, createdAt: t0, updatedAt: t0, commentCount: 0)
    }

    private func comment(_ id: String, _ body: String, author: ItemAuthor = .user, kind: TrackerComment.Kind = .comment,
                         offset: TimeInterval = 60) -> TrackerComment {
        TrackerComment(id: id, itemID: "it_1", author: author, kind: kind, body: body, createdAt: t0.addingTimeInterval(offset))
    }

    /// Row order is the thread order: the body card first, then every
    /// comment with a text body. Status rows and empty bodies have no text
    /// view and so cannot be part of a selection.
    func testSelectionOrderIsBodyThenTextComments() {
        let comments = [
            comment("c1", "Keep it."),
            comment("s1", "closed", kind: .status),
            comment("c2", "", author: .agent),
            comment("c3", "Done.", author: .agent),
        ]
        XCTAssertEqual(ItemDetailView.selectionOrder(item: item(), comments: comments),
                       [ItemDetailView.bodySelectionID(for: "it_1"), "c1", "c3"])
    }

    /// An item filed without a body has no body card, so nothing to select
    /// there — the order starts at the first comment.
    func testSelectionOrderSkipsAnEmptyBody() {
        XCTAssertEqual(ItemDetailView.selectionOrder(item: item(body: ""), comments: [comment("c1", "Hi")]), ["c1"])
    }

    /// The body card's selection id must not collide with a comment id —
    /// both come from the journal, and the controller keys its targets by id.
    func testBodySelectionIDIsDistinctFromTheItemID() {
        XCTAssertNotEqual(ItemDetailView.bodySelectionID(for: "it_1"), "it_1")
    }

    /// The transcript reads like the chat timeline's: "[date] Name: text"
    /// per selected card, in row order, skipping cards whose selected part
    /// is empty (the pointer sat in the gap above them).
    func testTranscriptFormatsSelectedCardsInOrder() {
        let comments = [comment("c1", "Keep it.", author: .user), comment("c2", "Done.", author: .agent, offset: 120)]
        let spans = [
            SelectedSpan(id: ItemDetailView.bodySelectionID(for: "it_1"), text: "original post."),
            SelectedSpan(id: "c1", text: ""),
            SelectedSpan(id: "c2", text: "Done."),
        ]
        let gb = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC")!
        let transcript = ItemDetailView.transcript(item: item(), comments: comments, spans: spans, locale: gb, timeZone: utc)
        XCTAssertEqual(transcript.messageCount, 2)
        let expectedBody = "[" + Self.stamp(t0, gb, utc) + "] Agent: original post."
        let expectedDone = "[" + Self.stamp(t0.addingTimeInterval(120), gb, utc) + "] Agent: Done."
        XCTAssertEqual(transcript.text, expectedBody + "\n" + expectedDone)
    }

    /// The author names follow the card captions: the user is "Me" (the
    /// timeline's own word for the reader), the agent is "Agent".
    func testTranscriptNamesTheUserMeAndTheAgentAgent() {
        let spans = [SelectedSpan(id: "c1", text: "Keep it.")]
        let transcript = ItemDetailView.transcript(item: item(), comments: [comment("c1", "Keep it.", author: .user)],
                                                   spans: spans, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(transcript.text.hasSuffix("] Me: Keep it."), transcript.text)
        XCTAssertEqual(transcript.messageCount, 1)
    }

    /// A span whose id is not in the thread (a card that left the model
    /// under a finished selection) contributes nothing rather than crashing
    /// or inventing an author.
    func testTranscriptIgnoresUnknownSpans() {
        let transcript = ItemDetailView.transcript(item: item(), comments: [], spans: [SelectedSpan(id: "ghost", text: "x")])
        XCTAssertEqual(transcript.messageCount, 0)
        XCTAssertEqual(transcript.text, "")
    }

    private static func stamp(_ date: Date, _ locale: Locale, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale; f.timeZone = tz; f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }
}
#endif
