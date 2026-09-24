import SwiftUI

/// The one-tap answers an agent attached to a tracker item (item action
/// buttons, contract 2026-09-24), drawn under the body card. Tapping one
/// answers exactly as typing its label would. The chosen one is filled
/// and checked and does nothing when tapped again; the others stay
/// tappable so the user can change their mind.
///
/// Plain SwiftUI buttons, deliberately outside the Mac thread's
/// `SelectableMessageText` cards: they are controls, not selectable text,
/// and a drag across the thread passes over them.
struct ItemActionButtons: View {
    let actions: [String]
    let selected: String?
    let onChoose: (String) -> Void

    var body: some View {
        // Side by side when the labels fit the measure, stacked when they
        // don't — four 40-character labels never fit a phone's width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        ForEach(actions, id: \.self) { label in
            button(label)
        }
    }

    @ViewBuilder
    private func button(_ label: String) -> some View {
        if label == selected {
            Button {} label: { chosenLabel(label) }
                .buttonStyle(.borderedProminent)
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("item-action-\(label)")
        } else {
            Button { onChoose(label) } label: { Text(label).fixedSize() }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .accessibilityIdentifier("item-action-\(label)")
        }
    }

    private func chosenLabel(_ label: String) -> some View {
        Label(label, systemImage: "checkmark").fixedSize()
    }
}
