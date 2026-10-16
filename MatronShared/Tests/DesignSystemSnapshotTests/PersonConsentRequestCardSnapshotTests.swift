import XCTest
import SwiftUI
import SnapshotTesting
import MatronEvents
@testable import MatronDesignSystem

/// Visual baselines for `PersonConsentRequestCard`, the inert people card.
/// One per footer a user meets: a link to the open mirror (outgoing and
/// incoming), the plain hint when no mirror was found, and the settled line
/// once the mirror is closed. Fixture names only.
final class PersonConsentRequestCardSnapshotTests: XCTestCase {
    private func card(_ card: PersonConsentCard, canOpen: Bool = true) -> some View {
        PersonConsentRequestCard(card: card, onOpenItem: canOpen ? { _ in } : nil)
            .frame(width: 360)
            .padding()
    }

    func test_outgoingContact() {
        let contact = PersonConsentCard(kind: .contactRequest, direction: .outgoing, personName: "bob",
                                        askID: "cr_1", mirror: .open(itemID: "it_1"))
        assertVariants(of: card(contact), named: "peopleCard_outgoingContact")
    }

    func test_incomingTalk() {
        let talk = PersonConsentCard(kind: .personRoom, direction: .incoming, personName: "alice",
                                     askID: "pr_1", topic: "the cover editor", talk: true,
                                     mirror: .open(itemID: "it_2"))
        assertVariants(of: card(talk), named: "peopleCard_incomingTalk")
    }

    func test_noMirrorHint() {
        let share = PersonConsentCard(kind: .sessionShare, direction: .incoming, personName: "alice",
                                      askID: "ss_1", sessionTitle: "box-a")
        assertVariants(of: card(share), named: "peopleCard_noMirrorHint")
    }

    func test_settled() {
        let share = PersonConsentCard(kind: .missionShare, direction: .outgoing, personName: "bob",
                                      askID: "ms_1", missionTitle: "Release notes",
                                      mirror: .closed(itemID: "it_3"))
        assertVariants(of: card(share), named: "peopleCard_settled")
    }
}
