#if os(macOS)
import XCTest
@testable import MatronMac

/// Mac-side smoke tests for `MacUnverifiedDeviceBanner` (Wave 6 /
/// live-test #3). Mirrors `MacVerificationBannerTests` — the banner is
/// trivial; we lock body composition + the verify-callback plumbing.
/// Banner-visibility branching (hidden when verified, hidden when nil,
/// shown only when explicitly false) lives in `MacChatListView`'s
/// `sidebarColumn` and is asserted indirectly by `MacChatListViewTests`'s
/// existing body-composition coverage (the new branch compiles + runs as
/// part of `view.body` evaluation).
@MainActor
final class MacUnverifiedDeviceBannerTests: XCTestCase {

    func test_bodyComposes() {
        let banner = MacUnverifiedDeviceBanner(onVerify: {})
        XCTAssertNotNil(banner.body)
    }

    func test_onVerify_fires_whenInvoked() {
        var taps = 0
        let banner = MacUnverifiedDeviceBanner(onVerify: { taps += 1 })
        // Direct closure invocation — XCTest can't simulate SwiftUI
        // button taps, but invoking the closure pins the contract that
        // the banner forwards its tap to the host's verify callback.
        banner.onVerify()
        XCTAssertEqual(taps, 1)
    }
}
#endif
