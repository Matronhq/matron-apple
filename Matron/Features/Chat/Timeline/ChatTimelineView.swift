import SwiftUI
import MatronViewModels

/// Hosts `ChatTimelineController` in `ChatView` (spec §2 Structure).
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
        // Stores the scroll position too (review F6): SwiftUI may dismantle
        // this before ChatView's `onDisappear`, whose bridge call would then
        // find no controller.
        controller.tearDown()
    }
}
