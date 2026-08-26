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

    public init(query: Binding<String>, matchCount: Int, matchIndex: Int,
                onSubmit: @escaping () -> Void, onOlder: @escaping () -> Void,
                onNewer: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._query = query
        self.matchCount = matchCount
        self.matchIndex = matchIndex
        self.onSubmit = onSubmit
        self.onOlder = onOlder
        self.onNewer = onNewer
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // Deliberately NOT auto-focused: the bar usually appears mid-
            // jump-to-match, and popping the keyboard (iOS) would cover the
            // very message the jump landed on. Tap/click the field to edit.
            TextField("Search in chat", text: $query)
                .textFieldStyle(.plain)
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
            .keyboardShortcut(.cancelAction)
            .help("Done")
            .accessibilityLabel("Close search")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var positionLabel: String {
        matchCount == 0 ? "No matches" : "\(matchIndex + 1) of \(matchCount)"
    }
}
