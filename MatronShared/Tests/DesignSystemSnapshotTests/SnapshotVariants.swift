import XCTest
import SwiftUI
import SnapshotTesting

/// Records baselines for a view across **{iOS, Mac} × {light, dark, accessibility5}**.
/// In practice the SPM test bundle runs on the host platform (macOS), so the
/// `os(macOS)` branch is the one exercised by `swift test`. The `canImport(UIKit)`
/// branch is reserved for the day this suite gets wired into the iOS xcodebuild
/// scheme; keeping both means we don't have to rewrite the helper later.
///
/// `swift-snapshot-testing` ships a SwiftUI-aware `.image` strategy on iOS/tvOS
/// only — on macOS the library only exposes an `NSView`-based strategy, so we
/// host the SwiftUI view in `NSHostingView` ourselves and snapshot that view.
/// Six baseline files are produced per snapshot test ({iOS,Mac} × {light,dark,XXXL}).
/// Set `MATRON_SKIP_SNAPSHOT_TESTS=1` in the environment to skip these tests.
/// CI uses this because the runner's macOS / Xcode versions render
/// NSHostingView pixels differently from a developer's local machine, and
/// pixel-equality assertions across macOS versions are inherently fragile.
/// Snapshots are still useful locally for visual regression review — they
/// run by default unless the env var opts out.
///
/// We also accept `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1` because this SPM
/// test bundle runs transitively inside the Mac xcodebuild scheme too (the
/// `MatronShared` SPM package is a dependency of the `MatronMac` scheme), and
/// xcodebuild only forwards env vars into the test runner under the
/// `TEST_RUNNER_*` prefix. Reading both names means the same skip works
/// regardless of whether the bundle is launched by `swift test` (inherits
/// shell env) or `xcodebuild test` (only `TEST_RUNNER_*` propagates).
func assertVariants<V: View>(
    of view: V,
    named base: String,
    file: StaticString = #file,
    testName: String = #function,
    line: UInt = #line
) {
    let env = ProcessInfo.processInfo.environment
    if ["MATRON_SKIP_SNAPSHOT_TESTS", "TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS"].contains(where: { env[$0] == "1" }) {
        return
    }
    #if canImport(UIKit) && !os(macOS)
    assertSnapshot(
        of: view,
        as: .image(layout: .sizeThatFits, traits: .init(userInterfaceStyle: .light)),
        named: "ios-\(base)-light",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: view,
        as: .image(layout: .sizeThatFits, traits: .init(userInterfaceStyle: .dark)),
        named: "ios-\(base)-dark",
        file: file, testName: testName, line: line
    )
    assertSnapshot(
        of: view,
        as: .image(layout: .sizeThatFits, traits: .init(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)),
        named: "ios-\(base)-axxxl",
        file: file, testName: testName, line: line
    )
    #endif

    #if os(macOS)
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
    #endif
}

#if os(macOS)
import AppKit

/// Wraps a SwiftUI view in `NSHostingView` and sizes it to its intrinsic content
/// so the NSView-based snapshot strategy has something concrete to render.
private func macHostingView<V: View>(_ view: V) -> NSView {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    return host
}
#endif
