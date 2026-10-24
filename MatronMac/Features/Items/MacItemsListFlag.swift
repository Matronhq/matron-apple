import Foundation

/// `list.appkit.items`: which items pane list draws. `true` → the AppKit
/// list (`MacItemsAppKitList`: a `MacListHost` with native
/// `MacItemRowCell` rows); `false` → the shared SwiftUI `ItemsListView`,
/// as before. Read when the list mounts. A launch argument
/// `-list.appkit.items YES` (or `NO`) sets it for one run, like every
/// `UserDefaults` flag.
enum MacItemsListFlag {
    static let key = "list.appkit.items"

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
