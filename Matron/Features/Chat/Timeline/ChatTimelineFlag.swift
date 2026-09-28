import Foundation

/// `chat.timeline.uikit` (spec §3): which iOS chat timeline renders.
/// `true` → `ChatTimelineController` (UIKit, TextKit cells); `false` → the
/// SwiftUI `ScrollViewReader` timeline, byte-for-byte as before.
enum ChatTimelineFlag {
    static let key = "chat.timeline.uikit"

    /// The `@AppStorage` default. On in every build: the spec kept App
    /// Store builds off for one release, and Dan (2026-09-28, tracker
    /// #3954) ships the UIKit timeline in the next one. Settings ▸ Advanced
    /// is the way back to the SwiftUI timeline.
    static let defaultValue = true

    /// The flag as `@AppStorage` reads it: a stored choice, else the default.
    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}
