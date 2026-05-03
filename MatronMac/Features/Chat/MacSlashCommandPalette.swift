import SwiftUI
import MatronModels

/// Mac-side mirror of `Matron/Features/Chat/Composer/SlashCommandPalette`.
/// The body is identical (pure SwiftUI, cross-platform) — duplicated rather
/// than promoted to `MatronDesignSystem` to avoid pulling `MatronModels`
/// into the design-system target's dependency graph for one view. Phase 7
/// polish can decide whether the palette belongs in DesignSystem.
struct MacSlashCommandPalette: View {
    let commands: [BotCommand]
    let onSelect: (BotCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.self) { cmd in
                    Button {
                        onSelect(cmd)
                    } label: {
                        row(for: cmd)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 220)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(for cmd: BotCommand) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cmd.trigger)
                        .font(.system(.body, design: .monospaced))
                        .bold()
                    if let hint = cmd.argHint {
                        Text(hint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(cmd.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
