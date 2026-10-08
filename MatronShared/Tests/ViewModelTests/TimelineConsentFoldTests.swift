import XCTest
import MatronChat
import MatronEvents
import MatronModels
@testable import MatronViewModels

/// What the timeline says about consent cards and item cards
/// (`TimelineConsentFold`): a chat card decided anywhere but here settles
/// from the events the decision left in its conversation, and a tracker
/// item shows once, in its latest state.
final class TimelineConsentFoldTests: XCTestCase {
    private func row(_ seq: Int, _ kind: TimelineItem.Kind, sender: String = "journal") -> TimelineItem {
        TimelineItem(id: String(seq), sender: sender, timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
                     kind: kind, isOwn: false)
    }

    private func card(_ seq: Int, room: String = "room-1", target: Int64 = 7) -> TimelineItem {
        row(seq, .agentChatRequest(eventID: String(seq), AgentChatRequest(
            ask: .invite, roomID: room, fromDeviceID: 4, fromName: "hub-box", targetDeviceID: target,
            toName: "oak", topic: "Staff API", justification: "needs logs")))
    }

    private func marker(
        _ seq: Int, item: String = "it_1", num: Int = 9418, action: ItemMarkerEvent.Action,
        awaiting: ItemAwaiting? = nil, resolution: ItemResolution? = nil, note: String? = nil,
        consent: String? = "chat", ask: String? = nil, outcome: String? = nil, decidedBy: String? = nil
    ) -> TimelineItem {
        row(seq, .itemMarker(eventID: String(seq), ItemMarkerEvent(
            itemID: item, num: num, kind: .question, title: "hub-box asks to chat with oak", action: action,
            by: .agent, awaiting: awaiting, resolution: resolution,
            comment: note.map { .init(id: "c\(seq)", body: $0) },
            consent: consent, consentAsk: ask, consentOutcome: outcome, decidedBy: decidedBy)))
    }

    private func coordinatorDecision(_ seq: Int, approve: Bool, ask: String? = "room-1/7") -> TimelineItem {
        row(seq, .consentDecision(eventID: String(seq), ConsentDecisionEvent(
            kind: .chat, decision: approve ? .approve : .decline, reason: "follows the box rules", askID: ask)))
    }

    // MARK: Chat cards

    func testAnUndecidedCardIsLeftAlone() {
        let fold = TimelineConsentFold.read([card(10), marker(11, action: .created, awaiting: .user)])
        XCTAssertNil(fold.chatResolutions["10"])
    }

