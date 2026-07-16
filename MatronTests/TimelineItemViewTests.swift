import XCTest
import MatronChat
import MatronDesignSystem
import MatronModels
@testable import Matron

/// Pins the formatting of `TimelineItemView.displayName(for:)`. The function
/// is a Phase-2 placeholder that takes the Matrix ID's local part — without
/// the leading `@` sigil — until member events round-trip from the SDK.
final class TimelineItemViewTests: XCTestCase {

    func test_displayName_stripsAtSigil_andServerSuffix() {
        // Regression for bugbot finding #5. The old impl just split on
        // ":" and returned the first component, which left the leading
        // `@` ("@bot:server.com" → "@bot"). The doc-comment promised
        // "the local part", which excludes the sigil.
        XCTAssertEqual(TimelineItemView.displayName(for: "@bot:server.com"), "bot")
    }

    func test_displayName_handlesMissingSigil() {
        // Defensive: senders that arrive without the `@` sigil (test
        // fixtures, malformed events) should still have the server part
        // stripped.
        XCTAssertEqual(TimelineItemView.displayName(for: "bot:server.com"), "bot")
    }

    func test_displayName_returnsInputWhenNoColon() {
        // Genuinely malformed IDs fall through to the original string —
        // better than rendering an empty bubble label.
        XCTAssertEqual(TimelineItemView.displayName(for: "weird"), "weird")
    }

    func test_displayName_handlesAtSigilOnly() {
        // Edge case: just "@" has no local part to extract → fall back
        // to the original input rather than rendering an empty label.
        XCTAssertEqual(TimelineItemView.displayName(for: "@"), "@")
    }

    // MARK: - shouldRender (round-5 bugbot finding #2)

    /// `TimelineServiceLive.mapVirtual` collapses `dateDivider`,
    /// `readMarker`, and `timelineStart` virtual items into
    /// `.stateChange(text: "")`. The renderer's `.stateChange` branch
    /// wraps the text in a padded `HStack` with `Spacer`s, which produces
    /// a visible 8pt blank row for these placeholders. `shouldRender(_:)`
    /// returns `false` for that case so `body` emits `EmptyView()`. Phase
    /// 3+ can replace this with a real `Kind` case + visual treatment.
    func test_shouldRender_returnsFalse_forEmptyStateChange() {
        let item = TimelineItem(
            id: "virtual-1",
            sender: "",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .stateChange(text: ""),
            isOwn: false,
            sendState: .sent
        )
        XCTAssertFalse(TimelineItemView.shouldRender(item),
                       "virtual placeholders must skip rendering to avoid blank padded rows")
    }

    /// `shouldRender` now hides ALL state-change rows (membership joins,
    /// profile updates, generic "Room state changed", etc.) — bot-first
    /// chats don't want that meta noise interleaved with the
    /// conversation. Phase 7 polish can bring back a metadata-events
    /// toggle. Empty-text variant (the `mapVirtual` placeholder) was
    /// already hidden; this generalises to the populated variants too.
    func test_shouldRender_returnsFalse_forPopulatedStateChange() {
        let item = TimelineItem(
            id: "join-1",
            sender: "@alice:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .stateChange(text: "alice joined"),
            isOwn: false,
            sendState: .sent
        )
        XCTAssertFalse(TimelineItemView.shouldRender(item),
                       "populated state-change rows are meta-noise in a bot chat — hide them")
    }

    // MARK: - SendStateGlyph mapping
    // The `TimelineSendState → SendStateGlyph` bridge is exercised by
    // `MatronShared/Tests/DesignSystemSnapshotTests/StateBridgesTests`.
    // The view itself just calls `SendStateGlyph.from(_:)`, so there's
    // no platform-specific mapping left to pin here.

    /// Sanity: text / image / file / unknown kinds always render.

    func test_shouldRender_returnsFalse_forAskUserAnswer() {
        // Phase 5: button responses are pendingAsk bookkeeping, never
        // rendered (Matron X hides them too).
        let item = TimelineItem(
            id: "a", sender: "@me:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .askUserAnswer(promptEventID: "$1", selectedValues: ["yes"]),
            isOwn: true, sendState: .sent
        )
        XCTAssertFalse(TimelineItemView.shouldRender(item),
                       "button-response answers must stay hidden")
    }

    func test_shouldRender_returnsTrue_forContentKinds() {
        let kinds: [TimelineItem.Kind] = [
            .text(body: "hi", formattedHTML: nil),
            .image(url: nil, caption: nil, sizeBytes: nil),
            .file(url: nil, filename: "x.pdf", caption: nil, sizeBytes: nil),
            .unknown(eventType: "m.audio"),
        ]
        for kind in kinds {
            let item = TimelineItem(
                id: "k", sender: "@a:s",
                timestamp: Date(timeIntervalSince1970: 0),
                kind: kind, isOwn: false, sendState: .sent
            )
            XCTAssertTrue(TimelineItemView.shouldRender(item),
                          "content kind \(kind) must render")
        }
    }
}
