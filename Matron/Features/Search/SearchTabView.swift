import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The Search tab's root: the shared Search page under the system search
/// field. Return in the field puts the keyboard away and opens a number,
/// as "Go to number" did; scrolling the results, or swiping down from the
/// field, puts it away too. A row's
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
            // The field sits in the tab bar right on top of the keyboard,
            // where "swipe the keyboard down" usually starts, and outside
            // this view, so the swipe is watched on the whole window.
            .swipeDownInWindowDismissesKeyboard()
            .modifier(SearchField(text: $viewModel.query))
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

/// The tab's search field. Up to iOS 26 a search-role tab's field sits at
/// the bottom in the tab bar's place. From iOS 27 the system draws it in
/// the navigation bar's drawer, hidden until the list is pulled down, and
/// the results page's pinned filter row stops that pull from reaching it;
/// so there it is always shown.
private struct SearchField: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                               prompt: GlobalSearchView.placeholder)
        } else {
            content.searchable(text: $text, prompt: GlobalSearchView.placeholder)
        }
    }
}
