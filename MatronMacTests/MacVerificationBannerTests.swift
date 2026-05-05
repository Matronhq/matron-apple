#if os(macOS)
import XCTest
import MatronVerification
import MatronViewModels
@testable import MatronMac

/// Mac-side smoke tests for `MacVerificationBanner` (Task 9b). Mirrors
/// the iOS `VerificationBannerTests` — the shared `VerificationCenter`
/// state machine is covered by SPM `VerificationCenterTests`; here we
/// just lock body composition + callback plumbing per Mac surface.
@MainActor
final class MacVerificationBannerTests: XCTestCase {

    func test_bodyComposes_withDeviceID() {
        let summary = VerificationRequestSummary(
            id: "req-1",
            otherUserID: "@alice:example.org",
            otherDeviceID: "DEV1",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let view = MacVerificationBanner(summary: summary, onAccept: { _ in }, onDismiss: { _ in })
        XCTAssertNotNil(view.body)
    }

    func test_bodyComposes_withoutDeviceID() {
        // User-level verification requests carry a nil device ID. The
        // `if let device = summary.otherDeviceID` branch must not crash
        // when it drops out — mirrors the iOS guard.
        let summary = VerificationRequestSummary(
            id: "req-2",
            otherUserID: "@bob:example.org",
            otherDeviceID: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let view = MacVerificationBanner(summary: summary, onAccept: { _ in }, onDismiss: { _ in })
        XCTAssertNotNil(view.body)
    }

    func test_onAccept_isPassedTheSummary() {
        let summary = VerificationRequestSummary(
            id: "req-3",
            otherUserID: "@alice:example.org",
            otherDeviceID: "DEV",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        var captured: VerificationRequestSummary?
        let banner = MacVerificationBanner(
            summary: summary,
            onAccept: { captured = $0 },
            onDismiss: { _ in }
        )
        banner.onAccept(banner.summary)
        XCTAssertEqual(captured?.id, "req-3")
    }

    func test_onDismiss_isPassedTheSummary() {
        let summary = VerificationRequestSummary(
            id: "req-4",
            otherUserID: "@alice:example.org",
            otherDeviceID: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        var captured: VerificationRequestSummary?
        let banner = MacVerificationBanner(
            summary: summary,
            onAccept: { _ in },
            onDismiss: { captured = $0 }
        )
        banner.onDismiss(banner.summary)
        XCTAssertEqual(captured?.id, "req-4")
    }
}
#endif
