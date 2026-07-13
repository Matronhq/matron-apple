import Foundation
import os

/// Process-wide gate for high-frequency diagnostic logs that we want
/// to keep in the codebase as breadcrumbs but ship turned off. Mirror
/// of the `debugLog('…')` helper pattern from the web side.
///
/// Default: off. Toggle on for a session by either:
///   - setting `UserDefaults.standard.set(true, forKey: "MatronDebug")`
///     before the first `diag` call (e.g. early app startup), OR
///   - running `defaults write chat.matron.app MatronDebug -bool YES`
///     for the iOS sim / `defaults write chat.matron.mac MatronDebug -bool YES`
///     for the Mac app (domain = bundle id, see project.yml), then
///     relaunching, OR
///   - flipping `MatronDebug.enabled = true` from a test, the LLDB
///     console, or a one-off debug build.
///
/// The flag snapshots `UserDefaults["MatronDebug"]` once at first
/// access. We don't observe changes — flipping `enabled` mid-session
/// requires either restarting or assigning the property directly.
public enum MatronDebug {
    @TaskLocal public static var override: Bool? = nil

    private static let _initial: Bool = {
        // An explicit defaults write always wins. Absent one, DEBUG
        // builds default verbose: dev builds run on personal devices
        // where the persisted diag trail is how field incidents get
        // diagnosed (the 2026-07-13 phone blanks left no snapshot logs
        // because the gate was off and there's no `defaults write` on
        // a physical iPhone). Release stays off.
        if UserDefaults.standard.object(forKey: "MatronDebug") != nil {
            return UserDefaults.standard.bool(forKey: "MatronDebug")
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    public static var enabled: Bool {
        get { override ?? _enabled }
        set { _enabled = newValue }
    }

    nonisolated(unsafe) private static var _enabled: Bool = MatronDebug._initial
}

public extension Logger {
    /// Diagnostic log that only fires when `MatronDebug.enabled` is
    /// true. Use for high-frequency or debug-only logs that we want
    /// to keep in the source as living documentation of the data
    /// flow without paying for them at runtime in shipped builds.
    ///
    /// Implementation note: `@autoclosure` defers the string
    /// interpolation so the format args don't get evaluated when the
    /// flag is off — important for logs that include `items.count`
    /// reads or other observable view-model properties that you
    /// don't want to be touching on every snapshot during normal
    /// operation. The whole interpolated string is logged at
    /// `.public` privacy because diagnostic strings here are app
    /// state, not user content; if you ever need per-arg privacy in
    /// a `.diag` log, drop back to `Logger.notice` and gate it
    /// manually with `if MatronDebug.enabled { ... }`.
    func diag(_ message: @autoclosure () -> String) {
        guard MatronDebug.enabled else { return }
        // Evaluate the autoclosure into a local before passing to
        // `notice`. The `OSLogMessage` interpolation captures its
        // arguments as escaping autoclosures internally; passing
        // `message()` inline would re-promote our non-escaping
        // parameter into an escaping context and fail to compile.
        let resolved = message()
        self.notice("\(resolved, privacy: .public)")
    }
}
