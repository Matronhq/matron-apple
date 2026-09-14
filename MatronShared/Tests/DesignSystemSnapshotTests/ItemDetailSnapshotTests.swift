import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

@MainActor
final class ItemDetailSnapshotTests: XCTestCase {
    func testQuestionWithThread() {
        let item = TrackerItem(id: "it_1", num: 12, kind: .question, awaiting: .agent, title: "Which auth library?",
                               body: "Two options:\n\n1. **Keep** the monorepo one\n2. Switch to `authlib`", labels: ["auth", "backend"],
                               links: [TrackerLink(url: "https://github.com/x/y/issues/9", title: "Issue #9")],
                               attachments: [TrackerAttachment(blobRef: "b", mime: "image/png", name: "shot.png", size: 1000)],
                               originConvoID: "c1", createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000), commentCount: 2)
        let comments = [
            TrackerComment(id: "c1", itemID: "it_1", author: .user, body: "Keep the monorepo one.",
                           attachments: [TrackerAttachment(blobRef: "v", mime: "audio/mp4", name: "voice-note.m4a", size: 100, transcript: "keep the monorepo one, it's already tested")],
                           createdAt: .init(timeIntervalSince1970: 1_770_000_100)),
            TrackerComment(id: "c2", itemID: "it_1", author: .agent, body: "Noted — wiring it now.", createdAt: .init(timeIntervalSince1970: 1_770_000_200)),
        ]
        let model = ItemDetailView.Model(item: item, comments: comments,
                                         pending: [.init(id: "L1", body: "Also rename the module", attachmentCount: 0, attempts: 2, lastError: "offline"),
                                                   .init(id: "L2", body: "Fix the tests too", attachmentCount: 0, attempts: 0, lastError: nil)],
                                         originTitle: "auth refactor", availableResolutions: [.answered, .cancelled], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant(""),
                                  image: { _ in
                                      Image(size: CGSize(width: 320, height: 200), label: Text("shot")) { ctx in
                                          ctx.fill(Path(CGRect(origin: .zero, size: CGSize(width: 320, height: 200))), with: .color(.teal))
                                      }
                                  },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Date(timeIntervalSince1970: 1_770_000_600))
            .frame(width: 380, height: 760)
        assertVariants(of: view, named: "ItemDetail_question")
    }

    func testClosedDecision() {
        let item = TrackerItem(id: "it_2", num: 4, kind: .decision, state: .closed, resolution: .reversed, title: "Use SQLite for the cache",
                               body: "Because it is already a dependency.", originConvoID: "c1", closedAt: .init(timeIntervalSince1970: 1_770_000_300))
        let status = TrackerComment(id: "s", itemID: "it_2", author: .user, kind: .status, body: "Postgres after all",
                                    statusFrom: .init(state: .open, resolution: nil, awaiting: nil), statusTo: .init(state: .closed, resolution: .reversed, awaiting: nil),
                                    createdAt: .init(timeIntervalSince1970: 1_770_000_300))
        let model = ItemDetailView.Model(item: item, comments: [status], pending: [], originTitle: nil, availableResolutions: [], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant("Draft text"), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Date(timeIntervalSince1970: 1_770_000_600))
            .frame(width: 380, height: 520)
        assertVariants(of: view, named: "ItemDetail_closedDecision")
    }

    /// A wide host (a dragged-out Mac pane, or the narrow-takeover on a big
    /// window) must not stretch the thread across the window: the column
    /// caps at `ItemTypography.measure` and centres, and the composer row
    /// caps to the same width so its accessory buttons sit on the column's
    /// text edges with the field inset between them (tracker #66).
    func testWideHostCapsAndCentresTheColumn() {
        let item = TrackerItem(id: "it_3", num: 28, kind: .question, awaiting: .user, title: "bev re-pin prunes editor/node_modules — patch-package then fails",
                               body: "The re-pin step runs `npm ci` in `editor/`, which prunes `node_modules` before `patch-package` has applied the `@cantoo/pdf-lib` patch. The next build then fails on the unpatched module.\n\nTwo options: run `patch-package` as a `postinstall` hook, or move the patch into a fork. I recommend the hook — it is one line in `package.json` and matches how the web app does it.",
                               originConvoID: "c1", createdBy: .agent,
                               createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000), commentCount: 1)
        let comments = [
            TrackerComment(id: "c1", itemID: "it_3", author: .user, body: "Hook is fine.", createdAt: .init(timeIntervalSince1970: 1_770_000_100)),
        ]
        let model = ItemDetailView.Model(item: item, comments: comments, pending: [], originTitle: "bev walkthrough",
                                         availableResolutions: [.answered], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Date(timeIntervalSince1970: 1_770_000_600))
            .frame(width: 900, height: 560)
        assertVariants(of: view, named: "ItemDetail_wide")
    }
}
