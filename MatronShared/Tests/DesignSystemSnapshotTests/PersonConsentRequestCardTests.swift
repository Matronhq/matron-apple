import XCTest
import MatronEvents
@testable import MatronDesignSystem

/// The people card has no answer buttons; its one way on is the tracker
/// mirror. These pin what the footer offers in each state, so a card never
/// draws a link with nothing behind it.
final class PersonConsentRequestCardTests: XCTestCase {
    private let talk = PersonConsentCard(kind: .personRoom, direction: .incoming, personName: "alice",
                                         askID: "pr_1", topic: "the cover editor", talk: true)

    func testAnOpenMirrorIsALinkToAnswerIt() {
        XCTAssertEqual(PersonConsentRequestCard.footer(for: talk.withMirror(.open(itemID: "it_1")), canOpen: true),
                       .link("Answer in the tracker", itemID: "it_1"))
    }

    func testAClosedMirrorSaysSoAndStillOpens() {
        XCTAssertEqual(PersonConsentRequestCard.footer(for: talk.withMirror(.closed(itemID: "it_1")), canOpen: true),
                       .settledLink("Open in the tracker", itemID: "it_1"))
        XCTAssertEqual(PersonConsentRequestCard.footer(for: talk.withMirror(.closed(itemID: "it_1")), canOpen: false),
                       .settled)
    }

    func testNoMirrorOrNowhereToOpenItIsAPlainHint() {
        XCTAssertEqual(PersonConsentRequestCard.footer(for: talk, canOpen: true),
                       .hint("Answer it in your tracker, under For you."))
        XCTAssertEqual(PersonConsentRequestCard.footer(for: talk.withMirror(.open(itemID: "it_1")), canOpen: false),
                       .hint("Answer it in your tracker, under For you."))
    }

    func testTheSummaryCarriesWhoWhichWayAndTopic() {
        XCTAssertEqual(PersonConsentRequestCard.accessibilitySummary(for: talk),
                       "Talk request. alice's agent wants to talk. About: the cover editor.")
    }
}
