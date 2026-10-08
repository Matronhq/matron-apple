import XCTest
@testable import MatronDesignSystem

/// The "Latest briefing" card's words: the age in the heading and the
/// two-line preview (its first two non-blank lines, as plain text).
final class BriefingFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testHeadingNamesTheAge() {
        XCTAssertEqual(BriefingFormat.heading(createdAt: nil, now: now), "Latest briefing")
        XCTAssertEqual(BriefingFormat.heading(createdAt: now.addingTimeInterval(-20), now: now),
                       "Latest briefing · just now")
        // A briefing stamped ahead of this device's clock is not "in 5 seconds".
        XCTAssertEqual(BriefingFormat.age(now.addingTimeInterval(5), now: now), "just now")
        let fiveMinutes = BriefingFormat.age(now.addingTimeInterval(-300), now: now)
        XCTAssertTrue(fiveMinutes.contains("5"), fiveMinutes)
        XCTAssertTrue(fiveMinutes.contains("minute"), "full units style: \(fiveMinutes)")
    }

    /// Web's rule: the first two non-blank lines, each plain text, each
    /// its own line (heading first, then the first body line).
    func testPreviewIsTheFirstTwoNonBlankLinesAsPlainText() {
        XCTAssertEqual(BriefingFormat.previewLines("## Morning sweep\n\nThree missions running, **two items** wait.\nMore."),
                       ["Morning sweep", "Three missions running, two items wait."])
        // web's own test case
        XCTAssertEqual(BriefingFormat.previewLines("## Status\n\n- one_two **bold**\n- [x](https://x.example)\n\nmore"),
                       ["Status", "one_two bold"])
    }

    func testPreviewDropsBlockSyntax() {
        let body = """
        ## Sweep, 09:00

        - **Projects**: 3 moving, [#12](matron://item/12) waits on you
        * Boxes all up
        1. Next: ship it
        > quoted
        ---
        | a | b |
        |---|---|
        ```
        code
        ```
        """
        XCTAssertEqual(BriefingFormat.previewLines(body, count: 10),
                       ["Sweep, 09:00", "Projects: 3 moving, #12 waits on you", "Boxes all up", "Next: ship it",
                        "quoted", "| a | b |", "code"])
    }

    func testPreviewOfPlainTextIsUnchanged() {
        XCTAssertEqual(BriefingFormat.previewLines("All quiet."), ["All quiet."])
        XCTAssertEqual(BriefingFormat.previewLines(""), [])
        XCTAssertEqual(BriefingFormat.previewLines("#hashtag 2024 results"), ["hashtag 2024 results"])
        XCTAssertEqual(BriefingFormat.previewLines("\n\n  spaced   out  \n"), ["spaced out"])
    }
}
