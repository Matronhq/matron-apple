import XCTest
import CoreGraphics
@testable import MatronJournal

/// Read state (spec 2026-09-30): dwell, range batching and flush.
final class SeenLedgerTests: XCTestCase {
    private let t0 = ContinuousClock.now
    private let surface = UUID()

    private func seconds(_ s: Double) -> ContinuousClock.Instant { t0 + .milliseconds(Int(s * 1000)) }

    private func ranges(_ ops: [ClientOp]) -> [String: [ClosedRange<Int64>]] {
        var out: [String: [ClosedRange<Int64>]] = [:]
        for case let .seen(convoID, r) in ops { out[convoID, default: []] += r }
        return out
    }

    // MARK: Dwell

    func testARowCountsAsSeenOnlyAfterOneSecondVisible() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(0))
        ledger.promote(now: seconds(0.9))
        XCTAssertFalse(ledger.hasPending, "0.9 s is not long enough")
        ledger.promote(now: seconds(1.0))
        XCTAssertEqual(ranges(ledger.drain()), ["c": [10...10]])
    }

    func testARowThatScrollsAwayBeforeTheDwellIsNotSeen() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10, 11], now: seconds(0))
        ledger.setVisible(surface: surface, convoID: "c", seqs: [11], now: seconds(0.5))
        ledger.promote(now: seconds(2))
        XCTAssertEqual(ranges(ledger.drain()), ["c": [11...11]])
    }

    func testARowThatStaysVisibleKeepsItsDwellStartAcrossUpdates() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(0))
        // Scroll ticks re-report the same row; the dwell must not restart.
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10, 11], now: seconds(0.6))
        ledger.promote(now: seconds(1.0))
        XCTAssertEqual(ranges(ledger.drain()), ["c": [10...10]])
        XCTAssertEqual(ledger.nextDeadline, seconds(1.6), "11 still dwelling from 0.6 s")
    }

    func testReturningToARowRestartsItsDwell() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(0))
        ledger.setVisible(surface: surface, convoID: "c", seqs: [], now: seconds(0.8))
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(1.0))
        ledger.promote(now: seconds(1.5))
        XCTAssertFalse(ledger.hasPending)
        ledger.promote(now: seconds(2.0))
        XCTAssertTrue(ledger.hasPending)
    }

    func testNothingDwellsWhileInactive() {
        var ledger = SeenLedger(isActive: false)
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(0))
        ledger.promote(now: seconds(5))
        XCTAssertFalse(ledger.hasPending)
        XCTAssertNil(ledger.nextDeadline)
        // Coming back restarts the clock from the moment of activation.
        ledger.setActive(true, now: seconds(5))
        ledger.promote(now: seconds(5.9))
        XCTAssertFalse(ledger.hasPending)
        ledger.promote(now: seconds(6))
        XCTAssertEqual(ranges(ledger.drain()), ["c": [10...10]])
    }

    func testGoingInactivePromotesWhatAlreadyDweltAndPausesTheRest() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(0))
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10, 11], now: seconds(0.5))
        ledger.setActive(false, now: seconds(1.2))
        XCTAssertEqual(ranges(ledger.drain()), ["c": [10...10]])
        ledger.promote(now: seconds(10))
        XCTAssertFalse(ledger.hasPending, "11 only had 0.7 s before the app left")
    }

    func testARowIsReportedOnceWhileItStaysOnScreen() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(0))
        ledger.promote(now: seconds(1))
        _ = ledger.drain()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(3))
        ledger.promote(now: seconds(10))
        XCTAssertFalse(ledger.hasPending)
        XCTAssertNil(ledger.nextDeadline)
    }

    func testRemovingASurfacePromotesWhatDweltAndDropsTheRest() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10], now: seconds(0))
        ledger.setVisible(surface: surface, convoID: "c", seqs: [10, 11], now: seconds(0.8))
        ledger.removeSurface(surface, now: seconds(1.1))
        XCTAssertEqual(ranges(ledger.drain()), ["c": [10...10]])
        ledger.promote(now: seconds(5))
        XCTAssertFalse(ledger.hasPending)
    }

    func testTwoSurfacesDwellIndependently() {
        var ledger = SeenLedger()
        let other = UUID()
        ledger.setVisible(surface: surface, convoID: "a", seqs: [1], now: seconds(0))
        ledger.setVisible(surface: other, convoID: "b", seqs: [7], now: seconds(0.5))
        ledger.promote(now: seconds(1.0))
        XCTAssertEqual(ranges(ledger.drain()), ["a": [1...1]])
        ledger.promote(now: seconds(1.5))
        XCTAssertEqual(ranges(ledger.drain()), ["b": [7...7]])
    }

    func testASurfaceSwitchingConversationsStartsOver() {
        var ledger = SeenLedger()
        ledger.setVisible(surface: surface, convoID: "a", seqs: [5], now: seconds(0))
        ledger.setVisible(surface: surface, convoID: "b", seqs: [5], now: seconds(0.9))
        ledger.promote(now: seconds(1.5))
        XCTAssertFalse(ledger.hasPending, "seq 5 of b has only been up 0.6 s")
    }

    func testMarkSeenSkipsTheDwell() {
        var ledger = SeenLedger(isActive: false)
        ledger.markSeen(convoID: "c", seq: 42)
        XCTAssertEqual(ranges(ledger.drain()), ["c": [42...42]])
    }

    // MARK: Ranges

    func testConsecutiveSeqsMergeIntoRanges() {
        XCTAssertEqual(SeenLedger.ranges([5, 1, 2, 3, 7, 8, 10]), [1...3, 5...5, 7...8, 10...10])
        XCTAssertEqual(SeenLedger.ranges([]), [])
    }

    func testMoreThanSixtyFourRangesSplitAcrossOps() {
        var ledger = SeenLedger()
        // 130 isolated seqs → 130 single ranges → 64 + 64 + 2.
        for i in 0..<130 { ledger.markSeen(convoID: "c", seq: Int64(i * 2 + 1)) }
        let ops = ledger.drain()
        let counts = ops.map { op -> Int in
            guard case let .seen(_, r) = op else { return -1 }
            return r.count
        }
        XCTAssertEqual(counts, [64, 64, 2])
        XCTAssertEqual(ranges(ops)["c"]?.first, 1...1)
        XCTAssertEqual(ranges(ops)["c"]?.last, 259...259)
        XCTAssertFalse(ledger.hasPending)
    }

    func testDrainGroupsByConversation() {
        var ledger = SeenLedger()
        ledger.markSeen(convoID: "b", seq: 3)
        ledger.markSeen(convoID: "a", seq: 1)
        ledger.markSeen(convoID: "a", seq: 2)
        XCTAssertEqual(ledger.drain(), [.seen(convoID: "a", ranges: [1...2]), .seen(convoID: "b", ranges: [3...3])])
    }

    func testRestorePutsAFailedOpBack() {
        var ledger = SeenLedger()
        ledger.markSeen(convoID: "c", seq: 1)
        ledger.markSeen(convoID: "c", seq: 2)
        let ops = ledger.drain()
        XCTAssertFalse(ledger.hasPending)
        ops.forEach { ledger.restore($0) }
        XCTAssertEqual(ledger.drain(), ops)
    }
}

