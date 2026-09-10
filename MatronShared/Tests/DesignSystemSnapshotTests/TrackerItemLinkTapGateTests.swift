import XCTest
@testable import MatronDesignSystem

/// Tracker-link taps resolve asynchronously and finish OUT OF ORDER: a miss
/// suspends inside a full `refresh(scope: .all)` while a tap made a moment
/// later hits the local store and returns at once. The gate is what stops
/// the slow one coming back afterwards to navigate somewhere the user has
/// already left, or to post an alert about a number they have moved on from
/// (CodeRabbit, item #115 round 5).
@MainActor
final class TrackerItemLinkTapGateTests: XCTestCase {

    /// The finding, reproduced: tap #65 (slow, resolves to a miss), then tap
    /// #9 (fast, resolves to a real item). Only #9 may act, and #65's alert
    /// must never appear — not even after it finally returns.
    func test_aSlowTapCannotActOnceALaterTapHasArrived() async {
        let gate = TrackerItemLinkTapGate()
        var applied: [TrackerItemLinkOutcome] = []
        var slowSawCancellation = false

        let slowSuspended = expectation(description: "the slow resolve is suspended")
        let slowReturned = expectation(description: "the slow resolve returned")
        var release: CheckedContinuation<Void, Never>?

        gate.begin(TrackerItemLinkTap(num: 65), resolve: { _ in
            await withCheckedContinuation { continuation in
                release = continuation
                slowSuspended.fulfill()
            }
            slowSawCancellation = Task.isCancelled
            slowReturned.fulfill()
            return .explain("Item #65 isn't on this device yet.")
        }, apply: { applied.append($0) })
        await fulfillment(of: [slowSuspended], timeout: 2)

        let fastApplied = expectation(description: "the later tap acted")
        gate.begin(TrackerItemLinkTap(num: 9), resolve: { _ in .open(itemID: "id-9") },
                   apply: { applied.append($0); fastApplied.fulfill() })
        await fulfillment(of: [fastApplied], timeout: 2)

        // Now let the superseded resolve finish. It runs straight from here
        // to the gate's currency check with no suspension in between, so
        // once `slowReturned` lands its verdict has already been taken.
        release?.resume()
        await fulfillment(of: [slowReturned], timeout: 2)
        await Task.yield()

        XCTAssertEqual(applied, [.open(itemID: "id-9")],
                       "only the latest tap may navigate, and the stale miss must never reach the alert")
        XCTAssertTrue(slowSawCancellation, "a superseded resolve is cancelled as well as ignored")
    }

    /// The gate is not a latch: once a tap has finished, the next one acts
    /// normally.
    func test_aTapAfterTheLastOneFinishedStillActs() async {
        let gate = TrackerItemLinkTapGate()
        var applied: [TrackerItemLinkOutcome] = []

        for (num, id) in [(65, "id-65"), (9, "id-9")] {
            let done = expectation(description: "#\(num) acted")
            gate.begin(TrackerItemLinkTap(num: num), resolve: { _ in .open(itemID: id) },
                       apply: { applied.append($0); done.fulfill() })
            await fulfillment(of: [done], timeout: 2)
        }

        XCTAssertEqual(applied, [.open(itemID: "id-65"), .open(itemID: "id-9")])
    }

    /// Two taps on the SAME number are two taps (`TrackerItemLinkTap.id`),
    /// so the second supersedes the first rather than being mistaken for it
    /// — one navigation, from the tap the user made last.
    func test_twoTapsOnTheSameNumberResolveToOneNavigation() async {
        let gate = TrackerItemLinkTapGate()
        var applied: [TrackerItemLinkOutcome] = []

        let firstSuspended = expectation(description: "the first #65 is suspended")
        var release: CheckedContinuation<Void, Never>?
        gate.begin(TrackerItemLinkTap(num: 65), resolve: { _ in
            await withCheckedContinuation { continuation in
                release = continuation
                firstSuspended.fulfill()
            }
            return .open(itemID: "id-65")
        }, apply: { applied.append($0) })
        await fulfillment(of: [firstSuspended], timeout: 2)

        let secondApplied = expectation(description: "the second #65 acted")
        gate.begin(TrackerItemLinkTap(num: 65), resolve: { _ in .open(itemID: "id-65") },
                   apply: { applied.append($0); secondApplied.fulfill() })
        await fulfillment(of: [secondApplied], timeout: 2)

        release?.resume()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(applied, [.open(itemID: "id-65")], "one tap, one push — not two")
    }

    /// Pins the contract `TrackerItemLinksModifier` depends on for the miss
    /// alert: applying an `.explain` outcome (as the modifier's `apply`
    /// closure does) sets `relay.alert` to that message, and clearing it
    /// (as the alert's OK button and dismiss binding do) resets it to
    /// `nil`. SwiftUI's `body` re-render on that write can't be exercised
    /// by XCTest — this is the behavioural slice that CAN be pinned (Bugbot,
    /// item #115 fix round 6).
    func test_explainOutcomeSetsRelayAlert_andClearingItResetsToNil() async {
        let gate = TrackerItemLinkTapGate()
        let relay = TrackerItemLinkRelay()
        let done = expectation(description: "applied")

        gate.begin(TrackerItemLinkTap(num: 65),
                   resolve: { _ in .explain("Item #65 isn't on this device yet.") },
                   apply: { outcome in
                       if case .explain(let message) = outcome { relay.alert = message }
                       done.fulfill()
                   })
        await fulfillment(of: [done], timeout: 2)

        XCTAssertEqual(relay.alert, "Item #65 isn't on this device yet.")

        relay.alert = nil
        XCTAssertNil(relay.alert)
    }

    /// `.ignore` is the host saying "I couldn't even try" (no session yet, a
    /// link to the item already on screen): it must not clear or set
    /// anything — the gate just applies it and the modifier does nothing.
    func test_ignoreIsDeliveredLikeAnyOtherOutcome() async {
        let gate = TrackerItemLinkTapGate()
        var applied: [TrackerItemLinkOutcome] = []
        let done = expectation(description: "applied")
        gate.begin(TrackerItemLinkTap(num: 65), resolve: { _ in .ignore },
                   apply: { applied.append($0); done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(applied, [.ignore])
    }
}
