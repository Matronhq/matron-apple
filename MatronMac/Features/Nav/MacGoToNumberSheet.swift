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
        GoToNumberView(text: $viewModel.text, message: viewModel.message, isBusy: viewModel.isBusy,
                       canGo: viewModel.canGo,
                       onGo: { Task { if await viewModel.submit() { onDone() } } },
                       onCancel: {
                           viewModel.cancel()
                           onDone()
                       })
    }
}