final class SeenVisibilityTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 1000, width: 400, height: 800)

    func testHalfVisibleRowsCount() {
        let frames: [(id: String, frame: CGRect)] = [
            ("above", CGRect(x: 0, y: 800, width: 400, height: 100)),       // fully above
            ("topHalf", CGRect(x: 0, y: 950, width: 400, height: 100)),     // 50 of 100 shown
            ("topSliver", CGRect(x: 0, y: 900, width: 400, height: 140)),   // 40 of 140
            ("middle", CGRect(x: 0, y: 1300, width: 400, height: 100)),
            ("bottomSliver", CGRect(x: 0, y: 1760, width: 400, height: 100)), // 40 of 100
            ("below", CGRect(x: 0, y: 1900, width: 400, height: 100)),
        ]
        XCTAssertEqual(SeenVisibility.visibleIDs(frames, in: viewport), ["topHalf", "middle"])
    }

    func testARowTallerThanTwoScreensCountsWhenItFillsHalfTheViewport() {
        let tall = CGRect(x: 0, y: 0, width: 400, height: 5000)
        XCTAssertEqual(SeenVisibility.visibleIDs([("tall", tall)], in: viewport), ["tall"],
                       "it can never be half visible, but it fills the whole screen")
        let peeking = CGRect(x: 0, y: 1500, width: 400, height: 5000) // 300 of 800 on screen
        XCTAssertEqual(SeenVisibility.visibleIDs([("tall", peeking)], in: viewport), [])
        let halfScreen = CGRect(x: 0, y: 1400, width: 400, height: 5000) // 400 of 800
        XCTAssertEqual(SeenVisibility.visibleIDs([("tall", halfScreen)], in: viewport), ["tall"])
    }

    func testEmptyViewportShowsNothing() {
        XCTAssertEqual(SeenVisibility.visibleIDs([("a", CGRect(x: 0, y: 0, width: 1, height: 1))], in: .zero), [])
    }

    func testRowIDsMapToSeqsOnlyForJournalEvents() {
        XCTAssertEqual(SeenVisibility.seq(forRowID: "1234"), 1234)
        XCTAssertNil(SeenVisibility.seq(forRowID: "echo:L1"))
        XCTAssertNil(SeenVisibility.seq(forRowID: "eph:m1"))
        XCTAssertNil(SeenVisibility.seq(forRowID: "sep:1700000000"))
        XCTAssertNil(SeenVisibility.seq(forRowID: "0"))
    }
}

