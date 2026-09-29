import XCTest
@testable import MatronMac

@MainActor final class MacTimelineScrollViewTests: XCTestCase {
    private func wheel(_ delta: Int32, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase? = nil) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        if phase != nil || momentum != nil {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        if let phase {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if let momentum {
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        }
        return NSEvent(cgEvent: cg)!
    }

    /// Longer than `MacTimelineScrollView.momentumGrace`.
    private func pastMomentumGrace() async throws {
        try await Task.sleep(nanoseconds: UInt64((MacTimelineScrollView.momentumGrace + 0.15) * 1_000_000_000))
    }

    private func makeView() -> MacTimelineScrollView {
        let sv = MacTimelineScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let doc = FlippedDocView(frame: NSRect(x: 0, y: 0, width: 300, height: 3000))
        sv.documentView = doc
        return sv
    }
    final class FlippedDocView: NSView { override var isFlipped: Bool { true } }

    /// A lift with no momentum still ends the scroll — after the grace in
    /// which a momentum `began` would have cancelled it.
    func test_phasedTrackpadScrollReportsBeganAndEnded() async throws {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(0, phase: .began))
        sv.scrollWheel(with: wheel(-20, phase: .changed))
        sv.scrollWheel(with: wheel(0, phase: .ended))
        XCTAssertEqual(log, ["began"])                  // deferred: momentum may follow
        try await pastMomentumGrace()
        XCTAssertEqual(log, ["began", "ended"])
    }

    /// Final review Important 1: the finger lift is NOT the end of a flick —
    /// exactly one "ended", after the momentum ends.
    func test_flickReportsOneEndedAfterMomentum() async throws {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(0, phase: .began))
        sv.scrollWheel(with: wheel(40, phase: .changed))
        sv.scrollWheel(with: wheel(0, phase: .ended))
        sv.scrollWheel(with: wheel(30, phase: nil, momentum: .begin))
        sv.scrollWheel(with: wheel(20, phase: nil, momentum: .continuous))
        try await pastMomentumGrace()                   // the lift's deferral was cancelled
        XCTAssertEqual(log, ["began"])
        sv.scrollWheel(with: wheel(0, phase: nil, momentum: .end))
        XCTAssertEqual(log, ["began", "ended"])
        try await pastMomentumGrace()
        XCTAssertEqual(log, ["began", "ended"])
    }

    /// Wave M item 3: a main-thread stall outlasted the grace, so the lift's
    /// deferred "ended" fired before momentum began. The momentum reopens
    /// the gesture — a second "began" (follow released for its run) — and
    /// its own end closes it: exactly two of each.
    func test_momentumAfterTheGraceFiredReopensTheGesture() async throws {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(0, phase: .began))
        sv.scrollWheel(with: wheel(40, phase: .changed))
        sv.scrollWheel(with: wheel(0, phase: .ended))
        try await pastMomentumGrace()                   // the stall: the deferral fired
        XCTAssertEqual(log, ["began", "ended"])
        sv.scrollWheel(with: wheel(30, phase: nil, momentum: .begin))
        XCTAssertEqual(log, ["began", "ended", "began"])
        XCTAssertTrue(sv.isGestureOpenForTesting)
        sv.scrollWheel(with: wheel(20, phase: nil, momentum: .continuous))
        sv.scrollWheel(with: wheel(0, phase: nil, momentum: .end))
        XCTAssertEqual(log, ["began", "ended", "began", "ended"])
        try await pastMomentumGrace()
        XCTAssertEqual(log, ["began", "ended", "began", "ended"])
    }

    /// Wave M item 2: `cancelGesture()` (the controller killed momentum)
    /// closes the gesture and its pending deferred end, reporting nothing.
    func test_cancelGestureClosesSilently() async throws {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        sv.scrollWheel(with: wheel(0, phase: .began))
        sv.scrollWheel(with: wheel(40, phase: .changed))
        sv.scrollWheel(with: wheel(0, phase: .ended))   // arms the deferred end
        XCTAssertTrue(sv.isGestureOpenForTesting)
        sv.cancelGesture()
        XCTAssertFalse(sv.isGestureOpenForTesting)
        try await pastMomentumGrace()
        XCTAssertEqual(log, ["began"])
    }

    /// Review gap 7d: a scroller-knob drag reports only through the
    /// live-scroll notification pair — WillStart is "began", DidEnd arms the
    /// deferred "ended".
    func test_liveScrollNotificationsReportBeganAndEnded() async throws {
        let sv = makeView()
        var log: [String] = []
        sv.onUserScrollBegan = { log.append("began") }
        sv.onUserScrollEnded = { log.append("ended") }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: sv)
        XCTAssertEqual(log, ["began"])
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: sv)
        XCTAssertEqual(log, ["began"])                  // deferred: momentum may follow
        try await pastMomentumGrace()
        XCTAssertEqual(log, ["began", "ended"])
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
