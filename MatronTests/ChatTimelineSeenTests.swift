import XCTest
import UIKit
import MatronChat
import MatronJournal
import MatronViewModels
@testable import Matron

/// Read state (spec 2026-09-30): the UIKit timeline reports the rows on
/// screen, and only those, to the session's `SeenTracker`.
@MainActor
final class ChatTimelineSeenTests: XCTestCase {
    private final class SentOps: @unchecked Sendable {
        private let lock = NSLock(); private var ops: [ClientOp] = []
        func append(_ op: ClientOp) { lock.lock(); ops.append(op); lock.unlock() }
        var seqs: Set<Int64> {
            lock.lock(); defer { lock.unlock() }
            var out = Set<Int64>()
            for case let .seen(_, ranges) in ops { for range in ranges { out.formUnion(range) } }
            return out
        }
    }

    private func harness(_ sent: SentOps) -> TimelineHarness {
        let h = TimelineHarness()
        h.viewModel.seen = SeenTracker(dwell: .milliseconds(50), flushInterval: .milliseconds(50)) { sent.append($0) }
        return h
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func test_onlyTheRowsOnScreenAreSeen() async throws {
        let sent = SentOps()
        let h = harness(sent)
        try await h.start(with: TimelineFixtures.conversation(60))
        await waitFor { sent.seqs.contains(60) }
        XCTAssertTrue(sent.seqs.contains(60), "the tail is on screen at open")
        XCTAssertFalse(sent.seqs.contains(1), "the top of a 60-message chat was never on screen")
        XCTAssertLessThan(sent.seqs.count, 30)
    }

    func test_aNewRowArrivingWhileFollowingTheTailIsSeen() async throws {
        let sent = SentOps()
        let h = harness(sent)
        var items = TimelineFixtures.conversation(30)
        try await h.start(with: items)
        await waitFor { sent.seqs.contains(30) }
        items.append(TimelineFixtures.text(31))
        try await h.emit(items)
        await waitFor { sent.seqs.contains(31) }
        XCTAssertTrue(sent.seqs.contains(31))
    }

    func test_scrollingUpReportsTheRowsScrolledTo() async throws {
        let sent = SentOps()
        let h = harness(sent)
        try await h.start(with: TimelineFixtures.conversation(60))
        await waitFor { sent.seqs.contains(60) }
        h.controller.scrollViewWillBeginDragging(h.collectionView)
        h.collectionView.contentOffset = .zero
        // The top of the applied window (the chat may hold more history
        // above it, not yet revealed).
        let top = try XCTUnwrap(h.controller.appliedRowIDs.lazy.compactMap { Int64($0) }.first)
        await waitFor { sent.seqs.contains(top) }
        XCTAssertTrue(sent.seqs.contains(top))
    }

    func test_aSuspendedTimelineReportsNothingMore() async throws {
        let sent = SentOps()
        let h = harness(sent)
        try await h.start(with: TimelineFixtures.conversation(60))
        h.controller.suspend()
        h.controller.scrollViewWillBeginDragging(h.collectionView)
        h.collectionView.contentOffset = .zero
        let top = try XCTUnwrap(h.controller.appliedRowIDs.lazy.compactMap { Int64($0) }.first)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(sent.seqs.contains(top), "rows reached while off screen are not seen")
    }
}
