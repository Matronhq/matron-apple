#if os(macOS)
import XCTest
import MatronModels
@testable import MatronMac

/// Pins which grid chrome the New Chat picker puts up. The rule follows what
/// the rows can actually *render*, not what the capacity map happens to hold:
/// a legacy bridge parses to an empty capacity, and a sleeping box's cached
/// session count is deliberately dropped, so either can leave a "Sessions"
/// heading over a column of em-dashes.
final class MacNewChatGridChromeTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_754_900_000)

    private func withSessions(_ count: Int) -> BoxCapacity {
        BoxCapacity(liveSessions: count, limitLines: [], accountEmail: nil)
    }

    private func withLines() -> BoxCapacity {
        BoxCapacity(liveSessions: 4,
                    limitLines: [LimitLine(id: "session", label: "Current session",
                                           percent: 39, resetsAt: nil)],
                    accountEmail: nil)
    }

    func test_showsSessions_whenAConnectedBoxReportedACount() {
        XCTAssertTrue(MacNewChatSheet.showsSessions(
            [(withSessions(2), .live), (nil, .live)], pending: false))
    }

    /// A count of zero is a real answer — "0" is information, unlike "—".
    func test_showsSessions_forAZeroCount() {
        XCTAssertTrue(MacNewChatSheet.showsSessions([(withSessions(0), .live)], pending: false))
    }

    /// The feature's flagship case: every box asleep. Their cached counts are
    /// dropped, so heading the column would promise data no row can supply.
    func test_showsSessions_isFalseWhenTheWholeFleetIsAsleep() {
        XCTAssertFalse(MacNewChatSheet.showsSessions(
            [(withLines(), .offline(capturedAt: capturedAt)),
             (withLines(), .offline(capturedAt: capturedAt))],
            pending: false))
    }

    func test_showsSessions_isFalseForAnAllLegacyFleet() {
        let empty = BoxCapacity(liveSessions: nil, limitLines: [], accountEmail: nil)
        XCTAssertFalse(MacNewChatSheet.showsSessions([(empty, .live), (nil, .live)], pending: false))
    }

    /// A fan-out still in flight will fill the column shortly; the "…"
    /// placeholders need somewhere to sit.
    func test_showsSessions_whileAFanOutIsPending() {
        XCTAssertTrue(MacNewChatSheet.showsSessions([(nil, .live)], pending: true))
    }

    /// One awake box among sleepers still earns the column, and every row
    /// then agrees with the header (the sleepers render "—").
    func test_showsSessions_whenOnlyOneBoxIsAwake() {
        XCTAssertTrue(MacNewChatSheet.showsSessions(
            [(withLines(), .offline(capturedAt: capturedAt)), (withSessions(1), .live)],
            pending: false))
    }
}
#endif
