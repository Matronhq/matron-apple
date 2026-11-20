import XCTest
@testable import MatronDesignSystem

/// Comment captions' dates ("5 min. ago") come from one shared formatter
/// rather than a new one per caption.
final class ItemDetailRelativeDateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCaptionsReadAsBefore() {
        func fresh(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: now)
        }
        XCTAssertEqual(ItemDetailView.relativeDate(now.addingTimeInterval(-10), now: now), "now")
        for age: TimeInterval in [90, 5 * 60, 3 * 3600, 2 * 86400] {
            let date = now.addingTimeInterval(-age)
            XCTAssertEqual(ItemDetailView.relativeDate(date, now: now), fresh(date))
        }
    }

    /// A 200-comment thread's captions, against making a formatter for
    /// each one as the page used to.
    func testAThreadsCaptionsAreCheap() {
        let dates = (0..<200).map { now.addingTimeInterval(-Double($0 * 600 + 120)) }
        func time(_ work: () -> Void) -> TimeInterval {
            let start = Date(); work(); return Date().timeIntervalSince(start)
        }
        _ = ItemDetailView.relativeDate(dates[0], now: now)
        let perCaption = time {
            for date in dates {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                _ = formatter.localizedString(for: date, relativeTo: now)
            }
        }
        let shared = time { for date in dates { _ = ItemDetailView.relativeDate(date, now: now) } }
        print("200 captions: new formatter each \(Int(perCaption * 1_000_000)) µs, shared \(Int(shared * 1_000_000)) µs")
        XCTAssertLessThan(shared, perCaption)
    }
}
