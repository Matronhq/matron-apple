#if os(macOS)
import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// The Mac item thread's selection WIRING (tracker #2533, reviewer PR
/// #232): the pure helpers say which cards take part; this mounts the real
/// view and checks that the cards register with the thread's own
/// controller — not an outer chat timeline's — that the row order follows
/// the model, and that an in-place item swap (the Mac hosts reuse one
/// `ItemDetailView` identity) drops a finished selection.
@MainActor
final class ItemDetailSelectionWiringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func model(itemID: String, commentIDs: [String]) -> ItemDetailView.Model {
        let item = TrackerItem(id: itemID, num: 1, kind: .question, awaiting: .agent, title: "Which?",
                               body: "The original post, long enough to wrap onto a second line in the card.",
                               originConvoID: "c1", createdAt: t0, updatedAt: t0)
        let comments = commentIDs.enumerated().map { index, id in
            TrackerComment(id: id, itemID: itemID, author: index % 2 == 0 ? .user : .agent,
                           body: "Reply \(id) with a few words.", createdAt: t0.addingTimeInterval(Double(index + 1) * 60))
        }
        return ItemDetailView.Model(item: item, comments: comments, pending: [], originTitle: nil,
                                    availableResolutions: [], isBusy: false)
    }

    /// One stable root type so `rootView` reassignment is an in-place model
    /// swap under the SAME `ItemDetailView` identity, as `MacItemDetailHost`
    /// does when the pane shows another item.
    private struct Harness: View {
        let model: ItemDetailView.Model
        let outer: MessageSelectionController
        var body: some View {
            ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                           onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                           onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {})
                .environment(outer)
                .frame(width: 420, height: 640)
        }
    }

    private func textViews(in view: NSView) -> [MessageCopyTextView] {
        if let tv = view as? MessageCopyTextView { return [tv] }
        return view.subviews.flatMap(textViews(in:))
    }

    private func spin() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) }

    func testCardsRegisterWithTheThreadControllerAndASwapClearsTheSelection() throws {
        let outer = MessageSelectionController()
        let host = NSHostingView(rootView: Harness(model: model(itemID: "it_A", commentIDs: ["c1", "c2"]), outer: outer))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        spin()

        let views = textViews(in: host)
        XCTAssertEqual(views.count, 3, "body card + two comments should each be a text view")
        let inner = try XCTUnwrap(views.first?.selectionController, "a card is not wired to any controller")
        XCTAssertFalse(inner === outer, "cards must use the thread's controller, not the outer chat's")
        for view in views { XCTAssertTrue(view.selectionController === inner, "every card shares one controller") }
        XCTAssertEqual(inner.orderedIDs, [ItemDetailView.bodySelectionID(for: "it_A"), "c1", "c2"])
        XCTAssertEqual(Set(views.compactMap(\.selectionItemID)), Set(inner.orderedIDs))

        // The outer controller never learns about item cards.
        XCTAssertFalse(outer.beginCrossMessage(anchorID: "c1", charIndex: 0))
        XCTAssertEqual(outer.selectedSpans(), [])

        // A finished selection across two cards, with a transcript from the
        // provider the view installed.
        XCTAssertTrue(inner.beginCrossMessage(anchorID: ItemDetailView.bodySelectionID(for: "it_A"), charIndex: 0))
        let second = try XCTUnwrap(views.first { $0.selectionItemID == "c1" })
        let inside = second.frameInWindow
        inner.extend(toWindowPoint: NSPoint(x: inside.midX, y: inside.midY), window: window)
        inner.finish()
        XCTAssertTrue(inner.hasSelection)
        let transcript = try XCTUnwrap(inner.finishedTranscript)
        XCTAssertEqual(transcript.messageCount, 2, transcript.text)
        XCTAssertTrue(transcript.text.contains("Agent: The original post"), transcript.text)

        // Swap the item in place: the row order follows, and the stale
        // selection (its ids are gone) is dropped rather than stranded.
        host.rootView = Harness(model: model(itemID: "it_B", commentIDs: ["d1"]), outer: outer)
        spin()
        XCTAssertFalse(inner.hasSelection, "a selection from item A must not survive item B")
        XCTAssertEqual(inner.orderedIDs, [ItemDetailView.bodySelectionID(for: "it_B"), "d1"])
        XCTAssertEqual(Set(textViews(in: host).compactMap(\.selectionItemID)), Set(inner.orderedIDs))
        inner.clear()
    }
}
#endif
