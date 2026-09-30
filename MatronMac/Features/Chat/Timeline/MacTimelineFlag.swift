import Foundation

/// `chat.timeline.appkit` (spec 2026-09-28 §5): which Mac chat timeline
/// renders. `true` → `MacTimelineController` (NSTableView); `false` → the
/// SwiftUI `ScrollViewReader` timeline, byte-for-byte as before. Read when a
/// chat opens.
enum MacTimelineFlag {
    static let key = "chat.timeline.appkit"

    /// On in Debug builds, off in Release until Dan has used it (spec §5).
    static func defaultValue(isDebugBuild: Bool) -> Bool { isDebugBuild }

    static var defaultValue: Bool {
        #if DEBUG
        return defaultValue(isDebugBuild: true)
        #else
        return defaultValue(isDebugBuild: false)
        #endif
    }
}
