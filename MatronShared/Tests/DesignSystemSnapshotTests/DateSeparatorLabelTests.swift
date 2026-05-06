import XCTest
@testable import MatronDesignSystem

/// Pins `DateSeparatorLabel.format(_:now:calendar:)` so the chat
/// timeline's separator copy doesn't silently drift across locales /
/// timezones. Tests inject an explicit `Calendar` so the assertions
/// don't depend on the host runtime.
final class DateSeparatorLabelTests: XCTestCase {
    /// UTC + en_GB so weekday names and the medium-style date format
    /// resolve deterministically. Locale matters for the medium-date
    /// branch ("5 Mar 2026" vs "Mar 5, 2026") and for the weekday
    /// names returned by `EEEE`.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    /// Anchor a deterministic "now" so all branches resolve relative
    /// to a known calendar day. Wednesday 2026-03-04 12:00 UTC.
    private let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 4; c.hour = 12
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func test_today() {
        // Same calendar day as `now` (just earlier in the morning) →
        // "Today". Matches Element / iMessage conventions.
        let date = calendar.date(byAdding: .hour, value: -3, to: now)!
        XCTAssertEqual(
            DateSeparatorLabel.format(date, now: now, calendar: calendar),
            "Today"
        )
    }

    func test_yesterday() {
        let date = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(
            DateSeparatorLabel.format(date, now: now, calendar: calendar),
            "Yesterday"
        )
    }

    func test_weekday_within_lastSevenDays() {
        // Three days back from Wednesday is the previous Sunday.
        let date = calendar.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(
            DateSeparatorLabel.format(date, now: now, calendar: calendar),
            "Sunday"
        )
    }

    func test_weekday_atSixDayBoundary_stillWeekday() {
        // The trailing-week branch fires for `1 < days < 7`. Six full
        // days back must still resolve to a weekday — pinning the
        // boundary so a future refactor doesn't silently drop it.
        let date = calendar.date(byAdding: .day, value: -6, to: now)!
        // Wednesday 2026-03-04 minus six days = Thursday 2026-02-26.
        XCTAssertEqual(
            DateSeparatorLabel.format(date, now: now, calendar: calendar),
            "Thursday"
        )
    }

    func test_olderThanWeek_fallsBack_toLocalisedDate() {
        // Eight days back from 2026-03-04 12:00 UTC → 2026-02-24
        // 12:00 UTC. Past the trailing-week window, so the medium-
        // style date kicks in. Medium-style en_GB: "24 Feb 2026".
        // Pinning the exact string is fine since we own the locale
        // via the injected calendar.
        let date = calendar.date(byAdding: .day, value: -8, to: now)!
        let formatted = DateSeparatorLabel.format(date, now: now, calendar: calendar)
        XCTAssertEqual(formatted, "24 Feb 2026")
    }
}
