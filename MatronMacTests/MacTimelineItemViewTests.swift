#if os(macOS)
import XCTest
import MatronChat
import MatronDesignSystem
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

    func test_shouldRender_returnsFalse_forPopulatedStateChange() {
        let item = TimelineItem(
            id: "join-1",
            sender: "@alice:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .stateChange(text: "alice joined"),
            isOwn: false,
            sendState: .sent
        )
        XCTAssertFalse(MacTimelineItemView.shouldRender(item),
                       "populated state-change rows are meta-noise in a bot chat — hide them")
    }

    // MARK: - SendStateGlyph mapping
    // The `TimelineSendState → SendStateGlyph` bridge is exercised by
    // `MatronShared/Tests/DesignSystemSnapshotTests/StateBridgesTests`.
    // The Mac view calls `SendStateGlyph.from(_:)` directly, so there's
    // no Mac-specific mapping left to pin here.


    func test_shouldRender_returnsFalse_forAskUserAnswer() {
        // Phase 5: button responses are pendingAsk bookkeeping, never
        // rendered (Matron X hides them too).
        let item = TimelineItem(
            id: "a", sender: "@me:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .askUserAnswer(promptEventID: "$1", selectedValues: ["yes"]),
            isOwn: true, sendState: .sent
        )
        XCTAssertFalse(MacTimelineItemView.shouldRender(item),
                       "button-response answers must stay hidden")
    }

    func test_shouldRender_returnsTrue_forContentKinds() {
        let kinds: [TimelineItem.Kind] = [
            .text(body: "hi", formattedHTML: nil),
            .image(url: nil, caption: nil, sizeBytes: nil, expired: false),
            .file(url: nil, filename: "x.pdf", caption: nil, sizeBytes: nil, expired: false),
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

    // MARK: - avatarSender (mirrors iOS TimelineItemViewTests)

    func test_avatarSender_ownMessage_isNil() {
        let item = TimelineItem(
            id: "1", sender: "dev-2", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: true, sendState: .sent
        )
        XCTAssertNil(MacTimelineItemView.avatarSender(for: item, hasMultipleSenders: true))
    }

    func test_avatarSender_singleSenderRoom_isNil() {
        let item = TimelineItem(
            id: "1", sender: "matron", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false, sendState: .sent
        )
        XCTAssertNil(MacTimelineItemView.avatarSender(for: item, hasMultipleSenders: false))
    }

    func test_avatarSender_multiSenderRoom_returnsSenderName() {
        let item = TimelineItem(
            id: "1", sender: "dev-2", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false, sendState: .sent
        )
        XCTAssertEqual(MacTimelineItemView.avatarSender(for: item, hasMultipleSenders: true), "dev-2")
    }

    /// Render-side twin of the `ChatViewModel.hasMultipleSenders`
    /// ephemeral-row exclusion (Cursor Bugbot, PR #141): the mid-turn
    /// streaming placeholder row ("eph:"-id, `.text` kind, hardcoded
    /// sender "agent") must not get an avatar even when the room is
    /// genuinely multi-sender.
    func test_avatarSender_ephemeralStreamingPlaceholder_isNil_evenInMultiSenderRoom() {
        let item = TimelineItem(
            id: "eph:1", sender: "agent", timestamp: .now,
            kind: .text(body: "partial reply…", formattedHTML: nil), isOwn: false, sendState: .sent
        )
        XCTAssertNil(MacTimelineItemView.avatarSender(for: item, hasMultipleSenders: true))
    }
}
#endif
