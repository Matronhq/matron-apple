import XCTest
import MatronEvents
import MatronModels
@testable import MatronDesignSystem

/// The hand-over card's words and the attribution lines on markers. The
/// card's state machine lives in `ChatViewModel`; these pin what it says.
final class MissionHandoverRequestCardTests: XCTestCase {
    private func card(_ direction: PersonConsentCard.Direction, kind: MissionHandoverDetails.SubjectKind = .mission,
                      brief: String = "Where it stands.") -> PersonConsentCard {
        PersonConsentCard(
            kind: .missionHandover, direction: direction,
            personName: direction == .outgoing ? "bob" : "alice", askID: "gr_9",
            missionTitle: "Cover editor", level: "owner",
            handover: MissionHandoverDetails(
                subjectKind: kind, subjectTitle: "Cover editor", brief: brief, milestones: 4, items: 6,
                comments: 12,
                attachments: [.init(mediaID: "md_1", name: "proof.pdf", size: 240_000, itemNum: 12)]))
    }

    func testTheButtonsSayApproveForTheOwnerAndAcceptForTheRecipient() {
        XCTAssertEqual(PersonConsentRequestCard.approveLabel(for: card(.outgoing)), "Approve")
        XCTAssertEqual(PersonConsentRequestCard.approveLabel(for: card(.incoming)), "Accept")
    }

    func testTheAnsweredLines() {
        XCTAssertEqual(PersonConsentRequestCard.answeredText(for: card(.outgoing), approved: true),
                       "Approved. Waiting for bob.")
        XCTAssertEqual(PersonConsentRequestCard.answeredText(for: card(.outgoing), approved: false),
                       "Declined. Nothing was sent.")
        XCTAssertEqual(PersonConsentRequestCard.answeredText(for: card(.incoming), approved: true),
                       "Accepted. The mission is yours.")
        XCTAssertEqual(PersonConsentRequestCard.answeredText(for: card(.incoming, kind: .project), approved: true),
                       "Accepted. The project is yours.")
        XCTAssertEqual(PersonConsentRequestCard.answeredText(for: card(.incoming), approved: false), "Declined.")
    }

    func testAFileLineSaysItsSizeAndItem() {
        XCTAssertEqual(PersonConsentRequestCard.attachmentMeta(.init(mediaID: "a", name: "x", size: 0, itemNum: 12)),
                       "on #12")
        XCTAssertNil(PersonConsentRequestCard.attachmentMeta(.init(mediaID: "a", name: "x")))
        XCTAssertTrue(PersonConsentRequestCard.attachmentMeta(.init(mediaID: "a", name: "x", size: 240_000, itemNum: 3))?
            .hasSuffix(" · on #3") == true)
    }

    func testOnlyALongBriefOffersTheWholeBrief() {
        XCTAssertFalse(PersonConsentRequestCard.briefMayBeClipped("Short."))
        XCTAssertTrue(PersonConsentRequestCard.briefMayBeClipped(Array(repeating: "line", count: 9).joined(separator: "\n")))
        XCTAssertTrue(PersonConsentRequestCard.briefMayBeClipped(String(repeating: "word ", count: 120)))
    }

    func testTheBriefKeepsItsLineBreaksAndReadsInlineMarkdown() {
        let text = PersonConsentRequestCard.briefText("**Next:** proofs\nThen print.")
        XCTAssertEqual(String(text.characters), "Next: proofs\nThen print.")
    }

    func testTheSummaryCarriesTheCountsAndBrief() {
        XCTAssertEqual(PersonConsentRequestCard.accessibilitySummary(for: card(.incoming)),
                       "Mission hand-over. alice wants to hand a mission over to you. Mission: Cover editor. "
                       + "4 milestones · 6 items · 12 comments · 1 file. Brief: Where it stands.")
    }

    func testAShareSummarySaysItsLevel() {
        let share = PersonConsentCard(kind: .missionShare, direction: .incoming, personName: "alice", askID: "gr_1",
                                      missionTitle: "Cover editor", level: "contribute")
        XCTAssertEqual(PersonConsentRequestCard.accessibilitySummary(for: share),
                       "Mission share. alice wants to share a mission with you. You can contribute. "
                       + "Mission: Cover editor. Can contribute.")
    }

    func testAHandedOverMissionSaysToWhom() {
        XCTAssertEqual(MissionNotice.text(for: MissionMarkerEvent(missionID: "ms_1", num: 3, title: "Cover editor",
                                                                  action: .closed, handedOverTo: "bob")),
                       "🏁 Mission #3 handed to bob · Cover editor")
        XCTAssertEqual(MissionNotice.text(for: MissionMarkerEvent(missionID: "ms_1", num: 3, action: .left,
                                                                  handedOverTo: "bob")),
                       "🏁 Left mission #3 · handed to bob")
        XCTAssertEqual(MissionNotice.text(for: MissionMarkerEvent(missionID: "ms_1", num: 3, action: .closed)),
                       "🏁 Mission #3 closed")
    }

    func testAContributorsMilestoneSaysBy() {
        let marker = MilestoneMarkerEvent(milestoneID: "ml_1", num: 7, kind: .progress, title: "Proofs in",
                                          missionID: "ms_1", missionNum: 3, missionTitle: "Cover editor",
                                          person: Contributor(name: "bob", via: .agent))
        XCTAssertEqual(MilestoneCard.subtitle(for: marker), "Progress · Cover editor · by bob's agent")
    }
}
