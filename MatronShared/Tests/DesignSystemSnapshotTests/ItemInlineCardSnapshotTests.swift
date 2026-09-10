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
        let userReplyMarkdown = ItemMarkerEvent(itemID: "it_3", num: 14, kind: .question, title: "Which billing plan?", action: .commented, by: .user, awaiting: .agent,
                                                comment: .init(id: "c2", body: "Let's go with the **annual** plan — it's cheaper long-term.\n\nWe can revisit at renewal if usage grows a lot."))
        let agentReplyVoiceNote = ItemMarkerEvent(itemID: "it_4", num: 15, kind: .task, title: "Record onboarding demo", action: .reopened, by: .agent, awaiting: .user,
                                                  comment: .init(id: "c3", body: "Reopening — the recording cuts off early.",
                                                                 attachments: [TrackerAttachment(blobRef: "b1", mime: "audio/m4a", name: "demo-take2.m4a", size: 48_000, transcript: "...and that's the last screen.")]))
        let closedWithComment = ItemMarkerEvent(itemID: "it_5", num: 16, kind: .task, title: "Rotate the staging key", action: .closed, by: .user, resolution: .done,
                                                comment: .init(id: "c4", body: "Rotated and verified in staging."))
        let view = VStack(alignment: .leading, spacing: 8) {
            ItemInlineCard(marker: created, onOpen: {})
            ItemInlineCard(marker: closed, onOpen: {})
            ItemInlineCard(marker: commented, onOpen: {})
            ItemInlineCard(marker: filed, onOpen: {})
            ItemInlineCard(marker: userReplyMarkdown, onOpen: {})
            ItemInlineCard(marker: agentReplyVoiceNote, onOpen: {})
            ItemInlineCard(marker: closedWithComment, onOpen: {})
        }.padding().frame(width: 380)
        assertVariants(of: view, named: "ItemInlineCard_variants")
    }
}
