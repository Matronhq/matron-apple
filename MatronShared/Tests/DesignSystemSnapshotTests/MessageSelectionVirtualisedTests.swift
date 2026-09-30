#if os(macOS)
import XCTest
import AppKit
@testable import MatronDesignSystem

@MainActor final class MessageSelectionVirtualisedTests: XCTestCase {
    final class Target: CrossSelectionTarget {
        let selectionItemID: String?
        let storageLength: Int
        var frameInWindow: NSRect
        var range: NSRange?
        init(_ id: String, length: Int, y: CGFloat) { selectionItemID = id; storageLength = length; frameInWindow = NSRect(x: 0, y: y, width: 100, height: 20) }
        func characterIndex(atWindowPoint point: NSPoint) -> Int { 2 }
        func setCrossSelection(_ range: NSRange?) { self.range = range }
        func crossSelectionMarkdown() -> String { "live-\(selectionItemID!)" }
    }

    private func controller() -> MessageSelectionController {
        let c = MessageSelectionController()
        c.orderedIDs = ["a", "b", "c", "d"]
        c.contentProvider = { id in (NSAttributedString(string: "text-\(id)"), "src-\(id)") }
        return c
    }

    func test_unmountedMiddleRowsCopyFromProvider() {
        let c = controller()
        let a = Target("a", length: 6, y: 100), d = Target("d", length: 6, y: 0)
        c.register(a); c.register(d)
        XCTAssertTrue(c.beginCrossMessage(anchorID: "a", charIndex: 2))
        c.hitTester = { _, _ in d }
        c.extend(toWindowPoint: .zero, window: nil)
        let spans = c.selectedSpans()
        XCTAssertEqual(spans.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(spans[1].text, "src-b")          // full span of an unmounted row = verbatim source
        XCTAssertEqual(spans[2].text, "src-c")
        XCTAssertEqual(spans[0].text, "live-a")
    }

    func test_registeringMidSelectionReceivesItsSpan() {
        let c = controller()
        let a = Target("a", length: 6, y: 100), d = Target("d", length: 6, y: 0)
        c.register(a); c.register(d)
        c.beginCrossMessage(anchorID: "a", charIndex: 2)
        c.hitTester = { _, _ in d }
        c.extend(toWindowPoint: .zero, window: nil)
        let b = Target("b", length: 9, y: 60)
        c.register(b)                                    // scrolled into view by autoscroll
        XCTAssertEqual(b.range, NSRange(location: 0, length: 9))
    }

    /// Review gap 7f: the ANCHOR row scrolls out mid-selection and back in
    /// (a new view registers for it): it gets its PARTIAL range — press
    /// point to end when dragging down — not the full row.
    func test_reregisteredAnchorRowReceivesItsPartialSpan() {
        let c = controller()
        let a = Target("a", length: 6, y: 100), d = Target("d", length: 6, y: 0)
        c.register(a); c.register(d)
        XCTAssertTrue(c.beginCrossMessage(anchorID: "a", charIndex: 2))
        c.hitTester = { _, _ in d }
        c.extend(toWindowPoint: .zero, window: nil)
        XCTAssertEqual(a.range, NSRange(location: 2, length: 4))
        c.unregister(a)                                  // anchor scrolled away
        let remounted = Target("a", length: 6, y: 100)
        c.register(remounted)                            // …and back, in a recycled view
        XCTAssertEqual(remounted.range, NSRange(location: 2, length: 4))
        XCTAssertEqual(c.selectedSpans().first?.text, "live-a")
    }

    func test_partialSpanOfUnmountedEndReconstructsMarkdown() {
        let c = controller()
        let d = Target("d", length: 6, y: 0)
        c.register(d)
        c.beginCrossMessage(anchorID: "d", charIndex: 3)
        let a = Target("a", length: 6, y: 100)
        c.register(a)
        c.hitTester = { _, _ in a }
        c.extend(toWindowPoint: .zero, window: nil)
        c.unregister(d)                                  // anchor scrolled away
        XCTAssertEqual(c.selectedSpans().last?.text, "tex")   // anchor at 3, dragging up → partial (0,3) of the unmounted anchor, reconstructed from the provider's attributed string
    }
}
#endif
