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
                                         context: .init(owner: .init(id: "c1", label: "auth refactor")), availableResolutions: [.answered, .cancelled], isBusy: false)
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
        let model = ItemDetailView.Model(item: item, comments: [status], pending: [], availableResolutions: [], isBusy: false)
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
    /// text edges with the field inset between them.
    func testWideHostCapsAndCentresTheColumn() {
        let item = TrackerItem(id: "it_3", num: 28, kind: .question, awaiting: .user, title: "A clean install drops the local patch — the next build then fails",
                               body: "The setup step runs `npm ci` in `web/`, which clears `node_modules` before `patch-package` has applied the `example-chart` patch. The next build then fails on the unpatched module.\n\nTwo options: run `patch-package` as a `postinstall` hook, or move the patch into a fork. I recommend the hook — it is one line in `package.json` and matches how the web app does it.",
                               originConvoID: "c1", createdBy: .agent,
                               createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000), commentCount: 1)
        let comments = [
            TrackerComment(id: "c1", itemID: "it_3", author: .user, body: "Hook is fine.", createdAt: .init(timeIntervalSince1970: 1_770_000_100)),
        ]
        let model = ItemDetailView.Model(item: item, comments: comments, pending: [], context: .init(owner: .init(id: "c1", label: "build setup")),
                                         availableResolutions: [.answered], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Date(timeIntervalSince1970: 1_770_000_600))
            .frame(width: 900, height: 560)
        assertVariants(of: view, named: "ItemDetail_wide")
    }

    /// A fenced ASCII diagram renders as ONE code box (no per-line strips,
    /// no gaps between lines), and a GFM table as a table — the two bodies
    /// that once broke in a tracker thread.
    func testCodeDiagramAndTable() {
        let diagram = """
        The proposed layout:

        ```
        ┌ #2240  Save memories ──────────── [Overview | Timeline] ┐
        │ STATUS (17pt, full paragraph)                            │
        ├─────────────────────────────┬────────────────────────────┤
        │ Latest step (large)         │ Needs you (items)          │
        └─────────────────────────────┴────────────────────────────┘
        ```

        Two columns above about 900 pt.
        """
        let table = """
        Done at 07:48 UTC on `staging`, for the three approved folders only.

        | Folder | Dry run | Real run | Re-check |
        |---|---|---|---|
        | 101 Guides | would resize 72 | resized 72, thumbnails rebuilt as v3 | nothing to resize |
        | 102 Reference | would resize 96 | resized 96, thumbnails rebuilt as v3 | nothing to resize |
        | 103 Tutorials | would resize 68 | resized 68, thumbnails rebuilt as v3 | nothing to resize |

        0 failed.
        """
        let item = TrackerItem(id: "it_4", num: 41, kind: .question, awaiting: .user, title: "Mission page layout",
                               body: diagram, originConvoID: "c1", createdBy: .agent,
                               createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000), commentCount: 1)
        let comments = [
            TrackerComment(id: "c1", itemID: "it_4", author: .agent, body: table, createdAt: .init(timeIntervalSince1970: 1_770_000_100)),
        ]
        let model = ItemDetailView.Model(item: item, comments: comments, pending: [], availableResolutions: [.answered], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Date(timeIntervalSince1970: 1_770_000_600))
            .frame(width: 720, height: 980)
        assertVariants(of: view, named: "ItemDetail_codeAndTable")
    }

    /// The context block under the `#N · Kind` line: the
    /// item's mission and the conversation that owns it, each a caption
    /// line that opens its page, a long label truncating.
    func testHeaderShowsTheMissionAndItsOwner() {
        let item = TrackerItem(id: "it_5", num: 10_563, kind: .task, title: "Show which conversation a task belongs to",
                               body: "The item detail header shows only the number and the state.",
                               originConvoID: "c-origin", createdBy: .agent,
                               createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000),
                               missionID: "m1", missionNum: 57)
        let context = ItemContext(
            mission: .init(num: 57, label: "#57 Item detail shows its mission and conversations"),
            owner: .init(id: "c-origin", label: "lab-mac \u{00B7} [cq] Coordinator: the conversation that filed this task and still owns it"))
        let model = ItemDetailView.Model(item: item, comments: [], pending: [], context: context,
                                         availableResolutions: [.done], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Date(timeIntervalSince1970: 1_770_000_600), onOpenMission: { _ in })
            .frame(width: 380, height: 360)
        assertVariants(of: view, named: "ItemDetail_context")
    }

    /// The same block on the Mac Decisions page, where the thread runs up
    /// under the clear title bar: a mission this device has not loaded
    /// reads by number, and an owner it has no row or title for still
    /// shows, as "Conversation" — a step lighter and not a button, since
    /// there is no chat here to open.
    func testHeaderContextFallbacksUnderTheTitleBar() {
        let item = TrackerItem(id: "it_6", num: 10_563, kind: .question, awaiting: .user, title: "Which box should run the web half?",
                               originConvoID: "c-origin", createdBy: .agent,
                               createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000),
                               missionID: "m1", missionNum: 57)
        let context = ItemContext(mission: .init(num: 57, label: "Mission #57"),
                                  owner: .init(id: "c-origin", label: ItemContext.unnamedConversation, isOpenable: false))
        let model = ItemDetailView.Model(item: item, comments: [], pending: [], context: context,
                                         availableResolutions: [.answered], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                  now: Date(timeIntervalSince1970: 1_770_000_600), onOpenMission: { _ in })
            .environment(\.itemDetailFillsTitleBar, true)
            .frame(width: 520, height: 300)
        assertVariants(of: view, named: "ItemDetail_contextFallbacks")
    }
}
