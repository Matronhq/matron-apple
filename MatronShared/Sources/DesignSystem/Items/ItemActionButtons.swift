import SwiftUI

/// The one-tap answers an agent attached to a tracker item (item action
/// buttons, contract 2026-09-24), drawn under the body card. Tapping one
/// answers exactly as typing its label would. The chosen one is filled
/// and checked and does nothing when tapped again; the others stay
/// tappable so the user can change their mind. Every button is disabled
/// while the item has a write in flight (`isEnabled` false — a close,
/// say): a tap racing a close would reopen the item it closes.
///
/// Plain SwiftUI buttons, deliberately outside the Mac thread's
/// `SelectableMessageText` cards: they are controls, not selectable text,
/// and a drag across the thread passes over them.
struct ItemActionButtons: View {
    let actions: [String]
    let selected: String?
    let isEnabled: Bool
    let onChoose: (String) -> Void

    /// What one button renders as — the whole of the row's logic, so it
    /// is pinned without a view inspector.
    struct ButtonState: Equatable {
        let label: String
        let isChosen: Bool
        let isEnabled: Bool
    }

    static func states(actions: [String], selected: String?, isEnabled: Bool) -> [ButtonState] {
        actions.map { ButtonState(label: $0, isChosen: $0 == selected, isEnabled: isEnabled) }
    }

    var body: some View {
        // Side by side when the labels fit the measure on one line each,
        // stacked when they don't — four 40-character labels never fit a
        // phone's width, and a stacked label wraps rather than overflow.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(stacked: false) }
            VStack(alignment: .leading, spacing: 8) { buttons(stacked: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(stacked: Bool) -> some View {
        ForEach(Self.states(actions: actions, selected: selected, isEnabled: isEnabled), id: \.label) { state in
            button(state, stacked: stacked)
        }
    }

    @ViewBuilder
    private func button(_ state: ButtonState, stacked: Bool) -> some View {
        if state.isChosen {
            Button {} label: { labelText(Label(state.label, systemImage: "checkmark"), stacked: stacked) }
                .buttonStyle(.borderedProminent)
                .disabled(!state.isEnabled)
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("item-action-\(state.label)")
        } else {
            Button { onChoose(state.label) } label: { labelText(Text(state.label), stacked: stacked) }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(!state.isEnabled)
                .accessibilityIdentifier("item-action-\(state.label)")
        }
    }

    /// Side by side, a label keeps its one-line width so `ViewThatFits`
    /// measures the row honestly; stacked, it may wrap to the measure.
    @ViewBuilder
    private func labelText<L: View>(_ label: L, stacked: Bool) -> some View {
        if stacked {
            label.fixedSize(horizontal: false, vertical: true)
        } else {
            label.fixedSize()
        }
    }
}
