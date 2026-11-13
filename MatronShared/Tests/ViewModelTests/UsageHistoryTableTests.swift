import XCTest
@testable import MatronModels

final class UsageHistoryTableTests: XCTestCase {
    /// Friday 9 January 2026, 12:00 UTC. Its week starts Monday 5 January.
    private let now = Date(timeIntervalSince1970: 1_767_960_000)
    private var monday: Date { Date(timeIntervalSince1970: 1_767_571_200) }

    private func week(_ unused: Int, daysFromMonday days: Double) -> UsageWeek {
        UsageWeek(resetsAt: monday.addingTimeInterval(days * 86_400), unused: unused, peak: 100 - unused,
                  lastReadingAt: nil)
    }

    private func account(_ id: String, email: String? = nil, boxes: [String] = ["box-a"],
                         primary: [UsageWeek], fable: [UsageWeek]? = nil) -> UsageAccount {
        var meters = [UsageMeter(id: "week_all", label: "Week (all models)", isPrimary: true, current: nil,
                                 weeks: primary)]
        if let fable {
            meters.append(UsageMeter(id: "week_fable", label: "Week (Fable)", isPrimary: false, current: nil,
                                     weeks: fable))
        }
        return UsageAccount(id: id, agent: "claude", email: email, boxes: boxes, meters: meters)
    }

    private let primary = UsageMeterChoice(id: UsageMeterChoice.primaryID, title: "All models")

    func test_columnsAreMondaysOldestFirst_endingWithThisWeek() {
        let table = UsageHistoryTable.build(UsageHistory(accounts: []), choice: primary, weeks: 3, now: now)
        XCTAssertEqual(table.columns, [monday.addingTimeInterval(-14 * 86_400),
                                       monday.addingTimeInterval(-7 * 86_400), monday])
        XCTAssertTrue(table.rows.isEmpty)
        XCTAssertEqual(table.columnAverages, [nil, nil, nil])
    }

    func test_aWeekSitsInTheCalendarWeekItResetIn() {
        // Resets on Wednesdays: this week's reset has passed, last week's too.
        let history = UsageHistory(accounts: [
            account("a", email: "alice@example.com", boxes: ["box-a", "box-b"],
                    primary: [week(28, daysFromMonday: 2), week(40, daysFromMonday: -5)]),
        ])
        let table = UsageHistoryTable.build(history, choice: primary, weeks: 3, now: now)
        XCTAssertEqual(table.rows.map(\.title), ["alice@example.com"])
        XCTAssertEqual(table.rows[0].subtitle, "Claude · 2 boxes")
        XCTAssertEqual(table.rows[0].cells.map { $0?.unused }, [nil, 40, 28])
        XCTAssertEqual(table.rows[0].averageUnused, 34)
        XCTAssertEqual(table.rows[0].latest?.unused, 28)
    }

    func test_columnAveragesSkipAccountsWithNoReading() {
        let history = UsageHistory(accounts: [
            account("a", primary: [week(10, daysFromMonday: 1), week(50, daysFromMonday: -6)]),
            account("b", primary: [week(31, daysFromMonday: 3)]),
        ])
        let table = UsageHistoryTable.build(history, choice: primary, weeks: 2, now: now)
        XCTAssertEqual(table.columnAverages, [50, 21])
    }

    func test_aModelMeterListsOnlyAccountsThatHaveIt() {
        let history = UsageHistory(accounts: [
            account("a", primary: [week(10, daysFromMonday: 1)], fable: [week(90, daysFromMonday: 1)]),
            account("b", primary: [week(31, daysFromMonday: 3)]),
        ])
        let choices = UsageHistoryTable.choices(for: history)
        XCTAssertEqual(choices.map(\.title), ["All models", "Fable"])
        let table = UsageHistoryTable.build(history, choice: choices[1], weeks: 1, now: now)
        XCTAssertEqual(table.rows.map(\.id), ["a"])
        XCTAssertEqual(table.rows[0].cells.map { $0?.unused }, [90])
    }

    func test_anAccountWithNoLoginIsNamedAfterItsBox() {
        let lone = account("claude:device:7", boxes: ["box-c"], primary: [])
        XCTAssertEqual(lone.title, "box-c")
        XCTAssertEqual(lone.subtitle, "Claude")
        let gone = UsageAccount(id: "codex:device:9", agent: "codex", email: nil, boxes: [], meters: [])
        XCTAssertEqual(gone.title, "Removed box")
        XCTAssertEqual(gone.subtitle, "Codex")
    }

    func test_parseReadsAccountsMetersAndWeeks() throws {
        let object: [String: Any] = ["now": 1, "weeks": 12, "accounts": [
            ["key": "claude:login:alice@example.com", "agent": "claude", "email": "alice@example.com",
             "boxes": ["box-a"],
             "meters": [
                ["id": "week_all", "label": "Week (all models)", "primary": true, "average_unused": 28,
                 "current": ["resets_at": "2026-01-12T12:00:00.000Z", "percent": 8, "unused": 92,
                             "as_of": 1_767_900_000_000],
                 "windows": [
                    ["resets_at": "2025-12-29T12:00:00.000Z", "percent": 60, "unused": 40, "peak": 61,
                     "first_at": 1, "last_at": 1_766_900_000_000],
                    ["resets_at": "2026-01-05T12:00:00.000Z", "percent": 72, "unused": 28, "peak": 72,
                     "first_at": 1, "last_at": 2],
                    ["resets_at": "not a date", "unused": 5],
                 ]],
                ["label": "no id"],
             ]],
            ["agent": "claude"],
        ]]
        let history = try XCTUnwrap(UsageHistory.parse(object))
        XCTAssertEqual(history.accounts.count, 1)
        let meter = try XCTUnwrap(history.accounts[0].meters.first)
        XCTAssertEqual(history.accounts[0].meters.count, 1)
        XCTAssertTrue(meter.isPrimary)
        XCTAssertEqual(meter.weeks.map(\.unused), [28, 40], "newest first")
        XCTAssertEqual(meter.weeks[1].peak, 61)
        XCTAssertEqual(meter.current?.unused, 92)
        XCTAssertEqual(meter.current?.asOf, Date(timeIntervalSince1970: 1_767_900_000))
        XCTAssertNil(UsageHistory.parse(["error": "not_found"]))
    }

    func test_tintGrowsWithWhatWasLeftUnused() {
        XCTAssertEqual(UsageHistoryTable.tintOpacity(unused: 0), 0.10, accuracy: 0.001)
        XCTAssertEqual(UsageHistoryTable.tintOpacity(unused: 100), 0.85, accuracy: 0.001)
        XCTAssertEqual(UsageHistoryTable.tintOpacity(unused: 140), 0.85, accuracy: 0.001)
    }
}
