import SwiftUI
import MatronModels

/// A multi-select question's answers (`multi_select` on an item or a
/// follow-up comment): every label as a row with a tick box, then Send.
/// Ticking sends nothing; Send posts every ticked label as one answer, and
/// stays disabled until something is ticked that differs from the latest
/// answer. Once answered, the answer's labels show ticked and a line says
/// so; changing the ticks and sending again replaces it, as re-tapping a
/// one-tap button does. Every row and Send are disabled while the item
/// has a write in flight (`isEnabled` false).
///
/// Plain SwiftUI controls, like `ItemActionButtons`: they sit outside the
/// thread's selectable text.
struct ItemMultiSelectList: View {
    let state: ItemMultiSelectState
    let isEnabled: Bool
    /// Leads each control's accessibility identifier; a comment's list
    /// passes its own so each stays addressable.
    var identifierPrefix = "item-multi"
    let onToggle: (String) -> Void
    let onSend: () -> Void

    /// What one row renders as — the row logic, pinned without a view
    /// inspector.
    struct RowState: Equatable {
        let label: String
        let isTicked: Bool
    }

    static func rows(_ state: ItemMultiSelectState) -> [RowState] {
        state.labels.map { RowState(label: $0, isTicked: state.ticked.contains($0)) }
    }

    /// Whether the "Answered" line shows: answered, and the ticks are the
    /// answer (no unsent edit).
    static func showsAnswered(_ state: ItemMultiSelectState) -> Bool {
        state.isAnswered && state.ticked == state.answered
    }

    #if os(macOS)
    private static let tickedGlyph = "checkmark.square.fill"
    private static let untickedGlyph = "square"
    #else
    private static let tickedGlyph = "checkmark.circle.fill"
    private static let untickedGlyph = "circle"
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                let rows = Self.rows(state)
                ForEach(Array(rows.enumerated()), id: \.element.label) { index, row in
                    if index > 0 { Divider().padding(.leading, 36) }
                    rowView(row)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.matronBubbleBot)
                    .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
            )
            HStack(spacing: 10) {
                Button(action: onSend) {
                    Text("Send").frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled || !state.canSend)
                .accessibilityIdentifier("\(identifierPrefix)-send")
                if Self.showsAnswered(state) {
                    Label("Answered", systemImage: "checkmark")
                        .font(ItemTypography.captionDetailFont)
                        .foregroundStyle(.secondary)
                } else if state.ticked.isEmpty {
                    Text("Tick one or more")
                        .font(ItemTypography.captionDetailFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(_ row: RowState) -> some View {
        Button { onToggle(row.label) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: row.isTicked ? Self.tickedGlyph : Self.untickedGlyph)
                    .foregroundStyle(row.isTicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                Text(verbatim: row.label)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(row.isTicked ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix)-\(row.label)")
    }
}
