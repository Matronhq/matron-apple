import XCTest
@testable import MatronEvents

final class LiveOutputEventTests: XCTestCase {
    func testParsesBridgePayload() throws {
        let event = try XCTUnwrap(LiveOutputEvent.parse(payload: [
            "tool_use_id": "toolu_123",
            "command": "npm test",
            "viewer_url": "https://viewer.example.com/live?token=abc.def",
            "expires_at": 1_760_000_000,
        ]))
        XCTAssertEqual(event.toolUseID, "toolu_123")
        XCTAssertEqual(event.command, "npm test")
        XCTAssertEqual(event.expiresAt, Date(timeIntervalSince1970: 1_760_000_000))
    }

    func testParseRequiresCommandAndViewerURL() {
        XCTAssertNil(LiveOutputEvent.parse(payload: ["command": "ls"]))
        XCTAssertNil(LiveOutputEvent.parse(payload: ["viewer_url": "https://x/live?token=t"]))
        XCTAssertNil(LiveOutputEvent.parse(payload: [
            "command": "", "viewer_url": "https://x/live?token=t",
        ]))
        // Ordinary tool_output payloads (snippet shape) must NOT parse —
        // they should keep rendering as the static tool-call card.
        XCTAssertNil(LiveOutputEvent.parse(payload: [
            "tool_name": "Read", "snippet": "some file contents",
        ]))
    }

    func testSocketURLRewrite() throws {
        let event = try XCTUnwrap(LiveOutputEvent.parse(payload: [
            "command": "ls",
            "viewer_url": "https://viewer.example.com/live?token=abc.def",
        ]))
        XCTAssertEqual(event.socketURL?.absoluteString,
                       "wss://viewer.example.com/live/ws?token=abc.def")

        let plain = try XCTUnwrap(LiveOutputEvent.parse(payload: [
            "command": "ls",
            "viewer_url": "http://127.0.0.1:9803/live?token=t",
        ]))
        XCTAssertEqual(plain.socketURL?.absoluteString,
                       "ws://127.0.0.1:9803/live/ws?token=t")

        // A URL that isn't a /live viewer link has no socket form.
        let odd = LiveOutputEvent(
            toolUseID: "t", command: "ls",
            viewerURL: URL(string: "https://x/view?token=t")!, expiresAt: nil)
        XCTAssertNil(odd.socketURL)
    }

    func testExpiry() {
        let expired = LiveOutputEvent(
            toolUseID: "t", command: "ls",
            viewerURL: URL(string: "https://x/live?token=t")!,
            expiresAt: Date(timeIntervalSinceNow: -60))
        XCTAssertTrue(expired.isExpired)
        let live = LiveOutputEvent(
            toolUseID: "t", command: "ls",
            viewerURL: URL(string: "https://x/live?token=t")!,
            expiresAt: Date(timeIntervalSinceNow: 3600))
        XCTAssertFalse(live.isExpired)
        let noExpiry = LiveOutputEvent(
            toolUseID: "t", command: "ls",
            viewerURL: URL(string: "https://x/live?token=t")!, expiresAt: nil)
        XCTAssertFalse(noExpiry.isExpired)
    }

    func testFrameDecode() {
        XCTAssertEqual(LiveOutputFrame.decode(#"{"type":"data","chunk":"hello\n"}"#),
                       .data(chunk: "hello\n"))
        XCTAssertEqual(LiveOutputFrame.decode(#"{"type":"complete","exitCode":0,"denied":false,"truncated":false}"#),
                       .complete(exitCode: 0, denied: false, truncated: false))
        XCTAssertEqual(LiveOutputFrame.decode(#"{"type":"complete","exitCode":1,"truncated":true}"#),
                       .complete(exitCode: 1, denied: false, truncated: true))
        XCTAssertNil(LiveOutputFrame.decode(#"{"type":"nonsense"}"#))
        XCTAssertNil(LiveOutputFrame.decode("not json"))
    }
}
