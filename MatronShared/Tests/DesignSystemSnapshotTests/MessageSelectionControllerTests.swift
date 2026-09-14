#if os(macOS)
import AppKit
import XCTest
@testable import MatronDesignSystem

/// Span math and registry behaviour of the cross-message selection
/// controller, driven with fake targets (no windows, no AppKit text views).
@MainActor
final class MessageSelectionControllerTests: XCTestCase {

    /// A stand-in message body: `length` characters laid out as one line
    /// per 10 characters inside `frame` (window coords, y-up), so a window
    /// point maps to a character index deterministically.
    final class FakeTarget: CrossSelectionTarget {
        let selectionItemID: String?
        let storageLength: Int
        let frameInWindow: NSRect
        var applied: [NSRange?] = []
        var current: NSRange?
        var markdown: (NSRange) -> String = { r in "chars \(r.location)..<\(r.location + r.length)" }

        init(id: String, length: Int, frame: NSRect) {
            selectionItemID = id
            storageLength = length
            frameInWindow = frame
        }

        func characterIndex(atWindowPoint point: NSPoint) -> Int {
            // Above the frame (y-up: y > maxY) → 0; below → length; inside →
            // proportional to the distance from the top edge.
            if point.y >= frameInWindow.maxY { return 0 }
            if point.y <= frameInWindow.minY { return storageLength }
            let fraction = (frameInWindow.maxY - point.y) / frameInWindow.height
            return min(storageLength, max(0, Int((fraction * CGFloat(storageLength)).rounded(.down))))
        }

        func setCrossSelection(_ range: NSRange?) {
            applied.append(range)
            current = range
        }

        func crossSelectionMarkdown() -> String {
            guard let current, current.length > 0 else { return "" }
            return markdown(current)
        }
    }

    private var controller: MessageSelectionController!
    // Rows stacked top→bottom in a 400pt-tall window: A (y 300–360),
    // B (200–240), C (100–160). Gap between them is card/padding space.
    private var a: FakeTarget!
    private var b: FakeTarget!
    private var c: FakeTarget!

    override func setUp() {
        super.setUp()
        controller = MessageSelectionController()
        controller.hitTester = { _, _ in nil }   // force the nearest-row fallback
        a = FakeTarget(id: "a", length: 60, frame: NSRect(x: 0, y: 300, width: 300, height: 60))
        b = FakeTarget(id: "b", length: 40, frame: NSRect(x: 0, y: 200, width: 300, height: 40))
        c = FakeTarget(id: "c", length: 60, frame: NSRect(x: 0, y: 100, width: 300, height: 60))
        controller.orderedIDs = ["a", "b", "c"]
        // Register out of row order on purpose — order must come from `orderedIDs`.
        controller.register(c)
        controller.register(a)
        controller.register(b)
    }

    func test_noSelection_initially() {
        XCTAssertFalse(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, [])
        XCTAssertEqual(controller.selectedSpans(), [])
    }

