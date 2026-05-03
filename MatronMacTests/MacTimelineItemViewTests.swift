#if os(macOS)
import XCTest
import MatronChat
import MatronModels
@testable import MatronMac

/// Mac mirror of `MatronTests/TimelineItemViewTests`. The Mac
/// `MacTimelineItemView` is a separate type from the iOS one (per-platform
/// glue mirrors the rest of the apps), so it gets its own coverage.
final class MacTimelineItemViewTests: XCTestCase {

    // MARK: - shouldRender (round-5 bugbot finding #2)

    /// Mac mirror of the iOS round-5 finding #2 fix. See iOS
    /// `TimelineItemViewTests.test_shouldRender_returnsFalse_forEmptyStateChange`
    /// for the full rationale — virtual placeholders (`dateDivider`,
    /// `readMarker`, `timelineStart`) collapse to `.stateChange(text: "")`
    /// in `mapVirtual`, and the renderer must short-circuit them to
    /// `EmptyView()` so they don't show as 8pt blank rows.
    func test_shouldRender_returnsFalse_forEmptyStateChange() {
        let item = TimelineItem(
            id: "virtual-1",
            sender: "",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .stateChange(text: ""),
            isOwn: false,
            sendState: .sent
        )
        XCTAssertFalse(MacTimelineItemView.shouldRender(item),
                       "virtual placeholders must skip rendering to avoid blank padded rows")
    }

    func test_shouldRender_returnsTrue_forPopulatedStateChange() {
        let item = TimelineItem(
            id: "join-1",
            sender: "@alice:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .stateChange(text: "alice joined"),
            isOwn: false,
            sendState: .sent
        )
        XCTAssertTrue(MacTimelineItemView.shouldRender(item),
                      "populated state-change rows are real events and must render")
    }

    func test_shouldRender_returnsTrue_forContentKinds() {
        let kinds: [TimelineItem.Kind] = [
            .text(body: "hi", formattedHTML: nil),
            .image(url: nil, caption: nil, sizeBytes: nil),
            .file(url: nil, filename: "x.pdf", sizeBytes: nil),
            .unknown(eventType: "m.audio"),
        ]
        for kind in kinds {
            let item = TimelineItem(
                id: "k", sender: "@a:s",
                timestamp: Date(timeIntervalSince1970: 0),
                kind: kind, isOwn: false, sendState: .sent
            )
            XCTAssertTrue(MacTimelineItemView.shouldRender(item),
                          "content kind \(kind) must render")
        }
    }
}
#endif
