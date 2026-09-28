import XCTest
@testable import MatronMac

@MainActor final class MacTimelineScrollViewTests: XCTestCase {
    private func wheel(_ delta: Int32, phase: CGScrollPhase?) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        if let phase {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        return NSEvent(cgEvent: cg)!
    }

    private func makeView() -> MacTimelineScrollView {
        let sv = MacTimelineScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let doc = FlippedDocView(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        sv.documentView = doc
        return sv
    }
    final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

    func test_phasedTrackpadScrollReportsBeganAndEnded() {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(0, phase: .began))
        sv.scrollWheel(with: wheel(-20, phase: .changed))
        sv.scrollWheel(with: wheel(0, phase: .ended))
        XCTAssertEqual(log.first, "began")
        XCTAssertEqual(log.last, "ended")
    }

    func test_mouseWheelTickIsBeganThenEnded() {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(-3, phase: nil))
        XCTAssertEqual(log, ["began", "ended"])
    }

    func test_programmaticScrollIsNotReportedAsUser() {
        let sv = makeView()
        var moves = 0
        sv.onUserScrolled = { _ in moves += 1 }
        sv.isApplyingProgrammaticScroll = true
        sv.contentView.scroll(to: NSPoint(x: 0, y: 500))
        sv.reflectScrolledClipView(sv.contentView)
        sv.isApplyingProgrammaticScroll = false
        XCTAssertEqual(moves, 0)
    }
}
