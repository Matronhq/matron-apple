import XCTest
import SwiftUI
@testable import MatronDesignSystem
import MatronModels

final class AgentCapacityRowContentTests: XCTestCase {
    func test_sessionsText_pluralisesAndNamesZero() {
        XCTAssertEqual(AgentCapacityRowContent.sessionsText(0), "No active sessions")
        XCTAssertEqual(AgentCapacityRowContent.sessionsText(1), "1 active session")
        XCTAssertEqual(AgentCapacityRowContent.sessionsText(2), "2 active sessions")
    }

    /// The chooser rows tint percentages with the same helper the /usage
    /// bars use — one threshold table, not two (green < 50, orange < 80,
    /// red >= 80 is pinned by `UsageMetersFormatTests`).
    func test_percentTint_reusesUsageMetersThresholds() {
        XCTAssertEqual(AgentCapacityRowContent.percentColor(49), UsageMetersFormat.barColor(percent: 49))
        XCTAssertEqual(AgentCapacityRowContent.percentColor(50), UsageMetersFormat.barColor(percent: 50))
        XCTAssertEqual(AgentCapacityRowContent.percentColor(80), UsageMetersFormat.barColor(percent: 80))
    }

    // MARK: Cached (offline) numbers

    private let capturedAt = Date(timeIntervalSince1970: 1_754_900_000)
    private func cached() -> AgentCapacityFreshness { .offline(capturedAt: capturedAt) }

    func test_sessionsLine_readsTheCountForLiveNumbers() {
        let capacity = BoxCapacity(liveSessions: 2, limitLines: [], accountEmail: nil)
        XCTAssertEqual(AgentCapacityRowContent.sessionsLine(capacity, freshness: .live),
                       "2 active sessions")
    }

    /// A box the host has put to sleep is running nothing at all, so its
    /// cached session count is the one number that is not merely stale but
    /// false. The quota lines survive; this one is dropped.
    func test_sessionsLine_isDroppedForCachedNumbers() {
        let capacity = BoxCapacity(liveSessions: 2, limitLines: [], accountEmail: nil)
        XCTAssertNil(AgentCapacityRowContent.sessionsLine(capacity, freshness: cached()))
    }

    /// The Mac grid renders the bare count in a fixed-width cell, so it takes
    /// the same decision as a number rather than re-deriving the rule.
    func test_shownSessions_matchesTheSessionsLineDecision() {
        let capacity = BoxCapacity(liveSessions: 2, limitLines: [], accountEmail: nil)
        XCTAssertEqual(AgentCapacityRowContent.shownSessions(capacity, freshness: .live), 2)
        XCTAssertNil(AgentCapacityRowContent.shownSessions(capacity, freshness: cached()))
        XCTAssertNil(AgentCapacityRowContent.shownSessions(nil, freshness: .live),
                     "no capacity at all — an old bridge or a box that never answered")
    }

    func test_sessionsLine_isAbsentWhenTheBridgeSentNoActivityBlock() {
        let capacity = BoxCapacity(liveSessions: nil, limitLines: [], accountEmail: nil)
        XCTAssertNil(AgentCapacityRowContent.sessionsLine(capacity, freshness: .live))
    }

    func test_percentEmphasis_tintsLiveInWindowNumbers() {
        XCTAssertEqual(AgentCapacityRowContent.percentEmphasis(85, expired: false, freshness: .live),
                       .tinted(UsageMetersFormat.barColor(percent: 85)))
    }

    /// Unchanged rule: a percentage from before its own reset moment is dead,
    /// whoever reported it.
    func test_percentEmphasis_deemphasisesAnExpiredLineOnALiveBox() {
        XCTAssertEqual(AgentCapacityRowContent.percentEmphasis(85, expired: true, freshness: .live),
                       .deemphasised)
    }

    /// New rule: cached numbers never wear the green/orange/red that vouches
    /// for a reading as current, even while their window is still open.
    func test_percentEmphasis_deemphasisesCachedNumbers() {
        XCTAssertEqual(AgentCapacityRowContent.percentEmphasis(85, expired: false, freshness: cached()),
                       .deemphasised)
    }

    // MARK: Accessibility

    func test_limitAccessibilityLabel_liveCopyIsUnchanged() {
        XCTAssertEqual(
            AgentCapacityRowContent.limitAccessibilityLabel(
                label: "Current session", percent: 39, expired: false,
                resetText: "resets 11:59 PM", freshness: .live),
            "Current session, 39 percent used, resets 11:59 PM")
        XCTAssertEqual(
            AgentCapacityRowContent.limitAccessibilityLabel(
                label: "Current session", percent: 39, expired: true,
                resetText: "reset", freshness: .live),
            "Current session, 39 percent used before the limit reset, reset")
        XCTAssertEqual(
            AgentCapacityRowContent.limitAccessibilityLabel(
                label: "Current week", percent: 12, expired: false,
                resetText: nil, freshness: .live),
            "Current week, 12 percent used")
    }

    /// The age itself is announced once, by the row's own caption — repeating
    /// it in every limit cell would make a three-column Mac row read it three
    /// times.
    func test_limitAccessibilityLabel_marksCachedNumbersLastKnown() {
        XCTAssertEqual(
            AgentCapacityRowContent.limitAccessibilityLabel(
                label: "Current session", percent: 39, expired: false,
                resetText: "resets 11:59 PM", freshness: cached()),
            "Current session, 39 percent used, resets 11:59 PM, last known")
    }
}
