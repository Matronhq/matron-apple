import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Pins the show/hide predicate and label wording for the tap-to-compact
/// strip. Mirrors the Android suite so the two clients stay behaviourally
/// identical (same 200k absolute threshold, same copy).
final class CompactContextBannerTests: XCTestCase {
    private func context(tokens: Int) -> SessionStatus.Context {
        SessionStatus.Context(tokens: tokens, window: 1_000_000, pct: tokens / 10_000)
    }

    func test_shouldShow_nilContext_isFalse() {
        XCTAssertFalse(CompactContextBanner.shouldShow(nil))
    }

    func test_shouldShow_exactlyAtThreshold_isFalse() {
        XCTAssertFalse(CompactContextBanner.shouldShow(context(tokens: 200_000)))
    }

    func test_shouldShow_strictlyAboveThreshold_isTrue() {
        XCTAssertTrue(CompactContextBanner.shouldShow(context(tokens: 200_001)))
    }

    func test_shouldShow_wellBelowThreshold_isFalse() {
        XCTAssertFalse(CompactContextBanner.shouldShow(context(tokens: 5_000)))
    }

    func test_title_usesCompactTokens() {
        XCTAssertEqual(
            CompactContextBanner.title(tokens: 265_400),
            "Large conversation (265k tokens) · Tap to compact"
        )
    }

    func test_spokenLabel_usesSpokenTokens() {
        XCTAssertEqual(
            CompactContextBanner.spokenLabel(tokens: 265_400),
            "Large conversation, 265 thousand tokens, tap to compact"
        )
    }
}
