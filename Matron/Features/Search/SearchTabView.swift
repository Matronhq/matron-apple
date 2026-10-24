import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The Search tab's root: the shared Search page under the system search
/// field. Return in the field puts the keyboard away and opens a number,
/// as "Go to number" did; scrolling the results puts it away too. A row's
/// tap goes to `onOpen`, which the shell routes.
struct SearchTabView: View {
    @Bindable var viewModel: GlobalSearchViewModel
    let onOpen: (GlobalSearchTarget) -> Void

    var body: some View {
        GlobalSearchView(text: $viewModel.query, filter: $viewModel.filter, page: viewModel.page,
                         showsField: false,
                         onSubmit: submit,
                         onOpen: { target in
                             KeyboardDismiss.resign()
                             onOpen(target)
                         })
            // As in the system's own search lists: the first drag of the
            // results puts the keyboard away.
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $viewModel.query, prompt: GlobalSearchView.placeholder)
            .onSubmit(of: .search, submit)
            // Keyed on the text so each keystroke cancels the run before
            // it — the view model waits out a typing pause first.
            .task(id: viewModel.query) { await viewModel.search() }
    }

    private func submit() {
        KeyboardDismiss.resign()
        Task { await viewModel.submit() }
    }
}
