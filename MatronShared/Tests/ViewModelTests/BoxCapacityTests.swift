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

    func test_resetText_todayVsLater() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_754_900_000) // 2026-08-11 UTC
        let today = now.addingTimeInterval(2 * 3600)
        let nextWeek = now.addingTimeInterval(4 * 86_400)
        XCTAssertTrue(BoxCapacity.resetText(today, now: now, calendar: cal)!.hasPrefix("resets "))
        XCTAssertFalse(BoxCapacity.resetText(today, now: now, calendar: cal)!.contains("Aug"),
                       "same-day reset shows time only")
        XCTAssertTrue(BoxCapacity.resetText(nextWeek, now: now, calendar: cal)!.contains("Aug"),
                      "later reset shows the date")
        XCTAssertNil(BoxCapacity.resetText(nil))
    }
}
