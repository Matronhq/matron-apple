import AppKit
import Observation
import SwiftUI
import MatronViewModels
import MatronDesignSystem

/// Hosts `MacTimelineController` in `MacChatView.chatColumn` in place of the
/// `ScrollViewReader`/`ScrollView` block when `chat.timeline.appkit` is on
/// (spec 2026-09-28) — the Mac twin of iOS `ChatTimelineView`.
struct MacTimelineView: NSViewControllerRepresentable {
    let viewModel: ChatViewModel
    let stripViewModel: SubChatStripViewModel
    let bridge: MacTimelineBridge
    let selection: MessageSelectionController
    let actions: MacTimelineActions

    func makeNSViewController(context: Context) -> MacTimelineController {
        MacTimelineController(viewModel: viewModel, stripViewModel: stripViewModel, bridge: bridge,
                              selection: selection, actions: actions)
    }

    func updateNSViewController(_ controller: MacTimelineController, context: Context) {
        controller.update(actions: actions)
    }

    static func dismantleNSViewController(_ controller: MacTimelineController, coordinator: ()) {
        // Stores the scroll position too: SwiftUI may dismantle this before
        // `MacChatView`'s `onDisappear`, whose bridge call would then find
        // no controller (the iOS review F6 case).
        controller.tearDown()
    }
}

/// The table timeline's state and commands for the SwiftUI chrome around it
/// (jump button, top-trailing controls, `onDisappear`) — the Mac twin of
/// iOS `ChatTimelineBridge`.
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
