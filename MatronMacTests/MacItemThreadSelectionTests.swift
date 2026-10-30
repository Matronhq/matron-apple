#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import MatronMac

/// The cross-card selection over the native item thread, through the real
/// controller in a window, and the SwiftUI face that hosts it.
@MainActor
final class MacItemThreadSelectionTests: XCTestCase {
    private var window: NSWindow!
    private let selection = MessageSelectionController()

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func detail(_ model: ItemDetailView.Model) -> ItemDetailView {
        ItemDetailView(model: model, draft: ItemReplyDraft(get: { "" }, set: { _ in }), image: { _ in nil },
                       onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                       onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {})
    }

    private func factory(_ model: ItemDetailView.Model) -> MacItemPieceFactory {
        MacItemPieceFactory(detail: detail(model), environment: MacItemThreadEnvironment(), selection: selection)
    }

    private func makeWindow(width: CGFloat = 600, height: CGFloat = 500) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func mount(_ model: ItemDetailView.Model) -> MacItemThreadController {
        let controller = MacItemThreadController(factory: factory(model))
        window = makeWindow()
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 500))
        window.orderFront(nil)
        settle()
        return controller
    }

    private func settle(_ seconds: TimeInterval = 0.05) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds / 4))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
    }

    /// From the body's first character to the middle of comment 30, with
    /// the body and most comments between scrolled off and unmounted: the
    /// copy is the SwiftUI thread's transcript of those spans, every card
    /// between included.
    func test_dragAcrossUnmountedCardsCopiesTranscript() throws {
        let model = MacItemThreadFixtures.model(comments: 40)
        let c = mount(model)
        let bodyID = ItemDetailView.bodySelectionID(for: model.item.id)
        XCTAssertTrue(selection.beginCrossMessage(anchorID: bodyID, charIndex: 0))

        let index = try XCTUnwrap(c.rowIndex(of: "comment:c30"))
        // Cards measured as they mount on the way move comment 30 down, so
        // scroll again until its row stays put: a point taken from a row
        // still moving lands on the card above it.
        var rowTop: CGFloat = -1
        for _ in 0..<6 where c.tableView.rect(ofRow: index).minY != rowTop {
            rowTop = c.tableView.rect(ofRow: index).minY
            c.scrollView.contentView.scroll(to: NSPoint(x: 0, y: rowTop))
            c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
            settle()
        }
        c.tableView.layoutSubtreeIfNeeded()
        // Cards scrolled in can show for a moment with zero-sized bodies,
        // until the thread measures them. A point taken then misses every
        // view and goes to the nearest target, which on a slow runner was
        // comment 29.
        func card() -> MacItemCardCell? {
            c.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacItemCardCell
        }
        let deadline = Date().addingTimeInterval(2)
        while (card()?.visibleBodies.first?.bounds.height ?? 0) == 0, Date() < deadline { settle() }
        let cell = try XCTUnwrap(card())
        let body = try XCTUnwrap(cell.visibleBodies.first)
        XCTAssertGreaterThan(body.bounds.height, 0, "comment 30's body was never laid out")
        let frame = body.convert(body.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        // What the drag lands on, for a failure to say why.
        let hit = selection.hitTester(point, window)
        let others = c.tableView.subviews.compactMap { rowView -> String? in
            guard let card = (rowView as? NSTableRowView)?.view(atColumn: 0) as? MacItemCardCell else { return nil }
            let ids = card.visibleBodies.map { "\($0.itemID ?? "nil")@\($0.convert($0.bounds, to: nil))" }
            return "\(card.rowID): \(ids)"
        }
        let landing = "body \(body.itemID ?? "nil") in cell \(cell.rowID), point \(point), "
            + "hit \(hit?.selectionItemID ?? "nil"), window \(window.contentView?.bounds ?? .zero), cards \(others)"
        selection.extend(toWindowPoint: point, window: window)
        selection.finish()

        let spans = selection.selectedSpans()
        XCTAssertEqual(spans.first?.id, bodyID)
        XCTAssertEqual(spans.last?.id, "c30", landing)
        // The body and comments 0–29 are off screen: whole, from their source.
        XCTAssertEqual(spans.first?.text, model.item.body)
        XCTAssertEqual(spans.first(where: { $0.id == "c1" })?.text, model.comments[1].body)
        XCTAssertFalse(try XCTUnwrap(spans.last?.text).isEmpty)

        let copied = try XCTUnwrap(selection.transcriptProvider?())
        let expected = ItemDetailView.transcript(item: model.item, comments: model.comments, spans: spans)
        XCTAssertEqual(copied.text, expected.text)
        XCTAssertEqual(copied.messageCount, 32)
        for i in 1...29 { XCTAssertTrue(copied.text.contains("Comment \(i). "), "comment \(i) missing") }
    }

    func test_selectionOrderFollowsModel() {
        let c = mount(MacItemThreadFixtures.model(comments: 3))
        XCTAssertEqual(selection.orderedIDs, ["body:it_fx", "c0", "c1", "c2"])
        c.update(factory: factory(MacItemThreadFixtures.model(comments: 4)))
        settle()
        XCTAssertEqual(selection.orderedIDs, ["body:it_fx", "c0", "c1", "c2", "c3"])
    }

    /// The face: the table under the pinned resolve control, the composer
    /// under a divider, and the thread's selection cleared when it goes.
    func test_nativeThreadHostsTheTableAndComposer() throws {
        let host = NSHostingView(rootView: MacItemNativeThread(detail: detail(MacItemThreadFixtures.model(comments: 5))))
        window = makeWindow()
        window.contentView = host
        window.orderFront(nil)
        settle(0.2)
        let table = try XCTUnwrap(Self.find(in: host) { $0.accessibilityIdentifier() == "item.thread" })
        XCTAssertGreaterThan(table.frame.height, 0)
        // The composer: a text input below the table, outside it.
        let tableBottom = table.convert(table.visibleRect, to: nil).minY
        let input = Self.find(in: host) { view in
            (view is NSTextView || view is NSTextField) && !view.isDescendant(of: table)
                && view.convert(view.bounds, to: nil).maxY <= tableBottom + 1
        }
        XCTAssertNotNil(input, "the reply composer is drawn under the thread")
    }

    private static func find(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for sub in view.subviews { if let hit = find(in: sub, where: match) { return hit } }
        return nil
    }
}
#endif
