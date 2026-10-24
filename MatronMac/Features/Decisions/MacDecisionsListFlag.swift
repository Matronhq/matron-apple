import Foundation

/// `list.appkit.decisions`: which For you list draws. `true` → the AppKit
/// list (`MacDecisionsAppKitList`: a `MacListHost` with native
/// `MacItemRowCell` rows); `false` → the shared SwiftUI `DecisionsListView`,
/// as before. Read when the list mounts. A launch argument
/// `-list.appkit.decisions YES` (or `NO`) sets it for one run, like every
/// `UserDefaults` flag.
enum MacDecisionsListFlag {
    static let key = "list.appkit.decisions"

    /// On in every build since its manual pass; the setting still turns
    /// it off.
    static func defaultValue(isDebugBuild: Bool) -> Bool { true }

    static var defaultValue: Bool {
        #if DEBUG
        return defaultValue(isDebugBuild: true)
        #else
        return defaultValue(isDebugBuild: false)
        #endif
    }

    /// The stored choice (or a launch argument), else the build's default.
    /// `bool(forKey:)` reads a launch argument's `YES`/`NO` string as well as
    /// a stored Bool; `as? Bool` would miss the string.
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}
