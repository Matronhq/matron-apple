import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Item thread fixes from Dan's 2026-10-01 notes:
/// - an image with a journal-stamped size reserves its real box, so the
///   thread is laid out the same before and after the bytes arrive;
/// - a reply the agent hasn't got yet says so, with Send now.
@MainActor
final class ItemDetailDeliverySnapshotTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func imageThread(loaded: Bool, sized: Bool = true) -> some View {
        let item = TrackerItem(id: "it_1", num: 31, kind: .decision, awaiting: .user, title: "Header layout",
                               body: "Which header?", originConvoID: "c1", createdAt: Self.t0, updatedAt: Self.t0, commentCount: 2)
        let comments = [
            TrackerComment(id: "c1", itemID: "it_1", author: .agent, body: "Before and after:",
                           attachments: [TrackerAttachment(blobRef: "wide", mime: "image/png", name: "wide.png", size: 52_000,
                                                           width: sized ? 1600 : nil, height: sized ? 900 : nil),
                                         TrackerAttachment(blobRef: "tall", mime: "image/jpeg", name: "tall.jpg", size: 91_000,
                                                           width: sized ? 1179 : nil, height: sized ? 2556 : nil)],
                           createdAt: Self.t0.addingTimeInterval(60)),
            TrackerComment(id: "c2", itemID: "it_1", author: .user, body: "The first one.", createdAt: Self.t0.addingTimeInterval(120)),
        ]
        let model = ItemDetailView.Model(item: item, comments: comments, pending: [], originTitle: nil,
                                         availableResolutions: [.decided], isBusy: false)
        return ItemDetailView(model: model, draft: .constant(""),
                              image: { a in
                                  guard loaded, let px = a.pixelSize else { return nil }
                                  return Image(size: px, label: Text(a.name)) { ctx in
                                      ctx.fill(Path(CGRect(origin: .zero, size: px)), with: .color(a.blobRef == "wide" ? .teal : .orange))
                                  }
                              },
                              onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                              onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                              now: Self.t0.addingTimeInterval(600))
            .frame(width: 380, height: 900)
    }

    /// Placeholder and loaded image take the same box: the two snapshots
    /// differ only inside the image frames.
    func testSizedImagesReserveTheirBoxBeforeLoading() {
        assertVariants(of: imageThread(loaded: false), named: "ItemDetail_sizedImages_placeholder")
        assertVariants(of: imageThread(loaded: true), named: "ItemDetail_sizedImages_loaded")
        // Without a size (an older journal) the placeholder is the old
        // 280-pt square, and the thread moves when the image lands.
        assertVariants(of: imageThread(loaded: false, sized: false), named: "ItemDetail_unsizedImages_placeholder")
    }

    func testQueuedRepliesSayTheyAreQueuedWithSendNow() {
        let item = TrackerItem(id: "it_2", num: 32, kind: .question, awaiting: .agent, title: "Ship tonight?",
                               body: "Ready to merge.", originConvoID: "c1", createdAt: Self.t0, updatedAt: Self.t0, commentCount: 4)
        let comments = [
            TrackerComment(id: "d1", itemID: "it_2", author: .user, body: "Yes, ship it.", createdAt: Self.t0.addingTimeInterval(60)),
            TrackerComment(id: "d2", itemID: "it_2", author: .user, body: "And deploy the journal first.", createdAt: Self.t0.addingTimeInterval(90)),
            TrackerComment(id: "d3", itemID: "it_2", author: .user, body: "Actually wait.", createdAt: Self.t0.addingTimeInterval(120)),
            TrackerComment(id: "d4", itemID: "it_2", author: .user, body: "Ignore that.", createdAt: Self.t0.addingTimeInterval(150)),
        ]
        let model = ItemDetailView.Model(
            item: item, comments: comments,
            pending: [.init(id: "L1", body: "Offline reply", attachmentCount: 0, attempts: 3, lastError: nil)],
            originTitle: nil, availableResolutions: [.answered], isBusy: false,
            queuedReplies: ["d2": .queued(convoID: "c1", targetSeq: 10, offersSendOne: true), "d3": .sending,
                            "d4": .cancelled])
        let view = ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Self.t0.addingTimeInterval(600),
                                  onSendQueuedNow: { _ in }, onSendPendingNow: {})
            .frame(width: 380, height: 900)
        assertVariants(of: view, named: "ItemDetail_queuedReplies")
    }
}
