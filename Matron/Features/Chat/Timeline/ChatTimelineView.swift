import SwiftUI
import MatronViewModels

/// Hosts `ChatTimelineController` in `ChatView` in place of the
/// `ScrollViewReader`/`ScrollView` block (spec §2 Structure).
struct ChatTimelineView: UIViewControllerRepresentable {
    let viewModel: ChatViewModel
    let stripViewModel: SubChatStripViewModel
    let bridge: ChatTimelineBridge
    let actions: ChatTimelineActions

    func makeUIViewController(context: Context) -> ChatTimelineController {
        ChatTimelineController(viewModel: viewModel, stripViewModel: stripViewModel, bridge: bridge,
                               actions: actions, environment: TimelineHostedEnvironment(context.environment))
    }

    func updateUIViewController(_ controller: ChatTimelineController, context: Context) {
        controller.update(actions: actions, environment: TimelineHostedEnvironment(context.environment))
    }

    static func dismantleUIViewController(_ controller: ChatTimelineController, coordinator: ()) {
        // TODO(Task 24, review F6): store the scroll position here too
        // (`controller.storeScrollPosition()`), not only from ChatView's
        // `onDisappear` via the bridge's weak controller — SwiftUI may
        // dismantle this before `onDisappear` runs, and the weak store
        // would then silently do nothing.
        controller.tearDown()
    }
}
