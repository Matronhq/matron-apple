import XCTest
@testable import Matron

/// Pins the formatting of `TimelineItemView.displayName(for:)`. The function
/// is a Phase-2 placeholder that takes the Matrix ID's local part — without
/// the leading `@` sigil — until member events round-trip from the SDK.
final class TimelineItemViewTests: XCTestCase {

    func test_displayName_stripsAtSigil_andServerSuffix() {
        // Regression for bugbot finding #5. The old impl just split on
        // ":" and returned the first component, which left the leading
        // `@` ("@bot:server.com" → "@bot"). The doc-comment promised
        // "the local part", which excludes the sigil.
        XCTAssertEqual(TimelineItemView.displayName(for: "@bot:server.com"), "bot")
    }

    func test_displayName_handlesMissingSigil() {
        // Defensive: senders that arrive without the `@` sigil (test
        // fixtures, malformed events) should still have the server part
        // stripped.
        XCTAssertEqual(TimelineItemView.displayName(for: "bot:server.com"), "bot")
    }

    func test_displayName_returnsInputWhenNoColon() {
        // Genuinely malformed IDs fall through to the original string —
        // better than rendering an empty bubble label.
        XCTAssertEqual(TimelineItemView.displayName(for: "weird"), "weird")
    }

    func test_displayName_handlesAtSigilOnly() {
        // Edge case: just "@" has no local part to extract → fall back
        // to the original input rather than rendering an empty label.
        XCTAssertEqual(TimelineItemView.displayName(for: "@"), "@")
    }
}
