import Foundation

/// `list.appkit.sidebar`: which sidebar chat list draws. `true` → the
/// AppKit list (`MacSidebarAppKitList`: a `MacListHost` fed by the chat-list
/// index, with native `MacChatListCell` rows and no row cap); `false` → the
/// SwiftUI `List` of `MacChatRow`s, as before. Read when the sidebar list
/// mounts. A launch argument `-list.appkit.sidebar YES` (or `NO`) sets it
/// for one run, like every `UserDefaults` flag.
enum MacSidebarListFlag {
    static let key = "list.appkit.sidebar"

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
