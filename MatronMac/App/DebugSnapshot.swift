#if DEBUG
import AppKit
import MatronModels
import MatronDesignSystem

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
        let env = ProcessInfo.processInfo.environment
        // MATRON_DEBUG_OPEN_URL=<link>: handled as if opened from outside
        // (an invite link's sheet), without going through Launch Services,
        // which could hand it to another installed copy of the app.
        if let raw = env["MATRON_DEBUG_OPEN_URL"], let url = URL(string: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !IncomingInviteLinks.shared.receive(url) { IncomingTrackerLinks.shared.receive(url) }
            }
        }
        guard let raw = ProcessInfo.processInfo.environment["MATRON_DEBUG_SNAPSHOT_AFTER"],
              let delay = Double(raw), delay > 0 else { return }
        let path = ProcessInfo.processInfo.environment["MATRON_DEBUG_SNAPSHOT_PATH"]
            ?? "/tmp/matron-mac-snapshot.png"
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
        }
    }

    /// The Settings pane MATRON_DEBUG_SETTINGS_TAB names, if any: the main
    /// window opens Settings on it (`MacChatListView`).
    static var settingsTab: String? { ProcessInfo.processInfo.environment["MATRON_DEBUG_SETTINGS_TAB"] }

    private static func capture(to path: String) {
        // contentView.superview is the theme frame: the full window chrome,
        // traffic lights included — what a marketing shot wants.
        // A sheet is a window of its own: capture it rather than the
        // dimmed window it hangs from.
        // With MATRON_DEBUG_SETTINGS_TAB, the Settings window.
        let settings = settingsTab == nil ? nil
            : NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.contains("Settings") ?? false) }
        guard let front = settings ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              case let window = front.attachedSheet ?? front,
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
