import SwiftUI
import MatronModels

/// Drop-down palette that surfaces the current `BotCommand` matches above
/// the composer. Item taps go through `onSelect`, which is wired to
/// `ComposerViewModel.selectCommand(_:)` so the input prefills with
/// `<trigger> ` and the palette dismisses.
struct SlashCommandPalette: View {
    let commands: [BotCommand]
    /// Recent-folder suggestions for `/start` / `/workdir` completion. When
    /// non-empty, the palette shows folder rows instead of commands (the
    /// two modes are mutually exclusive upstream, but folders win here).
    let folders: [String]
    let onSelect: (BotCommand) -> Void
    let onSelectFolder: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !folders.isEmpty {
                    ForEach(folders, id: \.self) { folder in
                        Button {
                            onSelectFolder(folder)
                        } label: {
                            folderRow(for: folder)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                } else {
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
        }
        .frame(maxHeight: 220)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func folderRow(for path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
