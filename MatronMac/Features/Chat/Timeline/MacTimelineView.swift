import Foundation
import Observation

/// The table timeline's state and commands for the SwiftUI chrome around it
/// (jump button, top-trailing controls, `onDisappear`) — the Mac twin of
/// iOS `ChatTimelineBridge`. Task 11 adds the representable to this file.
@Observable
@MainActor
final class MacTimelineBridge {
    private(set) var isFollowingTail = true
    @ObservationIgnored weak var controller: MacTimelineController?

    func setFollowing(_ following: Bool) {
        if isFollowingTail != following { isFollowingTail = following }
    }

    /// The jump-to-latest button.
    func jumpToBottom() { controller?.session.jumpToBottom() }

    /// `MacChatView.onDisappear`: remember (or forget) this room's position
    /// from the controller's real follow state. A no-op once the controller
    /// is gone — its `tearDown` has already stored.
    func storeScrollPosition() { controller?.session.storeScrollPosition() }
}
