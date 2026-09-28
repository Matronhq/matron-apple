import Foundation

/// Which iOS chat timeline renders. A shipped build has one, the UIKit
/// timeline (`ChatTimelineController`, TextKit cells): Dan, 2026-09-28,
/// people should not be choosing between two, so Settings has no toggle
/// and a choice stored by an earlier build is ignored.
///
/// Development and perf-probe builds still read `chat.timeline.uikit`, so
/// the perf gate has its SwiftUI baseline and the SwiftUI path its tests
/// until that code is deleted.
///
/// This covers `ChatView` only. The read-only sub-chat viewer
/// (`SubChatView`) never had the flag: it renders the SwiftUI rows
/// (`TimelineListContent`) in every build, and those stay until it moves
/// to the UIKit timeline too.
enum ChatTimelineFlag {
    static let key = "chat.timeline.uikit"

    /// Whether this build can still reach the SwiftUI timeline.
    static let developmentBuild: Bool = {
        #if DEBUG || MATRON_PERF_PROBE
        return true
        #else
        return false
        #endif
    }()

    static func isOn(in defaults: UserDefaults = .standard,
                     developmentBuild: Bool = ChatTimelineFlag.developmentBuild) -> Bool {
        guard developmentBuild, defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}
