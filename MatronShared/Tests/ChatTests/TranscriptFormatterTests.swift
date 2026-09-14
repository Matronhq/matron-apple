import XCTest
@testable import MatronChat

final class TranscriptFormatterTests: XCTestCase {

    private let gb = Locale(identifier: "en_GB")
    private let us = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-05 14:33:00 UTC
    private let t1 = Date(timeIntervalSince1970: 1_788_618_780)
    /// 2026-09-05 14:35:00 UTC
    private let t2 = Date(timeIntervalSince1970: 1_788_618_900)

    func test_singleEntry_enGB() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Claude", text: "hello")],
            locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Claude: hello")
    }

    func test_singleEntry_enUS() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Me", text: "hello")],
            locale: us, timeZone: utc)
        // en_US short date/time — narrow no-break space before PM on recent
        // Foundation; normalise to a plain space before asserting.
        let normalised = out.replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(normalised, "[9/5/26, 2:33 PM] Me: hello")
    }

    func test_entriesSeparatedBySingleNewline_noTrailingNewline() {
        let out = TranscriptFormatter.format([
            TranscriptEntry(timestamp: t1, name: "Me", text: "one"),
            TranscriptEntry(timestamp: t2, name: "Claude", text: "two"),
        ], locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Me: one\n[05/09/2026, 14:35] Claude: two")
        XCTAssertFalse(out.hasSuffix("\n"))
    }

    func test_multiLineTextContinuesUnprefixed() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Claude", text: "line 42 expects\nthe fixture is unsorted")],
            locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Claude: line 42 expects\nthe fixture is unsorted")
    }

    func test_leadingAndTrailingNewlinesTrimmedPerEntry_innerWhitespaceKept() {
        let out = TranscriptFormatter.format(
            [TranscriptEntry(timestamp: t1, name: "Me", text: "\n\n  two  spaces\n\n")],
            locale: gb, timeZone: utc)
        XCTAssertEqual(out, "[05/09/2026, 14:33] Me:   two  spaces")
    }

    func test_emptyList_isEmptyString() {
        XCTAssertEqual(TranscriptFormatter.format([], locale: gb, timeZone: utc), "")
    }
}
