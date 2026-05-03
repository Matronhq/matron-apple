#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import SnapshotTesting

/// Mac-side mirror of `MatronShared/Tests/DesignSystemSnapshotTests/SnapshotVariants.swift`.
///
/// The SPM-side helper lives in a different test target and isn't reachable
/// from the Xcode `MatronMacTests` bundle. Duplicated here (Mac branch only —
/// we don't need the iOS branch in this bundle) so Mac verification chrome
/// can use the same `assertVariants(of:named:)` call site.
///
/// Records baselines for a SwiftUI view across **light × dark × accessibility5**.
/// `swift-snapshot-testing` only ships an `NSView`-based image strategy on
/// macOS, so we host the SwiftUI view in `NSHostingView` and snapshot that.
/// Three baseline files are produced per call (`mac-{base}-{light,dark,axxxl}`).
///
/// Set `MATRON_SKIP_SNAPSHOT_TESTS=1` in the environment to skip these tests.
/// CI uses this because the runner's macOS / Xcode versions render
/// `NSHostingView` pixels differently from a developer's local machine, and
/// pixel-equality assertions across macOS versions are inherently fragile.
/// Snapshots are still useful locally for visual regression review — they
/// run by default unless the env var opts out.
///
/// Note for `xcodebuild test`: unlike `swift test`, xcodebuild does **not**
/// inherit the parent shell's env into the test runner. Pass it via the
/// documented `TEST_RUNNER_*` prefix instead:
///   `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test …`
/// CI's `mac-build-and-test` job uses this pattern.
func assertVariants<V: View>(
    of view: V,
    named base: String,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    if ProcessInfo.processInfo.environment["MATRON_SKIP_SNAPSHOT_TESTS"] == "1" {
        return
    }
    assertSnapshot(
        of: macHostingView(view.preferredColorScheme(.light)),
        as: .image,
        named: "mac-\(base)-light",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: macHostingView(view.preferredColorScheme(.dark)),
        as: .image,
        named: "mac-\(base)-dark",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: macHostingView(view.dynamicTypeSize(.accessibility5)),
        as: .image,
        named: "mac-\(base)-axxxl",
        file: file, testName: testName, line: line
    )
}

/// Wraps a SwiftUI view in `NSHostingView` and sizes it to its intrinsic
/// content so the NSView-based snapshot strategy has something concrete to
/// render. Mirrors the SPM helper's private `macHostingView`.
private func macHostingView<V: View>(_ view: V) -> NSView {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    return host
}
#endif
