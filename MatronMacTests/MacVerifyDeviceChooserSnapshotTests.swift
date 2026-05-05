#if os(macOS)
import XCTest
import SnapshotTesting
@testable import MatronMac

/// Snapshot coverage for `MacVerifyDeviceChooser` (handover Priority A
/// test #3). Locks the rendered chrome in both probe outcomes:
///
///   - `hasOtherDevices == true`  → "Verify with another device" enabled,
///     no caption shown.
///   - `hasOtherDevices == false` → button disabled, "No other verified
///     devices found for your account." caption visible. Without the
///     disabled-state, picking SAS would strand the user on a flow that
///     can never complete.
///
/// Snapshot rather than XCUITest because the chooser only renders when
/// the parent sheet's `Phase` resolves to `.chooser` —
/// `isThisDeviceVerified() == false` AND user is signed in. For a
/// never-released app that's a state new users can't naturally reach
/// (fresh sign-in always lands at the verify gate, which is a different
/// surface). Snapshot testing exercises the rendering directly without
/// state-injection trickery.
///
/// `assertVariants(of:named:)` records light × dark × accessibility5
/// baselines per state, gated by `MATRON_SKIP_SNAPSHOT_TESTS=1` for CI.
@MainActor
final class MacVerifyDeviceChooserSnapshotTests: XCTestCase {

    func test_chooser_otherDevicesAvailable() {
        assertVariants(
            of: MacVerifyDeviceChooser(
                hasOtherDevices: true,
                onSAS: {},
                onRecoveryKey: {},
                onClose: {}
            ),
            named: "MacVerifyDeviceChooser_otherDevicesAvailable"
        )
    }

    func test_chooser_noOtherDevices() {
        assertVariants(
            of: MacVerifyDeviceChooser(
                hasOtherDevices: false,
                onSAS: {},
                onRecoveryKey: {},
                onClose: {}
            ),
            named: "MacVerifyDeviceChooser_noOtherDevices"
        )
    }
}
#endif