/// The timed driver: real clocks with short intervals.
@MainActor
final class SeenTrackerTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var ops: [ClientOp] = []
        var failing = false
        func append(_ op: ClientOp) throws {
            lock.lock(); defer { lock.unlock() }
            if failing { throw JournalSyncError.offline }
            ops.append(op)
        }
        var all: [ClientOp] { lock.lock(); defer { lock.unlock() }; return ops }
    }

    private func make(_ sent: Sent, dwell: Duration = .milliseconds(100),
                      flush: Duration = .milliseconds(200)) -> SeenTracker {
        SeenTracker(dwell: dwell, flushInterval: flush) { op in try sent.append(op) }
    }

    private func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testVisibleRowsFlushAsOneRangeAfterDwellAndInterval() async {
        let sent = Sent()
        let tracker = make(sent)
        tracker.setVisible(surface: UUID(), convoID: "c", rowIDs: ["sep:1", "10", "11", "12", "echo:x"])
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(sent.all.isEmpty, "dwelt, but the flush interval hasn't passed")
        await waitFor { !sent.all.isEmpty }
        XCTAssertEqual(sent.all, [.seen(convoID: "c", ranges: [10...12])])
    }

    func testGoingInactiveFlushesAtOnce() async {
        let sent = Sent()
        let tracker = make(sent, flush: .seconds(60))
        tracker.setVisible(surface: UUID(), convoID: "c", rowIDs: ["5"])
        try? await Task.sleep(for: .milliseconds(150))
        tracker.setActive(false)
        await waitFor { !sent.all.isEmpty }
        XCTAssertEqual(sent.all, [.seen(convoID: "c", ranges: [5...5])])
    }

    func testClosingTheChatFlushesAtOnce() async {
        let sent = Sent()
        let tracker = make(sent, flush: .seconds(60))
        let surface = UUID()
        tracker.setVisible(surface: surface, convoID: "c", rowIDs: ["5"])
        try? await Task.sleep(for: .milliseconds(150))
        tracker.removeSurface(surface)
        await waitFor { !sent.all.isEmpty }
        XCTAssertEqual(sent.all, [.seen(convoID: "c", ranges: [5...5])])
    }

    func testAFailedFlushIsRetried() async {
        let sent = Sent()
        sent.failing = true
        let tracker = make(sent, dwell: .milliseconds(10), flush: .milliseconds(50))
        tracker.markSeen(convoID: "c", seq: 3)
        try? await Task.sleep(for: .milliseconds(120))
        sent.failing = false
        await waitFor { !sent.all.isEmpty }
        XCTAssertEqual(sent.all, [.seen(convoID: "c", ranges: [3...3])])
    }

    func testItemSeenSendsTheNewestCommentOnceAndAgainWhenANewerOneRenders() async {
        let sent = Sent()
        let tracker = make(sent)
        let first = Date(timeIntervalSince1970: 1_700_000_000.123)
        tracker.setItemOnScreen("it_1", newestComment: first)
        tracker.setItemOnScreen("it_1", newestComment: first)
        await waitFor { !sent.all.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sent.all, [.itemSeen(itemID: "it_1", throughCommentAt: 1_700_000_000_123)])
        tracker.setItemOnScreen("it_1", newestComment: first.addingTimeInterval(5))
        await waitFor { sent.all.count == 2 }
        XCTAssertEqual(sent.all.last, .itemSeen(itemID: "it_1", throughCommentAt: 1_700_000_005_123))
    }

    func testItemSeenWaitsForTheAppToBeActive() async {
        let sent = Sent()
        let tracker = make(sent)
        tracker.setActive(false)
        tracker.setItemOnScreen("it_1", newestComment: nil)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sent.all.isEmpty)
        tracker.setActive(true)
        await waitFor { !sent.all.isEmpty }
        XCTAssertEqual(sent.all, [.itemSeen(itemID: "it_1", throughCommentAt: 0)])
    }

    func testAnItemClosedWhileInactiveIsNotReportedOnReturn() async {
        let sent = Sent()
        let tracker = make(sent)
        tracker.setActive(false)
        tracker.setItemOnScreen("it_1", newestComment: nil)
        tracker.removeItem("it_1")
        tracker.setActive(true)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sent.all.isEmpty)
    }
}
