import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The Search tab's root: the shared Search page under the system search
/// field. Return in the field opens a number, as "Go to number" did; a
/// row's tap goes to `onOpen`, which the shell routes.
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
            .searchable(text: $viewModel.query,
                        // Always showing under the large title, as on For you
                        // and Conversations: a plain tab, not the system's
                        // search tab, gets no field of its own otherwise.
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: GlobalSearchView.placeholder)
            .onSubmit(of: .search, submit)
            // Keyed on the text so each keystroke cancels the run before
            // it — the view model waits out a typing pause first.
            .task(id: viewModel.query) { await viewModel.search() }
    }

    private func submit() {
        Task { await viewModel.submit() }
    }
}
