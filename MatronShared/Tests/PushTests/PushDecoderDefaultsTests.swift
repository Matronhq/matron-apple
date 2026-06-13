import XCTest
import MatrixRustSDK
@testable import MatronPush

/// Pins `PushDecoder.decode(...)` behaviour for the cases that don't
/// require a real `TimelineEvent` — fetcher returning `nil`, fetcher
/// returning an `.invite` notification, the leaf `body(forContent:)`
/// extraction layers. Constructing a `NotificationItem` with a real
/// timeline-event-backed payload requires a Rust-handle-backed
/// `TimelineEvent` instance, which can't be safely fabricated in
/// pure-Swift tests; Task 7 wires those scenarios into the integration
/// harness instead.
final class PushDecoderDefaultsTests: XCTestCase {
    // MARK: - decode(...) outer surface

    func test_decode_returnsFallbackWhenFetcherYieldsNil() async throws {
        let decoder = PushDecoder(fetcher: { _, _ in nil })
        let result = try await decoder.decode(roomID: "!r:s.example", eventID: "$evt")
        // Fallback shape mirrors what an iOS NSE shows when the SDK
        // can't resolve / decrypt the event in time. No plaintext
        // leaks via the placeholder body.
        XCTAssertEqual(result.title, "Matron")
        XCTAssertEqual(result.body, "New message")
        XCTAssertEqual(result.threadIdentifier, "!r:s.example")
        XCTAssertNil(result.badge)
    }

    // MARK: - body(forMessageType:) — every MessageType case

    func test_body_text_returnsBody() {
        let mt = MessageType.text(content: TextMessageContent(body: "hello there", formatted: nil))
        XCTAssertEqual(PushDecoder.body(forMessageType: mt), "hello there")
    }

    func test_body_notice_returnsBody() {
        let mt = MessageType.notice(content: NoticeMessageContent(body: "system notice", formatted: nil))
        XCTAssertEqual(PushDecoder.body(forMessageType: mt), "system notice")
    }

    func test_body_emote_prefixesWithAsterisk() {
        let mt = MessageType.emote(content: EmoteMessageContent(body: "waves", formatted: nil))
        XCTAssertEqual(PushDecoder.body(forMessageType: mt), "* waves")
    }

    func test_body_image_prefersCaptionThenFilename() throws {
        let withCaption = MessageType.image(content: ImageMessageContent(
            filename: "IMG_0001.jpg",
            caption: "view from the office",
            formattedCaption: nil,
            source: try Self.testMediaSource(),
            info: nil
        ))
        XCTAssertEqual(PushDecoder.body(forMessageType: withCaption), "📷 view from the office")

        let withoutCaption = MessageType.image(content: ImageMessageContent(
            filename: "IMG_0002.jpg",
            caption: nil,
            formattedCaption: nil,
            source: try Self.testMediaSource(),
            info: nil
        ))
        XCTAssertEqual(PushDecoder.body(forMessageType: withoutCaption), "📷 IMG_0002.jpg")
    }

    func test_body_file_prefersCaptionThenFilename() throws {
        let mt = MessageType.file(content: FileMessageContent(
            filename: "report.pdf",
            caption: nil,
            formattedCaption: nil,
            source: try Self.testMediaSource(),
            info: nil
        ))
        XCTAssertEqual(PushDecoder.body(forMessageType: mt), "📎 report.pdf")
    }

    func test_body_other_returnsRawBody() {
        // The SDK's catch-all for msgtypes we don't model explicitly
        // (e.g. `chat.matron.tool_call` from spec §10). Pass the body
        // through verbatim — the renderer's job to format it.
        let mt = MessageType.other(msgtype: "chat.matron.tool_call", body: "🔧 ran search")
        XCTAssertEqual(PushDecoder.body(forMessageType: mt), "🔧 ran search")
    }

