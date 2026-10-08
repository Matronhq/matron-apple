import SwiftUI

/// In-conversation search bar (WhatsApp-style), shared by the iOS and Mac
/// chat views. Renders the query field, the "n of m" position, and
/// older/newer chevrons; all state lives in `ChatViewModel.chatSearch` —
/// this view is a dumb projection over plain values + closures so the
/// design system stays ignorant of view models.
///
/// Chevron semantics follow the transcript, not the list: ∧ steps OLDER
/// (up into history), ∨ steps back toward the newest match. Matches are
/// ordered newest-first upstream, so "older" is the higher index.
public struct ChatSearchBar: View {
    @Binding var query: String
    /// Total matches for the submitted query.
    let matchCount: Int
    /// 0-based index of the focused match in the newest-first order.
    let matchIndex: Int
    let onSubmit: () -> Void
    let onOlder: () -> Void
    let onNewer: () -> Void
    let onClose: () -> Void
    /// Opened with nothing searched yet (Find in Chat): no "No matches"
    /// verdict.
    let isAwaitingQuery: Bool
    /// A pending request to focus the field
    /// (`ChatViewModel.chatSearchWantsFieldFocus`), honoured on appear or
    /// when it turns on; `onFieldFocused` reports it handled, so a later
    /// remount of the bar doesn't take focus again.
    let wantsFieldFocus: Bool
    let onFieldFocused: () -> Void
    /// Whether Escape closes the bar while its field is NOT focused. With
    /// two chats on screen (the Mac Coordinator panel beside the main
    /// chat) each passes `false`, so Escape closes only the bar being
    /// typed in rather than whichever SwiftUI picks.
    let closesOnEscapeUnfocused: Bool

    @FocusState private var fieldFocused: Bool

    public init(query: Binding<String>, matchCount: Int, matchIndex: Int,
                isAwaitingQuery: Bool = false, wantsFieldFocus: Bool = false,
                onFieldFocused: @escaping () -> Void = {},
                closesOnEscapeUnfocused: Bool = true,
                onSubmit: @escaping () -> Void, onOlder: @escaping () -> Void,
                onNewer: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._query = query
        self.matchCount = matchCount
        self.matchIndex = matchIndex
        self.isAwaitingQuery = isAwaitingQuery
        self.wantsFieldFocus = wantsFieldFocus
        self.onFieldFocused = onFieldFocused
        self.closesOnEscapeUnfocused = closesOnEscapeUnfocused
        self.onSubmit = onSubmit
        self.onOlder = onOlder
        self.onNewer = onNewer
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // Not auto-focused when opened by a search-result tap: that bar
            // appears mid-jump-to-match, and popping the keyboard (iOS)
            // would cover the very message the jump landed on. Find in
            // Chat opens it awaiting a query, and focuses it.
            TextField("Search in chat", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(onSubmit)
            Text(positionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                // Fixed at the widest realistic label so stepping through
                // matches doesn't wobble the chevrons.
                .frame(minWidth: 64, alignment: .trailing)
            Button(action: onOlder) {
                Image(systemName: "chevron.up")
            }
            .disabled(matchIndex + 1 >= matchCount)
            .help("Older match")
            .accessibilityLabel("Older match")
            Button(action: onNewer) {
                Image(systemName: "chevron.down")
            }
            .disabled(matchIndex <= 0)
            .help("Newer match")
            .accessibilityLabel("Newer match")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .keyboardShortcut(fieldFocused || closesOnEscapeUnfocused ? .cancelAction : nil)
            .help("Done")
            .accessibilityLabel("Close search")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { if wantsFieldFocus { focusField() } }
        .onChange(of: wantsFieldFocus) { _, wants in if wants { focusField() } }
    }

    /// Next runloop turn: a focus write in the same pass the field is
    /// inserted is dropped.
    private func focusField() {
        onFieldFocused()
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var positionLabel: String {
        Self.positionLabel(matchCount: matchCount, matchIndex: matchIndex, isAwaitingQuery: isAwaitingQuery)
    }

    static func positionLabel(matchCount: Int, matchIndex: Int, isAwaitingQuery: Bool) -> String {
        if isAwaitingQuery { return "" }
        return matchCount == 0 ? "No matches" : "\(matchIndex + 1) of \(matchCount)"
    }
}
