import SwiftUI
import XCTest
import MatronModels
import MatronEvents
@testable import MatronDesignSystem

/// Visual baseline for the inline timeline tracker marker (PR B / Task
/// 13): created/closed cards and commented/filed variants, side by side
/// so a resolution-pill or awaiting-pill regression is obvious at a glance.
@MainActor
final class ItemInlineCardSnapshotTests: XCTestCase {
    func testVariants() {
        let created = ItemMarkerEvent(itemID: "it_1", num: 12, kind: .question, title: "Which auth library?", action: .created, by: .agent, awaiting: .user)
        let closed = ItemMarkerEvent(itemID: "it_1", num: 12, kind: .question, title: "Which auth library?", action: .closed, by: .agent, resolution: .answered)
        let commented = ItemMarkerEvent(itemID: "it_1", num: 12, kind: .question, title: "Which auth library?", action: .commented, by: .user, awaiting: .agent, comment: .init(id: "c", body: "use A"))
        let filed = ItemMarkerEvent(itemID: "it_2", num: 13, kind: .task, title: "Refactor auth", action: .created, by: .user, awaiting: .agent)
        let view = VStack(alignment: .leading, spacing: 8) {
            ItemInlineCard(marker: created, onOpen: {})
            ItemInlineCard(marker: closed, onOpen: {})
            ItemInlineCard(marker: commented, onOpen: {})
            ItemInlineCard(marker: filed, onOpen: {})
        }.padding().frame(width: 380)
        assertVariants(of: view, named: "ItemInlineCard_variants")
    }
}
