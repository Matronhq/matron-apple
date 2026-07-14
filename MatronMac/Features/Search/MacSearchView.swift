import SwiftUI
import AppKit
import MatronDesignSystem
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
            // Hand-rolled field so we control the height: a plain style with
            // generous vertical padding on a warm rounded surface reads
            // taller and less cramped than `.roundedBorder`/`.large` did at
            // the top of the sidebar. The `matronBubbleBot` fill matches the
            // bot-bubble / composer surface; a hairline separator stroke
            // keeps it reading as a field.
            .textFieldStyle(.plain)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.matronBubbleBot)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
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
