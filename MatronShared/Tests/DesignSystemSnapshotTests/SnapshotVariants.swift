import XCTest
import SwiftUI
import SnapshotTesting

/// Records baselines for a view across iOS {light, dark, accessibility5} and
/// Mac {light, dark} (macOS has no Dynamic Type — see `MacSnapshotHost`).
/// In practice the SPM test bundle runs on the host platform (macOS), so the
/// `os(macOS)` branch is the one exercised by `swift test`. The `canImport(UIKit)`
/// branch is reserved for the day this suite gets wired into the iOS xcodebuild
/// scheme; keeping both means we don't have to rewrite the helper later.
///
/// `swift-snapshot-testing` ships a SwiftUI-aware `.image` strategy on iOS/tvOS
/// only — on macOS the library only exposes an `NSView`-based strategy, so we
/// host the SwiftUI view in a windowed `NSHostingView` ourselves
/// (`MacSnapshotHost`) and snapshot that.
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
    MainActor.assumeIsolated {
        let light = MacSnapshotHost(view, appearance: .aqua)
        let dark = MacSnapshotHost(view, appearance: .darkAqua)
        defer { light.close(); dark.close() }
        // A dark capture identical to the light one means the appearance
        // never reached the view (tracker #2840: every Mac pair was).
        if light.pngData() == dark.pngData() {
            XCTFail("mac-\(base): light and dark renders are byte-identical", file: file, line: line)
        }
        for (host, name) in [(light, "light"), (dark, "dark")] where !host.settled {
            XCTFail("mac-\(base)-\(name): render never stopped changing; the snapshot would be a random frame",
                    file: file, line: line)
        }
        assertSnapshot(of: light.view, as: .image, named: "mac-\(base)-light",
                       file: file, testName: testName, line: line)
        assertSnapshot(of: dark.view, as: .image, named: "mac-\(base)-dark",
                       file: file, testName: testName, line: line)
    }
    #endif
}

#if os(macOS)
import AppKit

/// Renders `view` through the Mac harness and returns the captured bitmap.
@MainActor
func macSnapshotImage<V: View>(of view: V, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
    let host = MacSnapshotHost(view, appearance: appearance)
    defer { host.close() }
    return host.bitmap()
}

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
    /// `false` when the render was still changing at the settle bound.
    private(set) var settled = false

    init<V: View>(_ content: V, appearance: NSAppearance.Name) {
        let host = NSHostingView(rootView: content)
        let frame = NSRect(origin: .zero, size: host.fittingSize)
        let backdrop = SnapshotBackdropView(frame: frame)
        host.frame = backdrop.bounds
        host.autoresizingMask = [.width, .height]
        backdrop.addSubview(host)

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        // ARC owns the window; `close()` must not also release it.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = backdrop
        view = backdrop

        backdrop.layoutSubtreeIfNeeded()
        // Let SwiftUI's update pass and the table view's deferred row load run.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        settled = settle()
    }

    /// Releases the window; call once the capture is done.
    func close() {
        window.close()
    }

    /// In a window, SwiftUI animations actually run (with no window they
    /// never started), so a view whose state changes on appear — e.g. the
    /// item detail's 0.18 s jump-to-bottom fade — would be captured
    /// mid-transition. Turn the run loop until two consecutive renders
    /// match, bounded so an endless animation can't hang the suite; a view
    /// that hits the bound fails its test (`assertVariants`) rather than
    /// recording whichever frame it happened to be on. An indeterminate
    /// `ProgressView` is not such a view: its spin is a Core Animation
    /// layer animation, which `cacheDisplay` never captures, so it draws
    /// the same static frame every time (checked: `test_downloading`
    /// settles on the first comparison).
    private func settle() -> Bool {
        var previous = renderedBytes()
        for _ in 0..<40 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let current = renderedBytes()
            if current == previous { return true }
            previous = current
        }
        return false
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