    /// The bug as reported: the Coordinator approved the ask, and
    /// the card in the chat still offered Decline/Approve.
    func testTheCoordinatorsDecisionSettlesTheCard() {
        let fold = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user),
            marker(12, action: .closed, resolution: .decided,
                   note: "Approved by the Coordinator — follows the box rules. The invitation is on its way."),
            coordinatorDecision(13, approve: true),
        ])
        XCTAssertEqual(fold.chatResolutions["10"], .answeredByCoordinator(approved: true))
    }

    /// A tap on another device leaves no event of its own; the consent
    /// item's closing marker is the record. Journals before `consent_ask`
    /// pair it with its card by position and say the outcome in the note.
    func testATapOnAnotherDeviceSettlesTheCard_fromTheClosingNote() {
        let approved = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user),
            marker(12, action: .closed, resolution: .decided, note: "Approved — the invitation is on its way."),
        ])
        XCTAssertEqual(approved.chatResolutions["10"], .answered(approved: true))

        let declined = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user),
            marker(12, action: .closed, resolution: .decided, note: "Declined."),
        ])
        XCTAssertEqual(declined.chatResolutions["10"], .answered(approved: false))
    }

    func testTheStructuredOutcomeWinsOverTheNote() {
        let fold = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user, ask: "room-1/7"),
            marker(12, action: .closed, resolution: .decided, note: "Approved — whatever the copy says now",
                   ask: "room-1/7", outcome: "denied", decidedBy: "coordinator"),
        ])
        XCTAssertEqual(fold.chatResolutions["10"], .answeredByCoordinator(approved: false))
    }

    func testALapsedAskSettlesAsNoLongerWaiting() {
        let expired = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user),
            marker(12, action: .closed, resolution: .cancelled, note: "Expired — no answer within 24 h."),
        ])
        XCTAssertEqual(expired.chatResolutions["10"], .expired)

        let left = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user, ask: "room-1/7"),
            marker(12, action: .closed, resolution: .cancelled, ask: "room-1/7", outcome: "left"),
        ])
        XCTAssertEqual(left.chatResolutions["10"], .expired)
    }

    /// Closing the mirror by hand does not answer the ask: the row is still
    /// waiting, so the card must keep its buttons.
    func testClosingTheItemByHandLeavesTheCardAnswerable() {
        let withNote = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user),
            marker(12, action: .closed, resolution: .done, note: "not now, will look tomorrow"),
        ])
        XCTAssertNil(withNote.chatResolutions["10"])

        let bare = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user, ask: "room-1/7"),
            marker(12, action: .closed, resolution: .done),
        ])
        XCTAssertNil(bare.chatResolutions["10"])
    }

    /// On a journal that names the ask, a close naming nothing is by hand —
    /// whatever its note says.
    func testAHandCloseOnANewJournalIsNotReadForItsNote() {
        let fold = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user, ask: "room-1/7"),
            marker(12, action: .closed, resolution: .done, note: "Declined for now, ask me later"),
        ])
        XCTAssertNil(fold.chatResolutions["10"])
    }

    func testALaterLapseDoesNotUndoADecision() {
        let fold = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user),
            marker(12, action: .closed, resolution: .decided, note: "Declined."),
            marker(13, action: .reopened, awaiting: .user),
            marker(14, action: .closed, resolution: .cancelled, outcome: "gone"),
        ])
        XCTAssertEqual(fold.chatResolutions["10"], .answered(approved: false))
    }

    /// A Coordinator decision whose item marker is missing (the mirror is
    /// best-effort) still settles the card.
    func testAConsentDecisionAloneSettlesTheCard() {
        let fold = TimelineConsentFold.read([card(10), coordinatorDecision(11, approve: false)])
        XCTAssertEqual(fold.chatResolutions["10"], .answeredByCoordinator(approved: false))
    }

    /// A fresh ask after a decline reuses the room/device key: the old
    /// decision belongs to the old card, and the new card stays answerable —
    /// even when the sweep closes the old item only after the new card.
    func testARenewedAskIsNotSettledByTheOldOnesDecision() {
        let fold = TimelineConsentFold.read([
            card(10), marker(11, item: "it_1", action: .created, awaiting: .user),
            marker(12, item: "it_1", action: .closed, resolution: .decided, note: "Declined."),
            card(20), marker(21, item: "it_2", num: 9500, action: .created, awaiting: .user),
            marker(22, item: "it_1", action: .closed, resolution: .cancelled,
                   note: "Closed — the request is no longer waiting for an answer."),
        ])
        XCTAssertEqual(fold.chatResolutions["10"], .answered(approved: false))
        XCTAssertNil(fold.chatResolutions["20"])

        let decided = TimelineConsentFold.read([
            card(10), marker(11, item: "it_1", action: .created, awaiting: .user),
            marker(12, item: "it_1", action: .closed, resolution: .decided, note: "Declined."),
            card(20), marker(21, item: "it_2", num: 9500, action: .created, awaiting: .user),
            coordinatorDecision(22, approve: true),
        ])
        XCTAssertEqual(decided.chatResolutions["10"], .answered(approved: false))
        XCTAssertEqual(decided.chatResolutions["20"], .answeredByCoordinator(approved: true))
    }

    /// The old item's `created` marker fell outside the snapshot: a close of
    /// it that names the ask must not settle the renewed ask's card, which
    /// its own item has claimed.
    func testAnOldItemsCloseCannotClaimTheRenewedCard() {
        let fold = TimelineConsentFold.read([
            card(20), marker(21, item: "it_2", num: 9500, action: .created, awaiting: .user, ask: "room-1/7"),
            marker(22, item: "it_1", action: .closed, resolution: .cancelled, ask: "room-1/7", outcome: "expired"),
        ])
        XCTAssertNil(fold.chatResolutions["20"])
    }

    /// A named `created` marker whose own card fell outside the snapshot
    /// does not claim an older card for the same pair.
    func testANamedCreatedMarkerDoesNotClaimAnotherAsksCard() {
        let fold = TimelineConsentFold.read([
            card(10), marker(11, item: "it_1", action: .created, awaiting: .user, ask: "room-1/7"),
            marker(21, item: "it_2", num: 9500, action: .created, awaiting: .user, ask: "room-1/7"),
            marker(22, item: "it_2", action: .closed, resolution: .decided, ask: "room-1/7", outcome: "approved"),
        ])
        XCTAssertNil(fold.chatResolutions["10"])
    }

    /// Two asks in one room — an invite and a join — each settle on their own.
    func testTwoAsksInOneRoomPairWithTheirOwnItems() {
        let fold = TimelineConsentFold.read([
            card(10, target: 7), marker(11, item: "it_1", action: .created, awaiting: .user, ask: "room-1/7"),
            card(20, target: 8), marker(21, item: "it_2", num: 9500, action: .created, awaiting: .user, ask: "room-1/8"),
            marker(30, item: "it_1", action: .closed, resolution: .decided, ask: "room-1/7", outcome: "approved"),
        ])
        XCTAssertEqual(fold.chatResolutions["10"], .answered(approved: true))
        XCTAssertNil(fold.chatResolutions["20"])
    }

    // MARK: Item cards

    /// The other half of #9418: an orange "Needs you" card that never
    /// cleared, under it a grey "Done · Decided" one. One card, the latest.
    func testAClosedItemShowsOnce_asItsClosedCard() {
        let fold = TimelineConsentFold.read([
            card(10), marker(11, action: .created, awaiting: .user),
            marker(12, action: .closed, resolution: .decided, note: "Declined."),
        ])
        XCTAssertEqual(fold.hiddenItemRows, ["11"])
        XCTAssertTrue(fold.restatedItemMarkers.isEmpty)
    }

    func testAnOpenItemsCardFollowsItsLaterNotes() {
        let fold = TimelineConsentFold.read([
            marker(11, item: "it_5", num: 5, action: .created, awaiting: .user, consent: nil),
            marker(12, item: "it_5", num: 5, action: .commented, awaiting: .agent, note: "use A", consent: nil),
        ])
        XCTAssertTrue(fold.hiddenItemRows.isEmpty)
        let shown = fold.restatedItemMarkers["11"]
        XCTAssertEqual(shown?.action, .created)
        XCTAssertEqual(shown?.awaiting, .agent)
    }

    func testAReopenedItemsCardIsNoLongerDone() {
        let fold = TimelineConsentFold.read([
            marker(11, item: "it_5", num: 5, action: .created, awaiting: .user, consent: nil),
            marker(12, item: "it_5", num: 5, action: .closed, resolution: .answered, note: "ok", consent: nil),
            marker(13, item: "it_5", num: 5, action: .reopened, awaiting: .agent, consent: nil),
        ])
        XCTAssertEqual(fold.hiddenItemRows, ["11"])
        XCTAssertEqual(fold.restatedItemMarkers["12"]?.action, .created)
        XCTAssertNil(fold.restatedItemMarkers["12"]?.resolution)
    }

    func testDifferentItemsDoNotFoldIntoEachOther() {
        let fold = TimelineConsentFold.read([
            marker(11, item: "it_5", num: 5, action: .created, awaiting: .user, consent: nil),
            marker(12, item: "it_6", num: 6, action: .created, awaiting: .user, consent: nil),
        ])
        XCTAssertTrue(fold.hiddenItemRows.isEmpty)
        XCTAssertTrue(fold.restatedItemMarkers.isEmpty)
    }
}
