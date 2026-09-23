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
    /// comment that is not a status row — including one with no typed
    /// body (a voice note), which a drag passes through and the
    /// transcript stands in a marker for. Status rows are centred captions,
    /// not cards.
    func testSelectionOrderIsBodyThenEveryNonStatusComment() {
        let comments = [
            comment("c1", "Keep it."),
            comment("s1", "closed", kind: .status),
            comment("c2", "", author: .agent),
            comment("c3", "Done.", author: .agent),
        ]
        XCTAssertEqual(ItemDetailView.selectionOrder(item: item(), comments: comments),
                       [ItemDetailView.bodySelectionID(for: "it_1"), "c1", "c2", "c3"])
    }

    /// An item filed with neither a body nor attachments renders no body
    /// card, so the order starts at the first comment; attachments alone
    /// still make a card.
    func testSelectionOrderIncludesTheBodyCardOnlyWhenItRenders() {
        XCTAssertEqual(ItemDetailView.selectionOrder(item: item(body: ""), comments: [comment("c1", "Hi")]), ["c1"])
        let withFile = TrackerItem(id: "it_1", num: 12, kind: .task, title: "Shot", body: "",
                                   attachments: [TrackerAttachment(blobRef: "b", mime: "image/png", name: "shot.png", size: 1)],
                                   originConvoID: "c1")
        XCTAssertEqual(ItemDetailView.selectionOrder(item: withFile, comments: []),
                       [ItemDetailView.bodySelectionID(for: "it_1")])
    }

    /// The body card's selection id is minted from the item id, and both
    /// item and comment ids come from the journal — the order must stay
    /// collision-free even if a comment id equals the item id, because
    /// the controller keys its targets by id.
    func testBodySelectionIDNeverCollidesWithACommentID() {
        let clash = TrackerItem(id: "same", num: 1, kind: .task, title: "t", body: "b", originConvoID: "c1")
        let order = ItemDetailView.selectionOrder(item: clash, comments: [comment("same", "reply")])
        XCTAssertEqual(order.count, 2)
        XCTAssertEqual(Set(order).count, 2, "duplicate selection ids: \(order)")
    }

    /// A voice-note reply with no typed body has no text view, so its span
    /// arrives with `nil` text — it still copies, as its transcript. A
    /// typed comment with a file gets the file marker on its own line
    /// after the text. A card whose text view exists but has nothing
    /// selected is skipped whole, markers included.
    func testTranscriptStandsInMarkersForAttachments() {
        let voice = TrackerAttachment(blobRef: "v", mime: "audio/mp4", name: "note.m4a", size: 1, transcript: "keep it, it's tested")
        let file = TrackerAttachment(blobRef: "f", mime: "application/pdf", name: "spec.pdf", size: 1)
        let comments = [
            TrackerComment(id: "c1", itemID: "it_1", author: .user, body: "", attachments: [voice], createdAt: t0.addingTimeInterval(60)),
            TrackerComment(id: "c2", itemID: "it_1", author: .agent, body: "See the spec.", attachments: [file], createdAt: t0.addingTimeInterval(120)),
            TrackerComment(id: "c3", itemID: "it_1", author: .agent, body: "Ignored.", attachments: [file], createdAt: t0.addingTimeInterval(180)),
        ]
        let spans = [SelectedSpan(id: "c1", text: nil), SelectedSpan(id: "c2", text: "See the spec."), SelectedSpan(id: "c3", text: "")]
        let transcript = ItemDetailView.transcript(item: item(), comments: comments, spans: spans,
                                                   locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(transcript.messageCount, 2)
        XCTAssertTrue(transcript.text.contains("] Me: [Voice note] keep it, it's tested\n["), transcript.text)
        XCTAssertTrue(transcript.text.hasSuffix("] Agent: See the spec.\n[File: spec.pdf]"), transcript.text)
        XCTAssertFalse(transcript.text.contains("Ignored"))
        XCTAssertEqual(ItemDetailView.attachmentMarker(TrackerAttachment(blobRef: "p", mime: "image/png", name: "p.png", size: 1)), "[Photo]")
        XCTAssertEqual(ItemDetailView.attachmentMarker(TrackerAttachment(blobRef: "a", mime: "audio/mp4", name: "a.m4a", size: 1)), "[Voice note]")
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
