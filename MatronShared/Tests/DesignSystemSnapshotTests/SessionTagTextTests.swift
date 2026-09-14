import XCTest
@testable import MatronDesignSystem

/// Pins `SessionTagText.plainLabel`'s room-first fallback (fix round 2,
/// H3; fix round 3, N1/N2) — a plain XCTest, no snapshots, since the
/// method returns a `String?` rather than a `Text`. Without this, H3
/// (VoiceOver speaking box names instead of letters) and N2 (the
/// room-branch threshold matching `room(...)`'s own `count >= 2` gate)
/// would both revert silently green.
final class SessionTagTextTests: XCTestCase {
    func test_roomWithTwoOrMoreNames_joinsThemWithComma() {
        XCTAssertEqual(
            SessionTagText.plainLabel(boxName: "solo", sessionShort: nil, roomBoxNames: ["dev-1", "dev-2"]),
            "dev-1, dev-2")
        XCTAssertEqual(
            SessionTagText.plainLabel(boxName: "solo", sessionShort: "bc", roomBoxNames: ["dev-1", "dev-2", "dev-3"]),
            "dev-1, dev-2, dev-3, bc")
    }

    func test_singleBox_usesBoxNameNotLetter() {
        XCTAssertEqual(SessionTagText.plainLabel(boxName: "dev-2", sessionShort: nil), "dev-2")
        XCTAssertEqual(SessionTagText.plainLabel(boxName: "dev-2", sessionShort: "bc"), "dev-2, bc")
    }

    /// N2: `roomBoxNames` with exactly ONE entry must fall through to the
    /// single-box branch — the visual `room(...)` Text run requires at
    /// least 2 names and falls back to `run(...)` (i.e. `boxName`) below
    /// that, so this must agree or VoiceOver speaks a "room" the eye
    /// never sees.
    func test_singleRoomBoxName_fallsThroughToBoxName() {
        XCTAssertEqual(
            SessionTagText.plainLabel(boxName: "dev-2", sessionShort: "bc", roomBoxNames: ["dev-2"]),
            "dev-2, bc")
    }

    func test_sessionShortOnly_noBoxName() {
        XCTAssertEqual(SessionTagText.plainLabel(boxName: nil, sessionShort: "bc"), "bc")
    }

    func test_nothingToShow_returnsNil() {
        XCTAssertNil(SessionTagText.plainLabel(boxName: nil, sessionShort: nil))
    }
}
