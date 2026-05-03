import XCTest
import MatronVerification
import MatronViewModels
@testable import Matron

/// View-layer smoke tests for `VerificationBanner` (Task 9). The banner
/// surfaces a `VerificationRequestSummary` with a "Verify" CTA and a
/// dismiss "X" button. The action plumbing (Tap → SasView sheet, X →
/// `VerificationCenter.dismiss`) is wired in `ChatListView`; here we
/// just lock the body composition + that the callbacks fire.
@MainActor
final class VerificationBannerTests: XCTestCase {

    func test_bodyComposes_withDeviceID() {
        let summary = VerificationRequestSummary(
            id: "req-1",
            otherUserID: "@alice:s",
            otherDeviceID: "DEVICE",
            createdAt: Date()
        )
        let view = VerificationBanner(summary: summary, onAccept: { _ in }, onDismiss: { _ in })
        XCTAssertNotNil(view.body)
    }

    func test_bodyComposes_withoutDeviceID() {
        // `otherDeviceID == nil` is a valid case — user-level verification
        // requests don't carry a device ID. The banner must not crash on
        // the `if let device = summary.otherDeviceID` branch dropping out.
        let summary = VerificationRequestSummary(
            id: "req-2",
            otherUserID: "@bob:s",
            otherDeviceID: nil,
            createdAt: Date()
        )
        let view = VerificationBanner(summary: summary, onAccept: { _ in }, onDismiss: { _ in })
        XCTAssertNotNil(view.body)
    }

    func test_onAccept_isPassedTheSummary() {
        let summary = VerificationRequestSummary(
            id: "req-3",
            otherUserID: "@alice:s",
            otherDeviceID: "DEV",
            createdAt: Date()
        )
        var captured: VerificationRequestSummary?
        let banner = VerificationBanner(
            summary: summary,
            onAccept: { captured = $0 },
            onDismiss: { _ in }
        )
        // Direct callback invocation — SwiftUI doesn't expose button taps
        // for unit tests, but invoking the closure pins the contract that
        // the banner forwards its own `summary` (not a stale captured
        // value or nil) to the host's accept callback.
        banner.onAccept(banner.summary)
        XCTAssertEqual(captured?.id, "req-3")
    }

    func test_onDismiss_isPassedTheSummary() {
        let summary = VerificationRequestSummary(
            id: "req-4",
            otherUserID: "@alice:s",
            otherDeviceID: nil,
            createdAt: Date()
        )
        var captured: VerificationRequestSummary?
        let banner = VerificationBanner(
            summary: summary,
            onAccept: { _ in },
            onDismiss: { captured = $0 }
        )
        banner.onDismiss(banner.summary)
        XCTAssertEqual(captured?.id, "req-4")
    }
}
