import XCTest
@testable import MatronVerification

final class VerificationDTOsTests: XCTestCase {
    func test_deviceInfo_equatableByValues() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = DeviceInfo(
            id: "DEV1",
            userID: "@a:s",
            displayName: "iPhone",
            trust: .verified,
            lastSeenAt: now
        )
        let b = DeviceInfo(
            id: "DEV1",
            userID: "@a:s",
            displayName: "iPhone",
            trust: .verified,
            lastSeenAt: now
        )
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, "DEV1")
    }

    func test_sasFlowState_readyForEmoji_equality() {
        let emoji = SasEmoji(symbol: "🐢", description: "Turtle")
        let lhs: SasFlowState = .readyForEmoji([emoji])
        let rhs: SasFlowState = .readyForEmoji([SasEmoji(symbol: "🐢", description: "Turtle")])
        XCTAssertEqual(lhs, rhs)
    }

    func test_sasFlowState_cancelledCarriesReason() {
        let cancelled: SasFlowState = .cancelled(reason: "user-cancelled")
        if case .cancelled(let reason) = cancelled {
            XCTAssertEqual(reason, "user-cancelled")
        } else {
            XCTFail("Expected cancelled state")
        }
    }

    func test_verificationRequestSummary_isIdentifiable() {
        let summary = VerificationRequestSummary(
            id: "req-1",
            otherUserID: "@b:s",
            otherDeviceID: "DEV2",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(summary.id, "req-1")
        XCTAssertEqual(summary.otherUserID, "@b:s")
        XCTAssertEqual(summary.otherDeviceID, "DEV2")
    }

    func test_deviceTrustLevel_distinctCases() {
        XCTAssertNotEqual(DeviceTrustLevel.verified, .unverified)
        XCTAssertNotEqual(DeviceTrustLevel.unverified, .blacklisted)
    }
}
