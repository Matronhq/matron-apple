import XCTest
@testable import Matron

/// View-layer smoke tests for `UnverifiedDeviceBanner` (Wave 6 /
/// live-test #3). Mirrors `VerificationBannerTests` — the banner is
/// trivial; we lock body composition + the verify-callback plumbing.
/// Banner-visibility branching (hidden when `isThisDeviceVerified` is
/// `true` or `nil`, shown only on explicit `false`) lives in
/// `ChatListView`'s body and is asserted indirectly by the existing
/// `ChatListViewBindingTests`.
@MainActor
final class UnverifiedDeviceBannerTests: XCTestCase {

    func test_bodyComposes() {
        let banner = UnverifiedDeviceBanner(onVerify: {})
        XCTAssertNotNil(banner.body)
    }

    func test_onVerify_fires_whenInvoked() {
        var taps = 0
        let banner = UnverifiedDeviceBanner(onVerify: { taps += 1 })
        // Direct closure invocation — XCTest can't simulate SwiftUI
        // button taps, but invoking the closure pins the contract that
        // the banner forwards its tap to the host's verify callback.
        banner.onVerify()
        XCTAssertEqual(taps, 1)
    }
}
