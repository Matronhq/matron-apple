import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// Go ▸ Go to Number… (⌘J) and the nav column's button: the shared number
/// field as a small sheet on the window. A sheet rather than a popover so
/// the menu command has somewhere to show it with the sidebar collapsed.
struct MacGoToNumberSheet: View {
    @Bindable var viewModel: GoToNumberViewModel
    /// Dismisses the sheet. Opening the target is the view model's `open`.
    let onDone: () -> Void

    var body: some View {
        GoToNumberView(text: $viewModel.text, outcome: viewModel.outcome, isOpening: viewModel.isOpening,
                       canGo: viewModel.canGo,
                       onGo: { Task { if await viewModel.submit() { onDone() } } },
                       onCancel: {
                           viewModel.cancel()
                           onDone()
                       })
            // Looked up as it is typed; a newer keystroke cancels the wait.
            .task(id: viewModel.text) { await viewModel.lookUp() }
    }
}

private extension GoToNumberViewModel {
    /// The view model's status in the shared view's plain values.
    var outcome: GoToNumberView.Outcome {
        switch status {
        case .idle: return .hint
        case .looking: return .looking
        case .found(let hit): return .found(heading: hit.heading, title: hit.title, note: hit.cannotOpenReason)
        case .nothing(let message): return .nothing(message)
        case .failed(let message): return .failed(message)
        }
    }
}
