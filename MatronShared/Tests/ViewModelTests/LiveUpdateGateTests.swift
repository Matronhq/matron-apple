import XCTest
@testable import MatronViewModels

@MainActor
final class LiveUpdateGateTests: XCTestCase {
    private final class Owner {}

    /// What a replaced update held (a whole list, in the app) is freed off
    /// main, and so is what a flushed one held.
    func testReplacedAndFlushedUpdatesAreFreedOffMain() {
        let gate = LiveUpdateGate(interval: .seconds(10))
        let owner = Owner()
        let replaced = expectation(description: "replaced update freed")
        let flushed = expectation(description: "flushed update freed")
        let onMain = FreedOnMain()
        gate.beginHold()
        do {
            let state = Tracer { isMain in onMain.note(isMain); replaced.fulfill() }
            gate.submit(owner, "a") { _ = state }
        }
        do {
            let state = Tracer { isMain in onMain.note(isMain); flushed.fulfill() }
            gate.submit(owner, "a") { _ = state }
        }
        wait(for: [replaced], timeout: 5)
        gate.endHold()
        wait(for: [flushed], timeout: 5)
        XCTAssertEqual(onMain.count, 0)
    }

    func testAFirstUpdateAppliesAtOnce() {
        let gate = LiveUpdateGate(interval: .seconds(10))
        let owner = Owner()
        var applied: [Int] = []
        gate.submit(owner, "a") { applied.append(1) }
        XCTAssertEqual(applied, [1])
    }

    /// Inside the interval, updates wait; each owner's newest wins, and
    /// every waiting owner applies in the same flush.
    func testUpdatesInsideTheIntervalApplyTogetherNewestFirstWins() async throws {
        let gate = LiveUpdateGate(interval: .milliseconds(150))
        let list = Owner(), items = Owner()
        var applied: [String] = []
        gate.submit(list, "list") { applied.append("list-0") }
        gate.submit(list, "list") { applied.append("list-1") }
        gate.submit(items, "items") { applied.append("items-1") }
        gate.submit(list, "list") { applied.append("list-2") }
        XCTAssertEqual(applied, ["list-0"])
        XCTAssertEqual(gate.flushCount, 1)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(applied, ["list-0", "list-2", "items-1"])
        XCTAssertEqual(gate.flushCount, 2, "both owners land in one flush")
    }

    func testAHoldParksEverythingUntilItEnds() {
        let gate = LiveUpdateGate(interval: .zero)
        let owner = Owner()
        var applied: [String] = []
        gate.beginHold()
        gate.submit(owner, "a") { applied.append("a") }
        XCTAssertEqual(applied, [])
        gate.endHold()
        XCTAssertEqual(applied, ["a"])
    }

    func testHoldsNest() {
        let gate = LiveUpdateGate(interval: .zero)
        var applied: [String] = []
        let owner = Owner()
        gate.beginHold()
        gate.beginHold()
        gate.submit(owner, "a") { applied.append("a") }
        gate.endHold()
        XCTAssertEqual(applied, [])
        gate.endHold()
        XCTAssertEqual(applied, ["a"])
        gate.endHold()
        XCTAssertEqual(gate.isHeld, false, "an unmatched end never goes negative")
    }

    /// A hold that never ends (a missed end-of-scroll) still lets updates
    /// through after `maxHold`.
    func testALongHoldStillFlushesAfterMaxHold() async throws {
        let gate = LiveUpdateGate(interval: .zero, maxHold: .milliseconds(150))
        let owner = Owner()
        var applied: [String] = []
        gate.beginHold()
        gate.submit(owner, "a") { applied.append("a") }
        XCTAssertEqual(applied, [], "parked while held")
        let deadline = Date().addingTimeInterval(3)
        while applied.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(applied, ["a"])
        XCTAssertTrue(gate.isHeld, "the hold itself stands until its end")
    }

    /// A gone owner's parked update is dropped, not applied.
    func testAReleasedOwnersUpdateIsDropped() {
        let gate = LiveUpdateGate(interval: .zero)
        var applied: [String] = []
        gate.beginHold()
        var owner: Owner? = Owner()
        gate.submit(owner!, "a") { applied.append("a") }
        owner = nil
        gate.endHold()
        XCTAssertEqual(applied, [])
    }
}

private final class Tracer: Sendable {
    let freed: @Sendable (Bool) -> Void
    init(freed: @escaping @Sendable (Bool) -> Void) { self.freed = freed }
    deinit { freed(Thread.isMainThread) }
}

private final class FreedOnMain: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain = 0
    var count: Int { lock.withLock { onMain } }
    func note(_ isMain: Bool) { if isMain { lock.withLock { onMain += 1 } } }
}
