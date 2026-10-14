import Foundation

/// `items.thread.native`: which Mac item thread draws. `true` → the AppKit
/// table (`MacItemThreadController`); `false` → `ItemDetailView`'s own
/// SwiftUI thread, as before. Read when an item opens.
enum MacItemThreadFlag {
    static let key = "items.thread.native"

    /// On in Debug builds, off in Release until it has had a manual pass.
    static func defaultValue(isDebugBuild: Bool) -> Bool { isDebugBuild }

    static var defaultValue: Bool {
        #if DEBUG
        return defaultValue(isDebugBuild: true)
        #else
        return defaultValue(isDebugBuild: false)
        #endif
    }

    /// The stored choice, else the build's default.
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}
