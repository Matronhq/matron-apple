import XCTest
@testable import MatronPush

/// Pins `JournalPushService`'s APNs-token hex encoding, mirroring
/// `PushServiceLiveTests`. `requestPermission()` / `registerToken` /
/// `unregister` all round-trip through `UNUserNotificationCenter` and
/// `JournalAPI`'s live network stack respectively — not unit-testable
/// headlessly — so this only pins the pure encoding helper.
final class JournalPushServiceTests: XCTestCase {
    func test_hexString_lowercasePadded_matchesJournalContract() {
        let bytes: [UInt8] = [0xab, 0xcd, 0xef, 0x01]
        XCTAssertEqual(JournalPushService.hexString(from: Data(bytes)), "abcdef01")
    }

    func test_hexString_padsSingleDigitBytes() {
        let bytes: [UInt8] = [0x00, 0x05, 0x0a, 0xff]
        XCTAssertEqual(JournalPushService.hexString(from: Data(bytes)), "00050aff")
    }

    func test_hexString_emptyData_returnsEmptyString() {
        XCTAssertEqual(JournalPushService.hexString(from: Data()), "")
    }
}
