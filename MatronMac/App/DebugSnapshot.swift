#if DEBUG
import AppKit

/// Marketing-screenshot hook, DEBUG builds only. External window capture
/// (screencapture, CGWindowList of other apps, XCUITest) all need TCC grants
/// an unattended screenshot rig doesn't have — but an app may always capture
/// its OWN window. With `MATRON_DEBUG_SNAPSHOT_AFTER=<seconds>` set, the app
/// writes a PNG of its frontmost window (title bar included) to
/// `MATRON_DEBUG_SNAPSHOT_PATH` (default /tmp/matron-mac-snapshot.png) and
/// keeps running. `MATRON_DEBUG_WINDOW_SIZE=WxH` (points, title bar
/// included) sizes the window first so the PNG lands on an App Store Mac
/// size (1280×800 at 2x = 2560×1600). Pairs with `MATRON_APP_SUPPORT_OVERRIDE`
/// and `MATRON_DEBUG_OPEN_CONVO` — see MatronUITests/rig/README.md.
///
/// Launch through LaunchServices (`open -n --env … MatronMac.app`): a binary
/// started straight from a shell gets no windows at all on macOS 26.
enum DebugSnapshot {
    static func armIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["MATRON_DEBUG_SNAPSHOT_AFTER"],
              let delay = Double(raw), delay > 0 else { return }
        let path = ProcessInfo.processInfo.environment["MATRON_DEBUG_SNAPSHOT_PATH"]
            ?? "/tmp/matron-mac-snapshot.png"
        if let raw = ProcessInfo.processInfo.environment["MATRON_DEBUG_WINDOW_SIZE"] {
            let parts = raw.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + min(1.5, delay / 2)) {
                    resizeFrontWindow(to: NSSize(width: parts[0], height: parts[1]))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
        }
    }

    private static func frontWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
    }

    private static func resizeFrontWindow(to size: NSSize) {
        guard let window = frontWindow() else {
            NSLog("DebugSnapshot: no window to resize (%d windows)", NSApp.windows.count); return
        }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        window.center()
    }

    private static func capture(to path: String) {
        guard let window = frontWindow() else {
            NSLog("DebugSnapshot: no window to capture (%d windows)", NSApp.windows.count); return
        }
        // Prefer the window server's own composite of this window: glass
        // chrome, the timeline's layer-backed rows, everything as the user
        // sees it. `cacheDisplay` renders macOS 26 glass as undefined layer
        // content and skips async-drawn rows, so it is only the fallback.
        let png: Data?
        if let cg = windowServerImage(of: window) {
            png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        } else {
            NSLog("DebugSnapshot: window-server capture unavailable, falling back to cacheDisplay")
            guard let frameView = window.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            else { NSLog("DebugSnapshot: no frame view to capture"); return }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png else { NSLog("DebugSnapshot: no png"); return }
        do { try png.write(to: URL(fileURLWithPath: path)); NSLog("DebugSnapshot: wrote %@", path) }
        catch { NSLog("DebugSnapshot: write failed %@", "\(error)") }
    }

    /// `CGWindowListCreateImage` is marked unavailable to Swift on the
    /// macOS 26 SDK (deprecated in favour of ScreenCaptureKit, which needs a
    /// Screen Recording grant even for one's own window). The C symbol is
    /// still exported and capturing one's own window needs no TCC grant, so
    /// resolve it at runtime; a nil here means the fallback path.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3          // kCGWindowListOptionIncludingWindow
        let boundsIgnoreFraming: UInt32 = 1 << 0      // kCGWindowImageBoundsIgnoreFraming
        let bestResolution: UInt32 = 1 << 3           // kCGWindowImageBestResolution
        guard let image = create(.null, includingWindow, UInt32(window.windowNumber),
                                 boundsIgnoreFraming | bestResolution)?.takeRetainedValue(),
              image.width > 1 else { return nil }
        return image
    }
}
#endif
