import SwiftUI
import MatronDesignSystem
import MatronViewModels

/// The "Go to number" sheet: the shared number field at a small detent.
/// Presented by `AppShellView`, over whichever tab asked for it.
struct GoToNumberSheet: View {
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
            .presentationDetents([.height(220), .medium])
    }
}

/// What a tab asks the shell for: the number field, or a number opened
/// outright (a search row's tap).
struct GoToNumberActions {
    /// Shows the field, empty.
    var present: () -> Void
    /// Opens what `num` names. `nil` when it opened, otherwise the reason
    /// it did not, for the caller to show.
    var open: (Int) async -> String?
}

extension EnvironmentValues {
    /// Set by `AppShellView`; `nil` (previews, tests) draws no button.
    @Entry var goToNumber: GoToNumberActions? = nil
}

/// The toolbar's way in, on the For you and Projects tabs — the two lists
/// whose rows carry the numbers. Leading, so it sits in the same place on
/// both whatever each tab's own trailing buttons are.
struct GoToNumberButton: ToolbarContent {
    @Environment(\.goToNumber) private var goToNumber

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let goToNumber {
                Button { goToNumber.present() } label: { Image(systemName: "number") }
                    .accessibilityLabel("Go to number")
                    .accessibilityIdentifier("goto-number")
            }
        }
    }
}