    func test_body_location_returnsGenericLabel() {
        let mt = MessageType.location(content: LocationContent(
            body: "Big Ben",
            geoUri: "geo:51.5,-0.12",
            description: nil,
            zoomLevel: nil,
            asset: AssetType.sender
        ))
        XCTAssertEqual(PushDecoder.body(forMessageType: mt), "📍 Location")
    }

    // MARK: - body(forMessageLike:) — selected non-roomMessage cases

    func test_body_messageLike_roomEncrypted_returnsLockBody() {
        XCTAssertEqual(PushDecoder.body(forMessageLike: .roomEncrypted), "🔒 Encrypted message")
    }

    func test_body_messageLike_reaction_returnsReactedBody() {
        XCTAssertEqual(
            PushDecoder.body(forMessageLike: .reactionContent(relatedEventId: "$src")),
            "Reacted to message"
        )
    }

    func test_body_messageLike_redaction_returnsRedactedBody() {
        XCTAssertEqual(
            PushDecoder.body(forMessageLike: .roomRedaction(redactedEventId: "$src", reason: nil)),
            "Message redacted"
        )
    }

    func test_body_messageLike_sticker_returnsStickerBody() {
        XCTAssertEqual(PushDecoder.body(forMessageLike: .sticker), "Sticker")
    }

    // MARK: - matronHintBody (Phase 5 Task 12)

    func test_hint_toolCall() {
        let raw = #"{"type": "chat.matron.tool_call", "content": {"tool": "Read", "status": "running", "started_at": 1745000000000}}"#
        XCTAssertEqual(PushDecoder.matronHintBody(rawEvent: raw), "🔧 Tool call")
    }

    func test_hint_askUser() {
        let raw = #"{"type": "chat.matron.ask_user", "content": {"prompt": "Which file?", "input": {"kind": "text"}}}"#
        XCTAssertEqual(PushDecoder.matronHintBody(rawEvent: raw), "❓ Question — needs your answer")
    }

    func test_hint_buttonsMessage_usesPrompt() {
        // The bridge's live protocol: ordinary m.room.message with a
        // chat.matron.buttons content key. The prompt is already in
        // the plaintext fallback body, so no new exposure.
        let raw = #"""
        {"type": "m.room.message", "content": {
            "msgtype": "m.text", "body": "Proceed? [Yes] [No]",
            "chat.matron.buttons": {"mode": "pick_one", "prompt": "Proceed?",
                "buttons": [{"id": "y", "label": "Yes", "value": "yes"}]}
        }}
        """#
        XCTAssertEqual(PushDecoder.matronHintBody(rawEvent: raw), "❓ Proceed?")
    }

    func test_hint_buttonsMessage_missingPrompt_fallsBackToGeneric() {
        let raw = #"{"type": "m.room.message", "content": {"body": "x", "chat.matron.buttons": {"mode": "pick_one"}}}"#
        XCTAssertEqual(PushDecoder.matronHintBody(rawEvent: raw), "❓ Question — needs your answer")
    }

    func test_hint_nilForPlainMessage() {
        let raw = #"{"type": "m.room.message", "content": {"msgtype": "m.text", "body": "hello"}}"#
        XCTAssertNil(PushDecoder.matronHintBody(rawEvent: raw))
    }

    func test_hint_nilForMalformedJson() {
        XCTAssertNil(PushDecoder.matronHintBody(rawEvent: "{chat.matron. not json"))
    }

    // MARK: - Helpers

    /// `MediaSource` is a Rust-handle class — there's no value-type
    /// constructor and the `init(noHandle:)` form crashes on any
    /// further FFI call. `fromUrl(url:)` allocates a real handle that's
    /// safe to drop without further calls; the body-extraction tests
    /// only read pure-Swift `caption` / `filename` fields off the
    /// content struct, never touching the source.
    private static func testMediaSource() throws -> MediaSource {
        try MediaSource.fromUrl(url: "mxc://test.matron/aaaaaaaaaaaa")
    }
}
