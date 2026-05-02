import XCTest
@testable import MatronChat

final class ChatRecencyGroupTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1745000000)
    let calendar = Calendar(identifier: .gregorian)

    func test_buckets_today() {
        let date = now.addingTimeInterval(-3600)
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .today)
    }

    func test_buckets_yesterday() {
        let date = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .yesterday)
    }

    func test_buckets_lastSevenDays() {
        let date = calendar.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .lastSevenDays)
    }

    func test_buckets_earlier() {
        let date = calendar.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(ChatRecencyGroup.bucket(date, now: now, calendar: calendar), .earlier)
    }
}
