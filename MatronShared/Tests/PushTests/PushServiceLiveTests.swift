import XCTest
@testable import MatronPush

/// Pins the APNs-token → `pushkey` encoding. Sygnal expects the
/// lowercase hex string of the raw token bytes — anything else (a
/// trailing space, uppercase digits, base64) gets silently rejected
/// by the homeserver's pusher row validation, which then surfaces as
/// "no APNs traffic ever leaves the host" with no useful client-side
/// signal. Pin this contract here so a refactor can't drift it.
///
/// Most of `PushServiceLive` is delegation to the SDK's
/// `Client.setPusher` / `Client.deletePusher` — those calls require a
/// live homeserver to exercise meaningfully and are covered by the
/// integration harness, not by unit tests.
final class PushServiceLiveTests: XCTestCase {
    func test_hexEncoded_lowercasePadded_matchesAPNsContract() {
        let bytes: [UInt8] = [0xab, 0xcd, 0xef, 0x01]
        XCTAssertEqual(PushServiceLive.hexEncoded(Data(bytes)), "abcdef01")
    }

    func test_hexEncoded_padsSingleDigitBytes() {
        // `0x0a` and `0x05` would render as `"a"` / `"5"` without the
        // `%02x` zero-padding — Sygnal's pushkey parser is strict on
        // hex-string length, so dropped leading zeros silently
        // misroute the token.
        let bytes: [UInt8] = [0x00, 0x05, 0x0a, 0xff]
        XCTAssertEqual(PushServiceLive.hexEncoded(Data(bytes)), "00050aff")
    }

    func test_hexEncoded_emptyData_returnsEmptyString() {
        XCTAssertEqual(PushServiceLive.hexEncoded(Data()), "")
    }

    func test_deviceDisplayName_isNonEmpty() {
        // Sygnal accepts an empty string but the homeserver UI then
        // shows "" for that pusher record, which is unhelpful for
        // multi-device users. Both platform branches must surface a
        // non-empty fallback.
        XCTAssertFalse(PushServiceLive.deviceDisplayName().isEmpty)
    }
}
