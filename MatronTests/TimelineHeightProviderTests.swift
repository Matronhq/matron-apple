import XCTest
import MatronModels
@testable import Matron

/// Spec §4: cache invalidation on width or Dynamic Type change, with a fake
/// measurer; precompute fills the cache off the main thread.
@MainActor
final class TimelineHeightProviderTests: XCTestCase {
    final class FakeMeasurer: TimelineRowMeasuring, @unchecked Sendable {
        var mainCalls = 0
        let backgroundCalls = LockedCounter()
        func backgroundTextRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender? {
            backgroundCalls.increment()
            if content.body.contains("NEEDS-MAIN") { return nil }
            return TextRowRender(content: content, segments: [], layout: .fixed(height: CGFloat(content.body.count)),
                                 timestampText: "", style: style)
        }
        func measure(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement {
            mainCalls += 1
            return .hosted(width / 10 + style.bodySize)
        }
        func footerHeight(label: String, width: CGFloat, style: TimelineTextStyle) -> CGFloat { 30 }
    }

    final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let large = TimelineStyleFixture.large
    private let huge = TimelineTextStyle(sizeCategory: .accessibilityExtraLarge)

    private func text(_ id: String, _ body: String) -> TextRowContent {
        TextRowContent(itemID: id, body: body, isOwn: false, sendState: .sent,
                       timestamp: Date(timeIntervalSince1970: 0), avatarSender: nil, senderLabel: "matron", pills: [])
    }

    private func provider(_ measurer: FakeMeasurer) -> TimelineHeightProvider {
        TimelineHeightProvider(roomID: "!r", cache: TimelineMeasureCache(countLimit: 100), measurer: measurer)
    }

    func test_secondLookup_isACacheHit() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "hello"))
        _ = heights.measurement(row, width: 390, style: large)
        _ = heights.measurement(row, width: 390, style: large)
        XCTAssertEqual(fake.mainCalls, 1)
    }

    func test_widthChange_isAMiss() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "hello"))
        _ = heights.measurement(row, width: 390, style: large)
        XCTAssertEqual(heights.measurement(row, width: 600, style: large).height, 60 + 17)
        XCTAssertEqual(fake.mainCalls, 2)
    }

    func test_dynamicTypeChange_isAMiss() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "hello"))
        _ = heights.measurement(row, width: 390, style: large)
        _ = heights.measurement(row, width: 390, style: huge)
        XCTAssertEqual(fake.mainCalls, 2)
    }

    func test_contentChange_underTheSameID_isAMiss() {
        let fake = FakeMeasurer(), heights = provider(fake)
        _ = heights.measurement(.text(text("1", "hello")), width: 390, style: large)
        _ = heights.measurement(.text(text("1", "hello, edited")), width: 390, style: large)
        XCTAssertEqual(fake.mainCalls, 2)
    }

    func test_precompute_fillsTheCache_andReportsMainThreadOnlyRows() async {
        let fake = FakeMeasurer(), heights = provider(fake)
        let rows = [text("1", "one"), text("2", "NEEDS-MAIN table"), text("3", "three")]
        let needsMain = await heights.precompute(rows, width: 390, style: large)
        XCTAssertEqual(needsMain, ["2"])
        XCTAssertEqual(fake.backgroundCalls.count, 3)
        XCTAssertEqual(heights.cached(.text(rows[0]), width: 390, style: large)?.height, 3)
        XCTAssertNil(heights.cached(.text(rows[1]), width: 390, style: large))
        let missing = heights.missingText(in: rows.map(TimelineRowContent.text), width: 390, style: large,
                                          excluding: needsMain)
        XCTAssertTrue(missing.isEmpty, "precomputed rows and main-thread-only rows are both excluded")
        XCTAssertEqual(fake.mainCalls, 0)
    }

    func test_storeHostedHeight_overridesTheEntry() {
        let fake = FakeMeasurer(), heights = provider(fake)
        let row = TimelineRowContent.text(text("1", "x"))
        _ = heights.measurement(row, width: 390, style: large)
        heights.storeHostedHeight(123, for: row, width: 390, style: large)
        XCTAssertEqual(heights.cached(row, width: 390, style: large)?.height, 123)
    }
}

enum TimelineStyleFixture {
    static let large = TimelineTextStyle(sizeCategory: .large)
}
