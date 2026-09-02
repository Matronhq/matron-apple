#if DEBUG
import AppKit

/// Marketing-screenshot hook, DEBUG builds only. External window capture
/// (screencapture, CGWindowList, XCUITest) all need TCC grants an
/// unattended screenshot rig doesn't have — but an app may always render
/// its own view hierarchy. With `MATRON_DEBUG_SNAPSHOT_AFTER=<seconds>`
/// set, the app writes a PNG of its frontmost window (title bar included)
/// to `MATRON_DEBUG_SNAPSHOT_PATH` (default /tmp/matron-mac-snapshot.png)
/// and keeps running. Pairs with `MATRON_APP_SUPPORT_OVERRIDE` and
/// `MATRON_DEBUG_OPEN_CONVO` — see the screenshot rig notes.
enum DebugSnapshot {
    static func armIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["MATRON_DEBUG_SNAPSHOT_AFTER"],
              let delay = Double(raw), delay > 0 else { return }
        let path = ProcessInfo.processInfo.environment["MATRON_DEBUG_SNAPSHOT_PATH"]
            ?? "/tmp/matron-mac-snapshot.png"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
        }
    }

    private static func capture(to path: String) {
        // contentView.superview is the theme frame: the full window chrome,
        // traffic lights included — what a marketing shot wants.
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
