import XCTest
import MatronChat
import MatronDesignSystem
import MatronEvents
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
            XCTAssertTrue(TimelineItemView.shouldRender(item),
                          "content kind \(kind) must render")
        }
    }

    /// The agent-spawn consent card and its resolution are both visible
    /// rows: the card is the ask itself, and the outcome row is where a
    /// started spawn offers a way into the room it created. Neither may
    /// join the hidden-kinds list.
    func test_shouldRender_returnsTrue_forSpawnKinds() {
        let request = AgentSpawnRequest(
            requestID: "spawn-1", fromDeviceID: 4, fromName: "dev-2",
            targetDeviceID: 7, targetName: "dev-6",
            workdir: "/srv/app", task: "Rebase and push")
        let outcome = SpawnOutcome(requestID: "spawn-1", outcome: "started", roomID: "room-9")
        let kinds: [TimelineItem.Kind] = [
            .agentSpawnRequest(eventID: "11", request),
            .spawnOutcomeRow(eventID: "12", outcome),
        ]
        for kind in kinds {
            let item = TimelineItem(
                id: "k", sender: "journal",
                timestamp: Date(timeIntervalSince1970: 0),
                kind: kind, isOwn: false, sendState: .sent
            )
            XCTAssertTrue(TimelineItemView.shouldRender(item),
                          "spawn kind \(kind) must render")
        }
    }

    // MARK: - avatarSender

    /// Own messages never get an avatar, even in a multi-sender room.
    func test_avatarSender_ownMessage_isNil() {
        let item = TimelineItem(
            id: "1", sender: "dev-2", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: true, sendState: .sent
        )
        XCTAssertNil(TimelineItemView.avatarSender(for: item, hasMultipleSenders: true))
    }

    /// A 1:1 chat (single bot) must not show an avatar even on its
    /// non-own messages — this is the "zero layout change" contract.
    func test_avatarSender_singleSenderRoom_isNil() {
        let item = TimelineItem(
            id: "1", sender: "matron", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false, sendState: .sent
        )
        XCTAssertNil(TimelineItemView.avatarSender(for: item, hasMultipleSenders: false))
    }

    /// The multi-agent case: non-own message in a room with >=2 distinct
    /// senders gets the sender's name back for `MessageBubble`.
    func test_avatarSender_multiSenderRoom_returnsSenderName() {
        let item = TimelineItem(
            id: "1", sender: "dev-2", timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil), isOwn: false, sendState: .sent
        )
        XCTAssertEqual(TimelineItemView.avatarSender(for: item, hasMultipleSenders: true), "dev-2")
    }

    /// Render-side twin of the `ChatViewModel.hasMultipleSenders`
    /// ephemeral-row exclusion (Cursor Bugbot, PR #141): the mid-turn
    /// streaming placeholder row ("eph:"-id, `.text` kind, hardcoded
    /// sender "agent") must not get an avatar even when the room is
    /// genuinely multi-sender — otherwise the in-flight bubble draws
    /// the wrong-coloured circle and jumps to the real one once the
    /// durable row lands.
    func test_avatarSender_ephemeralStreamingPlaceholder_isNil_evenInMultiSenderRoom() {
        let item = TimelineItem(
            id: "eph:1", sender: "agent", timestamp: .now,
            kind: .text(body: "partial reply…", formattedHTML: nil), isOwn: false, sendState: .sent
        )
        XCTAssertNil(TimelineItemView.avatarSender(for: item, hasMultipleSenders: true))
    }
}
