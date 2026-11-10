import XCTest
@testable import MatronModels

final class BoxAllowancesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func week(_ percent: Int, resetsIn days: Double?) -> [LimitLine] {
        [LimitLine(id: "week_all", label: "Week (all models)", percent: percent,
                   resetsAt: days.map { now.addingTimeInterval($0 * 86_400) })]
    }

    private func reading(_ id: Int64, _ email: String?, _ lines: [LimitLine]) -> BoxAllowanceReading {
        BoxAllowanceReading(boxID: id, accountEmail: email, lines: lines)
    }

    func test_nearLimit_startsAt80Percent() {
        XCTAssertFalse(BoxAllowances.isNearLimit(week(79, resetsIn: 3), now: now))
        XCTAssertTrue(BoxAllowances.isNearLimit(week(80, resetsIn: 3), now: now))
        XCTAssertTrue(BoxAllowances.isNearLimit(week(91, resetsIn: nil), now: now), "no known reset still counts")
    }

    func test_nearLimit_ignoresALineThatHasAlreadyReset() {
        XCTAssertFalse(BoxAllowances.isNearLimit(week(94, resetsIn: -1), now: now))
    }

    func test_nearLimit_ignoresOtherMeters() {
        let fable = [LimitLine(id: "week_fable", label: "Week (Fable)", percent: 99, resetsAt: nil)]
        XCTAssertFalse(BoxAllowances.isNearLimit(fable, now: now))
    }

    func test_mostSpare_ranksByPercentLeftPerDay() throws {
        let spare = try XCTUnwrap(BoxAllowances.mostSpare([
            reading(1, "a@example.com", week(0, resetsIn: 7)),
            reading(2, "b@example.com", week(23, resetsIn: 43.0 / 24)),
        ], now: now))
        XCTAssertEqual(spare.accountEmail, "b@example.com")
        XCTAssertEqual(spare.boxIDs, [2])
        XCTAssertEqual(spare.percentLeft, 77)
        XCTAssertEqual(spare.percentPerDay, 43)
    }

    func test_mostSpare_aResetUnderADayCountsAsAFullDay() throws {
        let spare = try XCTUnwrap(BoxAllowances.mostSpare([
            reading(1, "soon@example.com", week(94, resetsIn: 1.0 / 24)),
            reading(2, "later@example.com", week(0, resetsIn: 7)),
        ], now: now))
        XCTAssertEqual(spare.accountEmail, "later@example.com")
    }

    func test_mostSpare_boxesOnALoginCountOnce_atTheirHighestReading() throws {
        let spare = try XCTUnwrap(BoxAllowances.mostSpare([
            reading(1, "shared@example.com", week(10, resetsIn: 2)),
            reading(2, "shared@example.com", week(30, resetsIn: 2)),
            reading(3, "other@example.com", week(50, resetsIn: 2)),
        ], now: now))
        XCTAssertEqual(spare.boxIDs, [1, 2])
        XCTAssertEqual(spare.percentLeft, 70)
    }

    func test_mostSpare_boxesWithNoLoginStaySeparate() throws {
        let spare = try XCTUnwrap(BoxAllowances.mostSpare([
            reading(1, nil, week(90, resetsIn: 2)),
            reading(2, nil, week(10, resetsIn: 2)),
        ], now: now))
        XCTAssertEqual(spare.boxIDs, [2])
    }

    func test_mostSpare_skipsExpiredAndUnknownResetsAndFullLogins() {
        XCTAssertNil(BoxAllowances.mostSpare([
            reading(1, "old@example.com", week(10, resetsIn: -1)),
            reading(2, "none@example.com", week(10, resetsIn: nil)),
            reading(3, "full@example.com", week(100, resetsIn: 2)),
        ], now: now))
    }

    func test_parse_readsDiskAsOfAndDefaults() {
        let capacity = BoxCapacity.parse(replyObject: [
            "disk": ["free_bytes": 48_318_382_080, "total_bytes": 155_692_564_480],
            "limits": ["as_of": 1_700_000_000_000, "lines": [[String: Any]]()],
            "defaults": ["agent": "codex", "model": "gpt-example", "effort": "xhigh"],
        ])
        XCTAssertEqual(capacity.disk, BoxDisk(freeBytes: 48_318_382_080, totalBytes: 155_692_564_480))
        XCTAssertEqual(capacity.limitsAsOf, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(capacity.defaults, BoxResolvedDefaults(agent: "codex", model: "gpt-example", effort: "xhigh"))
    }

    func test_parse_dropsAMalformedDisk() {
        XCTAssertNil(BoxCapacity.parse(replyObject: ["disk": ["free_bytes": 5, "total_bytes": 1]]).disk)
        XCTAssertNil(BoxCapacity.parse(replyObject: ["disk": ["free_bytes": 5]]).disk)
    }

    func test_diskSizeText() {
        XCTAssertEqual(BoxDisk.sizeText(45 * 1024 * 1024 * 1024), "45G")
        XCTAssertEqual(BoxDisk.sizeText(7_945_689_498), "7.4G")
        XCTAssertEqual(BoxDisk.sizeText(1_979_120_929_996), "1.8T")
        XCTAssertEqual(BoxDisk.sizeText(1_099_404_827_607), "1.0T", "1023.9G carries to the next unit")
    }

    func test_ageText() {
        XCTAssertEqual(BoxAllowances.ageText(since: now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(BoxAllowances.ageText(since: now.addingTimeInterval(-240), now: now), "4 min ago")
        XCTAssertEqual(BoxAllowances.ageText(since: now.addingTimeInterval(-7200), now: now), "2 h ago")
        XCTAssertEqual(BoxAllowances.ageText(since: now.addingTimeInterval(-259_200), now: now), "3 d ago")
    }

    func test_defaultsText() {
        XCTAssertEqual(BoxAllowances.defaultsText(agent: "claude", model: "opus", effort: nil), "Claude · Opus")
        XCTAssertEqual(BoxAllowances.defaultsText(agent: "codex", model: "gpt-example", effort: "xhigh"),
                       "Codex · gpt-example · xhigh")
        XCTAssertEqual(BoxAllowances.defaultsText(agent: "claude", model: nil, effort: nil),
                       "Claude · Claude Code's own model")
    }
}
