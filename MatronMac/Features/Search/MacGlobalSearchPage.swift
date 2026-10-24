import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The Search page in the window's main column (Go ▸ Search…, ⌘K or ⌘J,
/// and the nav column's Search entry): the shared page with its own field,
/// focused when the page opens. Return opens a number, as Go to Number
/// did; a row's tap goes to `onOpen`, which the window routes.
struct MacGlobalSearchPage: View {
    @Bindable var viewModel: GlobalSearchViewModel
    let onOpen: (GlobalSearchTarget) -> Void

    var body: some View {
        GlobalSearchView(text: $viewModel.query, filter: $viewModel.filter, page: viewModel.page,
                         onSubmit: { Task { await viewModel.submit() } },
                         onOpen: onOpen)
            // Keyed on the text so each keystroke cancels the run before
            // it — the view model waits out a typing pause first.
            .task(id: viewModel.query) { await viewModel.search() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