    func test_dragDown_anchorToEnd_middlesFull_headFromStart() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 10)
        // Pointer halfway down C → index 30 of 60.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertTrue(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, ["a", "b", "c"])
        XCTAssertEqual(a.current, NSRange(location: 10, length: 50))
        XCTAssertEqual(b.current, NSRange(location: 0, length: 40))
        XCTAssertEqual(c.current, NSRange(location: 0, length: 30))
    }

    func test_dragUp_anchorFromStart_headToEnd() {
        controller.beginCrossMessage(anchorID: "c", charIndex: 20)
        // Pointer inside A, a quarter of the way down → index 15.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 345), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b", "c"])
        XCTAssertEqual(a.current, NSRange(location: 15, length: 45))
        XCTAssertEqual(b.current, NSRange(location: 0, length: 40))
        XCTAssertEqual(c.current, NSRange(location: 0, length: 20))
    }

    func test_headEqualsAnchor_collapsesToWithinMessageRange() {
        controller.beginCrossMessage(anchorID: "b", charIndex: 30)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 230), window: nil) // index 10 of B
        XCTAssertEqual(controller.selectedIDs, ["b"])
        XCTAssertEqual(b.current, NSRange(location: 10, length: 20))
        XCTAssertNil(a.current)
        XCTAssertNil(c.current)
    }

    func test_sameRowSpan_clampsToStorageLength() {
        // Anchor charIndex (999) is far beyond B's storageLength (40).
        controller.beginCrossMessage(anchorID: "b", charIndex: 999)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 230), window: nil) // index 10 of B
        XCTAssertEqual(controller.selectedIDs, ["b"])
        XCTAssertEqual(b.current, NSRange(location: 10, length: 30))
    }

    func test_pointerInGapAboveHead_givesZeroLengthHeadSpan() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        // y = 250 is between A (minY 300) and B (maxY 240); nearer B by 10 vs 50.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 250), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b"])
        XCTAssertEqual(b.current, NSRange(location: 0, length: 0))
        XCTAssertEqual(controller.selectedSpans(), [
            SelectedSpan(id: "a", text: "chars 0..<60"),
            SelectedSpan(id: "b", text: ""),
        ])
    }

    func test_pointerBelowEverything_selectsThroughLastRowFully() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 5)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 10), window: nil)
        XCTAssertEqual(c.current, NSRange(location: 0, length: 60))
    }

    func test_directHitWins_overNearest() {
        controller.hitTester = { [b] _, _ in b }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        // Geometrically nearest is C, but the hit test says B.
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b"])
        XCTAssertNil(c.current)
    }

    /// The default hit-tester walks the window, so with two timelines side by
    /// side it can return the OTHER timeline's text view. A direct hit that
    /// this controller has not registered must be ignored, not trusted — the
    /// unvalidated version froze the drag (its id is absent from `orderedIDs`,
    /// so `extend` returned without moving the head).
    func test_directHitNotRegisteredHere_fallsBackToNearestRegistered() {
        let foreign = FakeTarget(id: "other-timeline", length: 40,
                                 frame: NSRect(x: 0, y: 200, width: 300, height: 40))
        controller.hitTester = { _, _ in foreign }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b", "c"],
                       "the nearest REGISTERED row must win over a foreign direct hit")
        XCTAssertNil(foreign.current, "a foreign target must never be painted")
    }

    /// Same rule for a hit on a target registered under an id this controller
    /// knows but that is a DIFFERENT object (a recycled body view mid-swap).
    func test_directHitWithKnownID_butForeignObject_fallsBackToNearest() {
        let impostor = FakeTarget(id: "b", length: 40, frame: NSRect(x: 0, y: 200, width: 300, height: 40))
        controller.hitTester = { _, _ in impostor }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "b", "c"])
        XCTAssertNil(impostor.current)
        XCTAssertEqual(c.current, NSRange(location: 0, length: 30))
    }

    /// A FINISHED selection outlives the drag, so the row window can move
    /// under it — most commonly the `eph:` streaming placeholder being
    /// replaced by its durable row. Without revalidation `hasSelection`
    /// stayed true over an empty `selectedIDs`: highlights lingered and ⌘C /
    /// "Copy N Messages" silently copied nothing.
    func test_finishedSelection_isDropped_whenAnEndpointLeavesRowOrder() {
        controller.transcriptProvider = { SelectionTranscript(text: "x", messageCount: 3) }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        controller.finish()
        XCTAssertTrue(controller.hasSelection)
        XCTAssertNotNil(controller.finishedTranscript)

        controller.orderedIDs = ["b", "c"]
        XCTAssertFalse(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, [])
        XCTAssertNil(a.current); XCTAssertNil(b.current); XCTAssertNil(c.current)
        XCTAssertNil(controller.finishedTranscript, "the menu must not offer a dead snapshot")
    }

    func test_reassigningRowOrder_keepsSelection_whenBothEndsSurvive() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)  // a…b
        controller.finish()
        controller.orderedIDs = ["a", "b", "c", "d"]
        XCTAssertTrue(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, ["a", "b"])
    }

    func test_extendingShrinksPreviouslySelectedRows() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)  // through C
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)  // back to B
        XCTAssertEqual(controller.selectedIDs, ["a", "b"])
        XCTAssertNil(c.current, "a row that left the range must have its highlight cleared")
    }

    func test_endLeavingRowOrder_dropsSelection_andClearsEveryHighlight() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)  // a…c, all three lit
        // The timeline's row window moves and drops the anchor row.
        controller.orderedIDs = ["b", "c"]
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertFalse(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, [])
        XCTAssertNil(a.current); XCTAssertNil(b.current); XCTAssertNil(c.current)
    }

    func test_idsWithoutTarget_areInSelectedIDs_butSpanTextIsNil() {
        controller.orderedIDs = ["a", "card", "b", "c"]
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)
        XCTAssertEqual(controller.selectedIDs, ["a", "card", "b"])
        XCTAssertEqual(controller.selectedSpans().map(\.id), ["a", "card", "b"])
        XCTAssertNil(controller.selectedSpans()[1].text)
    }

    func test_clear_zeroesEveryTarget_andHasSelectionFalse() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        controller.clear()
        XCTAssertFalse(controller.hasSelection)
        XCTAssertEqual(controller.selectedIDs, [])
        XCTAssertNil(a.current); XCTAssertNil(b.current); XCTAssertNil(c.current)
    }

    func test_unregisteredTarget_isSkipped() {
        controller.unregister(b)
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertNil(b.current)
        XCTAssertEqual(controller.selectedSpans()[1], SelectedSpan(id: "b", text: nil))
    }

    func test_anchorNotInOrder_isIgnored() {
        controller.beginCrossMessage(anchorID: "zzz", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        XCTAssertFalse(controller.hasSelection)
    }

    func test_copyTranscript_writesProviderText_andSkipsEmpty() {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.transcriptProvider = { SelectionTranscript(text: "[x] Me: hi", messageCount: 1) }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)
        controller.copyTranscript()
        XCTAssertEqual(written, ["[x] Me: hi"])

        controller.transcriptProvider = { SelectionTranscript(text: "", messageCount: 0) }
        controller.copyTranscript()
        XCTAssertEqual(written, ["[x] Me: hi"], "an empty transcript must not clear the pasteboard")
    }

    func test_copyTranscript_withoutSelection_isNoop() {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.transcriptProvider = { SelectionTranscript(text: "x", messageCount: 1) }
        controller.copyTranscript()
        XCTAssertEqual(written, [])
    }

    // MARK: Begin result

    func test_beginCrossMessage_reportsWhetherASelectionStarted() {
        XCTAssertTrue(controller.beginCrossMessage(anchorID: "a", charIndex: 0))
        XCTAssertTrue(controller.hasSelection)
        XCTAssertFalse(controller.beginCrossMessage(anchorID: "not-a-row", charIndex: 0),
                       "an anchor outside the row order starts nothing, and the caller must know")
        XCTAssertFalse(controller.hasSelection)
    }

    // MARK: finish() — snapshot and monitor

    func test_finish_snapshotsTheTranscript_andClearDropsIt() {
        var calls = 0
        controller.transcriptProvider = {
            calls += 1
            return SelectionTranscript(text: "[x] Me: hi", messageCount: 2)
        }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)
        XCTAssertNil(controller.finishedTranscript, "no snapshot until the drag ends")
        controller.finish()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.finishedTranscript?.text, "[x] Me: hi")
        XCTAssertEqual(controller.finishedTranscript?.messageCount, 2)
        controller.clear()
        XCTAssertNil(controller.finishedTranscript)
    }

    func test_finish_withLiveSelection_armsExactlyOneClearMonitor() {
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 220), window: nil)
        controller.finish()
        XCTAssertTrue(controller.hasClearMonitor)
        controller.clear()
        XCTAssertFalse(controller.hasClearMonitor)
    }

    /// `applySpans` inside `finish()` can clear the selection outright (an end
    /// left the row order). Arming the clear monitor anyway left a monitor
    /// with nothing to clear firing on every left press for the life of the
    /// controller.
    func test_finish_thatClearsTheSelection_armsNoMonitor() {
        controller.transcriptProvider = { SelectionTranscript(text: "x", messageCount: 1) }
        controller.beginCrossMessage(anchorID: "a", charIndex: 0)
        controller.extend(toWindowPoint: NSPoint(x: 50, y: 130), window: nil)
        controller.orderedIDs = ["b", "c"]   // the anchor row leaves
        controller.finish()
        XCTAssertFalse(controller.hasSelection)
        XCTAssertFalse(controller.hasClearMonitor)
        XCTAssertNil(controller.finishedTranscript)
    }

    func test_copyText_writesCapturedText_andSkipsEmpty() {
        var written: [String] = []
        controller.pasteboardWriter = { written.append($0) }
        controller.copyText("captured at menu-build time")
        controller.copyText("")
        XCTAssertEqual(written, ["captured at menu-build time"],
                       "captured text copies without a live selection; empty must not clear the pasteboard")
    }
}
#endif
