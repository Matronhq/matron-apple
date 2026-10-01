#if os(macOS)
import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

/// The Mac item thread builds a card's text view only once the card comes
/// near the screen (mission 6040, `SelectableMessageText.defersTextView`).
/// Building every card's NSTextView up front made a long thread slow to
/// open; a `LazyVStack` fixed the open but, under load, moved the thread by
/// hundreds of points while scrolling up from the tail. These pin the
/// bounded build, TextKit 1 for the cards that are built, and that cards
/// realised while scrolling never move the thread or change its height.
@MainActor
final class ItemDetailDeferredThreadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private static let commentCount = 80

    private func model() -> ItemDetailView.Model {
        let para = "A typical agent comment with **bold**, a [link](https://example.com) and `code`, long enough to wrap across several lines of the card."
        let item = TrackerItem(id: "it_lazy", num: 1, kind: .decision, awaiting: .user, title: "A long decision thread",
                               body: Array(repeating: para, count: 3).joined(separator: "\n\n"),
                               originConvoID: "c1", createdAt: t0, updatedAt: t0)
        var comments: [TrackerComment] = []
        for i in 0..<Self.commentCount {
            let parts: [String] = Array(repeating: para, count: 1 + i % 4)
            let author: ItemAuthor = i % 2 == 0 ? .user : .agent
            comments.append(TrackerComment(id: "c\(i)", itemID: "it_lazy", author: author,
                                           body: "Reply \(i). " + parts.joined(separator: "\n\n"),
                                           createdAt: t0.addingTimeInterval(Double(i + 1) * 60)))
        }
        return ItemDetailView.Model(item: item, comments: comments, pending: [], originTitle: nil,
                                    availableResolutions: [], isBusy: false, loadedCommentCount: comments.count)
    }

    private struct Harness: View {
        let model: ItemDetailView.Model
        let startsAtBottom: Bool
        var body: some View {
            ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                           onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                           onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                           startsAtBottom: startsAtBottom)
                .frame(width: 560, height: 800)
        }
    }

    private func mount(startsAtBottom: Bool) -> (NSHostingView<Harness>, NSWindow) {
        let host = NSHostingView(rootView: Harness(model: model(), startsAtBottom: startsAtBottom))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        spin()
        return (host, window)
    }

    private func spin(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

    private func textViews(in view: NSView) -> [MessageCopyTextView] {
        if let tv = view as? MessageCopyTextView { return [tv] }
        return view.subviews.flatMap(textViews(in:))
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    func testOpeningAtTheTopBuildsOnlyTheCardsOnScreen() {
        let (host, window) = mount(startsAtBottom: false)
        defer { window.orderOut(nil) }
        let ids = textViews(in: host).compactMap(\.selectionItemID)
        XCTAssertTrue(ids.contains(ItemDetailView.bodySelectionID(for: "it_lazy")), "the body card is on screen: \(ids)")
        XCTAssertLessThan(ids.count, 20, "an 80-comment thread must not build every card up front")
        XCTAssertFalse(ids.contains("c\(Self.commentCount - 1)"), "the last reply is far below the fold")
        for view in textViews(in: host) {
            XCTAssertNil(view.textLayoutManager, "a thread card lays out with TextKit 1, not TextKit 2's per-scroll viewport layout")
        }
    }

    func testOpeningAtTheBottomBuildsOnlyTheTail() {
        let (host, window) = mount(startsAtBottom: true)
        defer { window.orderOut(nil) }
        let ids = textViews(in: host).compactMap(\.selectionItemID)
        XCTAssertTrue(ids.contains("c\(Self.commentCount - 1)"), "the reader who left at the tail opens there: \(ids)")
        // The first frame draws at the top before the jump to the tail, so
        // the few cards up there may be built too — but not the middle.
        XCTAssertLessThan(ids.count, 20, "an 80-comment thread must not build every card up front")
        XCTAssertFalse(ids.contains("c40"), "the middle of the thread is off screen both ways")
    }

    /// Scrolls through the thread in fixed steps. A card on screen before
    /// and after a step must move by exactly the step — anything else is
    /// the thread jumping under the reader as cards are realised.
    private func assertScrollsWithoutJumping(startsAtBottom: Bool, step: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let (host, window) = mount(startsAtBottom: startsAtBottom)
        defer { window.orderOut(nil) }
        let scroll = try XCTUnwrap(scrollView(in: host))
        // Let the opening placement settle first: on a loaded machine the
        // jump to the tail can land after the mount's spin, and would read
        // as a scroll that went nowhere.
        var settled = scroll.contentView.bounds.origin.y
        for _ in 0..<20 {
            spin(0.1)
            if scroll.contentView.bounds.origin.y == settled { break }
            settled = scroll.contentView.bounds.origin.y
        }
        let delta = startsAtBottom ? -step : step
        func positions() -> [String: CGFloat] {
            Dictionary(textViews(in: host).compactMap { view in
                view.selectionItemID.map { ($0, view.convert(view.bounds, to: nil).minY) }
            }, uniquingKeysWith: { first, _ in first })
        }
        let height = try XCTUnwrap(scroll.documentView).frame.height
        var realised = Set<String>()
        for index in 0..<60 {
            let before = positions()
            var origin = scroll.contentView.bounds.origin
            let maxY = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
            guard startsAtBottom ? origin.y > step : origin.y + step < maxY else { break }
            origin.y += delta
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            spin(0.05)
            host.layoutSubtreeIfNeeded()
            let after = positions()
            realised.formUnion(after.keys)
            for (id, y) in before {
                guard let moved = after[id].map({ $0 - y }) else { continue }
                XCTAssertEqual(abs(moved), step, accuracy: 1, "step \(index): \(id) moved \(moved) pt for a \(step)-pt scroll",
                               file: file, line: line)
            }
        }
        XCTAssertGreaterThan(realised.count, 15, "the scroll should have walked well through the thread", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.height, height, accuracy: 0.5,
                       "building a card's text view must not change the thread's height", file: file, line: line)
    }

    func testScrollingUpFromTheBottomNeverJumps() throws {
        try assertScrollsWithoutJumping(startsAtBottom: true, step: 250)
    }

    func testScrollingUpInLargeStepsNeverJumps() throws {
        try assertScrollsWithoutJumping(startsAtBottom: true, step: 700)
    }

    func testScrollingDownFromTheTopNeverJumps() throws {
        try assertScrollsWithoutJumping(startsAtBottom: false, step: 250)
    }
}
#endif
