import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// A consent ask in a list (item #2318): the row carries a small "Consent"
/// chip so a spawn or chat ask is told apart from an ordinary question at a
/// glance, and VoiceOver says so too (the row's label is one hand-built
/// string — see `ItemRow.accessibilityLabel(for:)`).
@MainActor
final class ItemRowConsentTests: XCTestCase {
    private func consentItem() -> TrackerItem {
        TrackerItem(id: "it_1", num: 2366, kind: .question, awaiting: .user, title: "Approve spawn on dan-mac — consent items",
                    labels: ["consent"], links: [TrackerLink(url: "matron://consent/spawn/spawn-1", title: "Spawn request spawn-1")],
                    originConvoID: "c1")
    }

    func testAccessibilityLabelNamesTheConsentAsk() {
        XCTAssertEqual(ItemRow.accessibilityLabel(for: consentItem()),
                       "Question 2366, Approve spawn on dan-mac — consent items, needs you, consent ask")
        let plain = TrackerItem(id: "it_2", num: 12, kind: .question, awaiting: .user, title: "Which auth library?", originConvoID: "c1")
        XCTAssertEqual(ItemRow.accessibilityLabel(for: plain), "Question 12, Which auth library?, needs you")
    }

    func testConsentRowVariants() {
        let view = VStack(alignment: .leading, spacing: 12) {
            ItemRow(item: consentItem())
            ItemRow(item: consentItem(), showsOrigin: "consent deploy")
        }
        .frame(width: 360)
        .padding()
        assertVariants(of: view, named: "ItemRow_consent")
    }
}
