import SwiftUI
import MatronViewModels

/// Mac toolbar search field. Lives in the chat-window toolbar; a non-empty
/// query swaps the detail column for `MacSearchResultsView` (wired in
/// `MacChatListView`). `⌘F` ("Find in Chat" menu item) flips `focusRequest`,
/// which this view turns into a `@FocusState` focus on the field.
struct MacSearchView: View {
    @Bindable var viewModel: SearchViewModel
    @FocusState private var isFieldFocused: Bool
    /// Set to `true` from the menu's `⌘F` action to programmatically focus the
    /// field; reset to `false` here once focus is taken.
    @Binding var focusRequest: Bool

    var body: some View {
        TextField("Search", text: $viewModel.query)
            .textFieldStyle(.roundedBorder)
            // Taller hit target than the default control height — the
            // stock field read cramped at the top of the sidebar.
            .controlSize(.large)
            .frame(minWidth: 200)
            .focused($isFieldFocused)
            .onChange(of: viewModel.query) { _, _ in
                Task { await viewModel.search() }
            }
            .onChange(of: focusRequest) { _, newValue in
                if newValue {
                    isFieldFocused = true
                    focusRequest = false
                }
            }
    }
}
