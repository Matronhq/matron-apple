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
    /// `MacChatView.respondsToMenuCommands`: only the main chat column's
    /// timeline registers the DEBUG perf probe.
    let registersPerfProbe: Bool

    func makeNSViewController(context: Context) -> MacTimelineController {
        Self.makeController(viewModel: viewModel, stripViewModel: stripViewModel, bridge: bridge,
                            selection: selection, actions: actions, registersPerfProbe: registersPerfProbe)
    }

    /// `makeNSViewController`'s body, callable without a SwiftUI context
    /// (tests drive the pane-toggle order through it).
    ///
    /// A structural branch move (the sub-chat pane toggling) makes this
    /// controller BEFORE the old one's `tearDown`; the new one's `mount()`
    /// reads the room's remembered position in `init`. Store it now from the
    /// OLD controller (the bridge's weak `controller` is still it); its later
    /// `tearDown` then leaves that entry alone.
    static func makeController(viewModel: ChatViewModel, stripViewModel: SubChatStripViewModel,
                               bridge: MacTimelineBridge, selection: MessageSelectionController,
                               actions: MacTimelineActions, registersPerfProbe: Bool,
                               cache: MacTimelineMeasureCache = .shared) -> MacTimelineController {
        bridge.storeScrollPosition()
        return MacTimelineController(viewModel: viewModel, stripViewModel: stripViewModel, bridge: bridge,
                                     selection: selection, actions: actions, cache: cache,
                                     registersPerfProbe: registersPerfProbe)
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

    /// `MacTimelineView.makeNSViewController`, before a replacement
    /// controller mounts: remember (or forget) this room's position from the
    /// CURRENT controller's real follow state. A no-op when there is none,
    /// or once it is torn down — its `tearDown` has already stored.
    func storeScrollPosition() { controller?.session.storeScrollPosition() }
}
