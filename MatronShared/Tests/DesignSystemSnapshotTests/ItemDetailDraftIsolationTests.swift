#if os(macOS) && DEBUG
import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Typing in an item's reply must not rebuild the thread.
/// The draft used to be a `@Binding` on `ItemDetailView`, so every
/// keystroke re-ran its body and rebuilt every comment row: 17–21 ms a
/// keystroke on a 113-comment thread on the Mac, ~39 ms on iPhone. These
/// pin that a keystroke builds no comment row, and that the reply field
/// still shows every change to the draft — typed or set by the host
/// (cleared after Send, a transcript appended).
@MainActor
final class ItemDetailDraftIsolationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    @Observable final class Draft {
        var text = ""
    }

    /// What the reply field rendered, newest last, and the binding it was
    /// handed — the one a keystroke writes through.
    final class FieldLog {
        var shown: [String] = []
        var binding: Binding<String>?
    }

    private struct ProbeField: View {
        let draft: Binding<String>
        let log: FieldLog
        var body: some View {
            let value = draft.wrappedValue
            let _ = log.shown.append(value)
            let _ = log.binding = draft
            Text(value.isEmpty ? " " : value)
        }
    }

    private struct Harness: View {
        let model: ItemDetailView.Model
        let draft: Draft
        let log: FieldLog
        var body: some View {
            ItemDetailView(model: model, draft: ItemReplyDraft(get: { draft.text }, set: { draft.text = $0 }),
                           image: { _ in nil }, onOpenAttachment: { _ in }, onOpenLink: { _ in },
                           onOpenConversation: { _ in }, onSubmit: {}, onAttach: {}, onVoiceNote: {},
                           onClose: { _ in }, onReopen: {}, now: Date(timeIntervalSince1970: 1_770_010_000))
                .environment(\.itemCommentField, ItemCommentFieldFactory { field in
                    AnyView(ProbeField(draft: field.draft, log: log))
                })
                .frame(width: 560, height: 800)
        }
    }

    private func model(comments count: Int) -> ItemDetailView.Model {
        let item = TrackerItem(id: "it_draft", num: 1, kind: .task, title: "A long thread", body: "The item body.",
                               originConvoID: "c1", createdAt: t0, updatedAt: t0)
        var comments: [TrackerComment] = []
        for i in 0..<count {
            let author: ItemAuthor = i % 2 == 0 ? .user : .agent
            let body = "Comment \(i) with **bold** and a [link](https://example.com)."
            let at = t0.addingTimeInterval(Double(i + 1) * 60)
            comments.append(TrackerComment(id: "c\(i)", itemID: "it_draft", author: author, body: body, createdAt: at))
        }
        return .init(item: item, comments: comments, pending: [], availableResolutions: [.done],
                     isBusy: false, loadedCommentCount: comments.count)
    }

    private func spin(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func mount(_ harness: Harness) -> NSWindow {
        let host = NSHostingView(rootView: harness)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        spin(0.5)
        return window
    }

    func test_typingInTheReply_buildsNoCommentRow() {
        let draft = Draft(), log = FieldLog()
        let window = mount(Harness(model: model(comments: 40), draft: draft, log: log))
        defer { window.close() }
        XCTAssertGreaterThan(ItemDetailViewProbe.commentRowBuilds, 0, "the thread's rows were built at open")

        ItemDetailViewProbe.commentRowBuilds = 0
        // Type as the field does: through the binding the composer gave it.
        for ch in "hello" {
            guard let field = log.binding else { return XCTFail("the reply field was never built") }
            field.wrappedValue.append(ch)
            spin(0.05)
        }
        spin()
        XCTAssertEqual(ItemDetailViewProbe.commentRowBuilds, 0, "a keystroke rebuilt the thread")
        XCTAssertEqual(draft.text, "hello", "the field's edits reach the host's draft")
        XCTAssertEqual(log.shown.last, "hello", "the reply field shows what was typed")
    }

    func test_theHostChangingTheDraft_reachesTheReplyField() {
        let draft = Draft(), log = FieldLog()
        let window = mount(Harness(model: model(comments: 5), draft: draft, log: log))
        defer { window.close() }

        draft.text = "a transcript"
        spin()
        XCTAssertEqual(log.shown.last, "a transcript")
        // Send clears the draft from the view model, not from the field.
        draft.text = ""
        spin()
        XCTAssertEqual(log.shown.last, "")
    }

    func test_aNewComment_stillRebuildsTheThread() {
        let draft = Draft(), log = FieldLog()
        let short = model(comments: 3)
        let host = NSHostingView(rootView: Harness(model: short, draft: draft, log: log))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        spin(0.5)

        ItemDetailViewProbe.commentRowBuilds = 0
        host.rootView = Harness(model: model(comments: 4), draft: draft, log: log)
        spin()
        XCTAssertGreaterThan(ItemDetailViewProbe.commentRowBuilds, 0, "the thread follows its model")
    }
}
#endif
