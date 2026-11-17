#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import MatronMac

@MainActor
final class MacItemCellsTests: XCTestCase {
    private let model = MacItemThreadFixtures.model(comments: 2)

    private var factory: MacItemPieceFactory {
        MacItemPieceFactory(detail: MacItemPiecesTests.detail(model), environment: MacItemThreadEnvironment(),
                            selection: MessageSelectionController())
    }

    private func layout(_ parts: [ItemCardContent.Part]) -> MacItemCardLayout {
        let card = ItemCardContent(row: .comment("c1"), mine: false, parts: parts, hasDelivery: false,
                                   hasActions: false, hostedSignature: 0)
        let sizer = MacItemPieceSizer()
        return MacItemCardGeometry.layout(card, textSelectionIDs: ["c1", "c1#seg1"], rowWidth: 600) { piece, width in
            sizer.size(of: self.factory.view(piece), maxWidth: width)
        }
    }

    private func host(_ view: NSView, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        // Under ARC: `close()` must not release it a second time.
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    func test_cardCell_placesEveryPartAtItsFrame() {
        let layout = layout([.markdown("First part"), .attachment(MacItemThreadFixtures.image("b1")), .markdown("Second")])
        let cell = MacItemCardCell(frame: .zero)
        let window = host(cell, height: layout.height)
        defer { window.close() }
        cell.configure(rowID: "comment:c1", layout: layout, copyText: "First part\n\nSecond", mine: false, dimmed: false, factory: factory,
                       selection: MessageSelectionController(), routing: MacTimelineLinkRouting())
        cell.layoutSubtreeIfNeeded()
        let bodies = cell.visibleBodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.map(\.frame), [layout.frames[1], layout.frames[3]])
        XCTAssertEqual(bodies.map(\.itemID), ["c1", "c1#seg1"])
        XCTAssertEqual(cell.visibleHostFrames, [layout.frames[0], layout.frames[2]])
        XCTAssertEqual(cell.groundFrame, layout.cardFrame)
    }

    func test_cardCell_reconfiguredWithFewerParts_hidesTheRest() {
        let cell = MacItemCardCell(frame: .zero)
        let two = layout([.markdown("First part"), .attachment(MacItemThreadFixtures.image("b1")), .markdown("Second")])
        let window = host(cell, height: two.height)
        defer { window.close() }
        let selection = MessageSelectionController()
        cell.configure(rowID: "comment:c1", layout: two, copyText: "First part\n\nSecond", mine: false, dimmed: false, factory: factory,
                       selection: selection, routing: MacTimelineLinkRouting())
        let one = layout([.markdown("Only")])
        cell.configure(rowID: "comment:c1", layout: one, copyText: "Only", mine: true, dimmed: false, factory: factory,
                       selection: selection, routing: MacTimelineLinkRouting())
        XCTAssertEqual(cell.visibleBodies.count, 1)
        XCTAssertEqual(cell.visibleHostFrames.count, 1)
    }

    private func rightClick(_ cell: MacItemCardCell, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: cell.convert(point, to: nil),
                                        modifierFlags: [], timestamp: 0, windowNumber: cell.window!.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func test_cardGroundMenuCopiesWholeMarkdown_andClearsOnReuse() throws {
        let source = "**First** with [link](https://example.com).\n\n```swift\nlet x = 1\n```"
        let attachment = MacItemThreadFixtures.image("b1")
        let content = ItemCardContent(row: .comment("c1"), mine: false,
                                      parts: [.markdown("  " + source + "\n"), .attachment(attachment), .markdown(" Second. ")],
                                      hasDelivery: false, hasActions: false, hostedSignature: 0)
        let layout = layout(content.parts)
        let cell = MacItemCardCell(frame: .zero)
        let window = host(cell, height: layout.height)
        defer { window.close() }
        cell.configure(rowID: "comment:c1", layout: layout, copyText: content.copyText, mine: false, dimmed: false,
                       factory: factory, selection: MessageSelectionController(), routing: MacTimelineLinkRouting())
        let groundPoint = NSPoint(x: layout.cardFrame.minX + 2, y: layout.cardFrame.midY)
        let event = try rightClick(cell, at: groundPoint)
        let menu = try XCTUnwrap(cell.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["Copy"])
        let copy = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(copy.isEnabled)
        let action = try XCTUnwrap(copy.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: copy.target, from: copy))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), source + "\n\nSecond.")

        // A fallback from a text/code/table or hosted piece must not offer the card menu.
        for frame in layout.frames {
            XCTAssertNil(cell.menu(for: try rightClick(cell, at: NSPoint(x: frame.midX, y: frame.midY))))
        }
        XCTAssertNil(cell.menu(for: try rightClick(cell, at: NSPoint(x: layout.cardFrame.minX - 2, y: groundPoint.y))))
        cell.prepareForReuse()
        XCTAssertNil(cell.menu(for: event))

        let picturesOnly = ItemCardContent(row: .comment("c2"), mine: false, parts: [.attachment(attachment)],
                                           hasDelivery: false, hasActions: false, hostedSignature: 0)
        let pictureLayout = self.layout(picturesOnly.parts)
        cell.configure(rowID: "comment:c2", layout: pictureLayout, copyText: picturesOnly.copyText,
                       mine: false, dimmed: false, factory: factory,
                       selection: MessageSelectionController(), routing: MacTimelineLinkRouting())
        let pictureGround = NSPoint(x: pictureLayout.cardFrame.minX + 2, y: pictureLayout.cardFrame.midY)
        XCTAssertNil(cell.menu(for: try rightClick(cell, at: pictureGround)))
    }

    func test_hostedCell_reportsAHeightOtherThanExpected() {
        let cell = MacItemHostedCell(frame: .zero)
        let window = host(cell, height: 100)
        defer { window.close() }
        let reported = expectation(description: "height report")
        cell.onHeightChange = { id, height in
            XCTAssertEqual(id, "divider")
            XCTAssertEqual(height, 37, accuracy: 0.5)
            reported.fulfill()
        }
        cell.configure(rowID: "divider", expectedHeight: 100, view: AnyView(Color.red.frame(height: 37)))
        cell.layoutSubtreeIfNeeded()
        wait(for: [reported], timeout: 2)
    }
}
#endif
