import XCTest
import MatronModels

/// Pins the freshness marker a chooser row carries alongside its capacity:
/// live numbers say nothing, cached ones say how old they are.
final class AgentCapacityFreshnessTests: XCTestCase {
    /// 2026-08-11 08:13 UTC.
    private let now = Date(timeIntervalSince1970: 1_754_900_000)
    private let english = Locale(identifier: "en_US")

    func test_live_carriesNoAgeCaption() {
        XCTAssertFalse(AgentCapacityFreshness.live.isStale)
        XCTAssertNil(AgentCapacityFreshness.live.ageText(now: now, locale: english),
                     "numbers fetched this visit need no apology")
    }

    func test_offline_isStale() {
        XCTAssertTrue(AgentCapacityFreshness.offline(capturedAt: now).isStale)
    }

    func test_offline_captionsHowOldTheNumbersAre() {
        let freshness = AgentCapacityFreshness.offline(capturedAt: now.addingTimeInterval(-2 * 3600))
        XCTAssertEqual(freshness.ageText(now: now, locale: english), "offline · as of 2h ago")
    }

    /// Abbreviated units, the same style the recent-folder rows use — the
    /// caption sits under a name line, not on its own.
    func test_offline_usesAbbreviatedUnits() {
        let cases: [(TimeInterval, String)] = [
            (45 * 60, "offline · as of 45m ago"),
            (3 * 86_400, "offline · as of 3d ago"),
        ]
        for (age, expected) in cases {
            let freshness = AgentCapacityFreshness.offline(capturedAt: now.addingTimeInterval(-age))
            XCTAssertEqual(freshness.ageText(now: now, locale: english), expected)
        }
    }
}
