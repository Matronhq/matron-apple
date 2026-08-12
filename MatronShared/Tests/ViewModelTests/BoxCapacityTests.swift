import XCTest
@testable import MatronModels

final class BoxCapacityTests: XCTestCase {
    private func obj(_ json: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
    }

    func test_parse_fullBlock() {
        let c = BoxCapacity.parse(replyObject: obj(#"""
        {"folders":[],
         "activity":{"live_sessions":2,"last_hour":[{"path":"/w","sessions":1}]},
         "limits":{"as_of":1754900000000,"lines":[
            {"id":"session","label":"Current session","percent":39,"resets_at":"2026-08-11T23:59:00Z"},
            {"id":"week","label":"Current week (all models)","percent":66}]},
         "account":{"email":"pat@yearbook.com"}}
        """#))
        XCTAssertEqual(c.liveSessions, 2)
        XCTAssertEqual(c.limitLines.map(\.label), ["Current session", "Current week (all models)"])
        XCTAssertEqual(c.limitLines[0].percent, 39)
        XCTAssertNotNil(c.limitLines[0].resetsAt)
        XCTAssertNil(c.limitLines[1].resetsAt, "missing resets_at parses as nil")
        XCTAssertEqual(c.accountEmail, "pat@yearbook.com")
    }

    func test_parse_missingBlocks_degradeToEmpty() {
        let c = BoxCapacity.parse(replyObject: obj(#"{"folders":[]}"#))
        XCTAssertNil(c.liveSessions)
        XCTAssertEqual(c.limitLines, [])
        XCTAssertNil(c.accountEmail)
    }

    func test_parse_malformedEntries_dropLineNotBlock() {
        let c = BoxCapacity.parse(replyObject: obj(#"""
        {"limits":{"lines":[
            {"id":"ok","label":"Fine","percent":10},
            {"id":"bad","label":"No percent"},
            {"label":"No id","percent":5}]},
         "account":{"email":42},
         "activity":{"live_sessions":"two"}}
        """#))
        XCTAssertEqual(c.limitLines.map(\.id), ["ok"], "lines missing id/label/percent are dropped")
        XCTAssertNil(c.accountEmail, "non-string email → nil")
        XCTAssertNil(c.liveSessions, "non-numeric live_sessions → nil")
    }

    func test_parse_percentClamped() {
        let c = BoxCapacity.parse(replyObject: obj(#"{"limits":{"lines":[{"id":"a","label":"A","percent":-5},{"id":"b","label":"B","percent":5000}]}}"#))
        XCTAssertEqual(c.limitLines.map(\.percent), [0, 999])
    }

    func test_parse_booleanAndFractionalNumbersAreMalformed() {
        let c = BoxCapacity.parse(replyObject: obj(#"""
        {"activity":{"live_sessions":true},
         "limits":{"lines":[
            {"id":"bool","label":"Boolean","percent":true},
            {"id":"frac","label":"Fractional","percent":39.5},
            {"id":"whole","label":"Whole","percent":40.0}]}}
        """#))
        XCTAssertNil(c.liveSessions, "JSON true bridges through NSNumber as 1 — reject it")
        XCTAssertEqual(c.limitLines.map(\.id), ["whole"],
                       "boolean and fractional percents drop the line rather than truncate")
        XCTAssertEqual(c.limitLines[0].percent, 40, "an integral 40.0 is still a whole percent")
    }

    func test_parse_resetsAt_acceptsFractionalAndPlainISO() {
        let c = BoxCapacity.parse(replyObject: obj(#"""
        {"limits":{"lines":[
            {"id":"frac","label":"Fractional","percent":1,"resets_at":"2026-08-12T10:00:00.123Z"},
            {"id":"plain","label":"Plain","percent":2,"resets_at":"2026-08-12T10:00:00Z"},
            {"id":"junk","label":"Junk","percent":3,"resets_at":"tomorrow"}]}}
        """#))
        XCTAssertEqual(c.limitLines.count, 3)
        guard let fractional = c.limitLines[0].resetsAt, let plain = c.limitLines[1].resetsAt else {
            return XCTFail("bridge timestamps carry milliseconds — both forms must parse")
        }
        XCTAssertEqual(fractional.timeIntervalSince1970, plain.timeIntervalSince1970 + 0.123,
                       accuracy: 0.001)
        XCTAssertNil(c.limitLines[2].resetsAt,
                     "an unparseable resets_at drops the caption, not the line")
    }

    func test_resetText_todayVsLater() {
        // Fixed zone *and* locale: the caption's branch and its symbols both
        // depend on them, so an unpinned formatter would read differently on
        // a machine in another time zone or language.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let now = Date(timeIntervalSince1970: 1_754_900_000) // 2026-08-11 08:13 UTC
        let today = now.addingTimeInterval(2 * 3600)
        let nextWeek = now.addingTimeInterval(4 * 86_400)
        XCTAssertEqual(BoxCapacity.resetText(today, now: now, calendar: cal), "resets 10:13 AM",
                       "same-day reset shows time only")
        XCTAssertEqual(BoxCapacity.resetText(nextWeek, now: now, calendar: cal), "resets Aug 15",
                       "later reset shows the date")
        XCTAssertNil(BoxCapacity.resetText(nil))
    }

    // MARK: limitColumns(across:)

    private func capacity(_ lines: [LimitLine]) -> BoxCapacity {
        BoxCapacity(liveSessions: nil, limitLines: lines, accountEmail: nil)
    }

    func test_limitColumns_unionInFirstEncounterOrder() {
        let a = capacity([
            LimitLine(id: "session", label: "Current session", percent: 10, resetsAt: nil),
            LimitLine(id: "week", label: "Current week (all models)", percent: 20, resetsAt: nil),
        ])
        let b = capacity([
            LimitLine(id: "session", label: "Session (renamed)", percent: 30, resetsAt: nil),
            LimitLine(id: "opus", label: "Current week (Opus)", percent: 40, resetsAt: nil),
        ])
        let columns = BoxCapacity.limitColumns(across: [a, b])
        XCTAssertEqual(columns.map(\.id), ["session", "week", "opus"])
        // Label comes from the first box that reported the line.
        XCTAssertEqual(columns.map(\.label),
                       ["Current session", "Current week (all models)", "Current week (Opus)"])
    }

    func test_limitColumns_duplicateIdsWithinOneBoxNotDuplicated() {
        let a = capacity([
            LimitLine(id: "session", label: "First", percent: 1, resetsAt: nil),
            LimitLine(id: "session", label: "Second", percent: 2, resetsAt: nil),
        ])
        XCTAssertEqual(BoxCapacity.limitColumns(across: [a]).map(\.label), ["First"])
    }

    func test_limitColumns_emptyInEmptyOut() {
        XCTAssertTrue(BoxCapacity.limitColumns(across: []).isEmpty)
        XCTAssertTrue(BoxCapacity.limitColumns(across: [capacity([])]).isEmpty)
    }
}
