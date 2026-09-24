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
/// Records baselines for a SwiftUI view in **light × dark**.
/// `swift-snapshot-testing` only ships an `NSView`-based image strategy on
/// macOS, so we host the SwiftUI view in a windowed `NSHostingView`
/// (`MacSnapshotHost`) and snapshot that. Two baseline files are produced
/// per call (`mac-{base}-{light,dark}`); macOS has no Dynamic Type, so an
/// accessibility-size variant would only duplicate the light one.
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
/// CI's `mac-build-and-test` job uses this pattern. We accept both the
/// unprefixed and the `TEST_RUNNER_*`-prefixed names so the same call site
/// works whether this helper is invoked under `swift test` (inherits shell
/// env) or `xcodebuild test` (only `TEST_RUNNER_*` propagates into the runner).
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
    MainActor.assumeIsolated {
        let light = MacSnapshotHost(view, appearance: .aqua)
        let dark = MacSnapshotHost(view, appearance: .darkAqua)
        // A dark capture identical to the light one means the appearance
        // never reached the view (tracker #2840: every Mac pair was).
        if light.pngData() == dark.pngData() {
            XCTFail("mac-\(base): light and dark renders are byte-identical", file: file, line: line)
        }
        assertSnapshot(of: light.view, as: .image, named: "mac-\(base)-light",
                       file: file, testName: testName, line: line)
        assertSnapshot(of: dark.view, as: .image, named: "mac-\(base)-dark",
                       file: file, testName: testName, line: line)
    }
}

/// Mirrors `MacSnapshotHost` in the SPM `SnapshotVariants.swift` (whose
/// `SnapshotHarnessTests` pin the behaviour).
///
/// Hosts a SwiftUI view the way the app does — inside a window — so the
/// NSView-based snapshot strategy captures what a user would see.
///
/// A window-less `NSHostingView` (the old harness) is not enough on macOS:
/// - `List` is an `NSTableView`, which only loads its rows once it is in a
///   window and the run loop has turned; without that the capture showed
///   the header, an opaque black band where the section header's backdrop
///   should be, and a blank body (tracker #2840).
/// - `preferredColorScheme` is applied to the hosting WINDOW's appearance,
///   so with no window the dark variant rendered light: every Mac
///   light/dark reference pair was byte-identical.
///
/// So the view goes into a borderless, never-ordered-in window whose
/// `appearance` is set explicitly, over a backdrop that paints the
/// window background colour (dark text on a transparent PNG is unreadable
/// in review), and the run loop turns before capture.
///
/// There is no Mac accessibility-size variant: macOS has no Dynamic Type,
/// so `.dynamicTypeSize(.accessibility5)` leaves Mac text unchanged and the
/// old `mac-*-axxxl` references were copies of the light ones.
@MainActor
final class MacSnapshotHost {
    let window: NSWindow
    let view: NSView

    init<V: View>(_ content: V, appearance: NSAppearance.Name) {
        let host = NSHostingView(rootView: content)
        let frame = NSRect(origin: .zero, size: host.fittingSize)
        let backdrop = SnapshotBackdropView(frame: frame)
        host.frame = backdrop.bounds
        host.autoresizingMask = [.width, .height]
        backdrop.addSubview(host)

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = backdrop
        view = backdrop

        backdrop.layoutSubtreeIfNeeded()
        // Let SwiftUI's update pass and the table view's deferred row load run.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        settle()
    }

    /// In a window, SwiftUI animations actually run (with no window they
    /// never started), so a view whose state changes on appear — e.g. the
    /// item detail's 0.18 s jump-to-bottom fade — would be captured
    /// mid-transition. Turn the run loop until two consecutive renders
    /// match, bounded so an endless animation can't hang the suite.
    private func settle() {
        var previous = renderedBytes()
        for _ in 0..<40 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let current = renderedBytes()
            if current == previous { return }
            previous = current
        }
    }

    private func renderedBytes() -> Data? {
        view.layoutSubtreeIfNeeded()
        return bitmap()?.tiffRepresentation
    }

    func bitmap() -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func pngData() -> Data? {
        bitmap()?.representation(using: .png, properties: [:])
    }
}

/// Paints the window background in the view's effective appearance.
private final class SnapshotBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
#endif
