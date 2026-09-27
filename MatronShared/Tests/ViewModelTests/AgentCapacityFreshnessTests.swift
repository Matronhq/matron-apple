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

    /// Clock skew between the box's journal and this device can stamp a
    /// capture at or ahead of now. "as of in 3 hr" — and the formatter's
    /// "in 0s" for a dead heat — would read as promises about the future
    /// rather than disclaimers about the past.
    func test_offline_neverCaptionsACaptureAsAhead() {
        for skew in [3 * 3600.0, 0] {
            let freshness = AgentCapacityFreshness.offline(capturedAt: now.addingTimeInterval(skew))
            let caption = freshness.ageText(now: now, locale: english)
            XCTAssertEqual(caption, "offline · as of just now")
            XCTAssertFalse(caption?.contains(" in ") ?? true, "never phrased as a future moment")
        }
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

    // MARK: Reported (a connected box that did not answer this visit)

    func test_reported_isStale() {
        XCTAssertTrue(AgentCapacityFreshness.reported(at: now).isStale)
    }

    /// The box is connected, so "offline" would be false — the caption only
    /// says how old the box's own last report is.
    func test_reported_captionsTheReportAgeWithoutClaimingOffline() {
        let freshness = AgentCapacityFreshness.reported(at: now.addingTimeInterval(-45 * 60))
        XCTAssertEqual(freshness.ageText(now: now, locale: english), "as of 45m ago")
        let skewed = AgentCapacityFreshness.reported(at: now.addingTimeInterval(60))
        XCTAssertEqual(skewed.ageText(now: now, locale: english), "as of just now")
    }
}
