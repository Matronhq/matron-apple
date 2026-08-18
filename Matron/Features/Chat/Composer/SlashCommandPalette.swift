import SwiftUI
import MatronModels
import MatronViewModels

/// Drop-down palette that surfaces the current `BotCommand` matches above
/// the composer. Item taps go through `onSelect`, which is wired to
/// `ComposerViewModel.selectCommand(_:)` so the input prefills with
/// `<trigger> ` and the palette dismisses.
struct SlashCommandPalette: View {
    let commands: [BotCommand]
    /// Argument/folder suggestions for a fully-typed command. When
    /// non-empty, the palette shows suggestion rows instead of commands
    /// (the two modes are mutually exclusive upstream, but suggestions
    /// win here).
    let suggestions: [PaletteSuggestion]
    let onSelect: (BotCommand) -> Void
    let onSelectSuggestion: (PaletteSuggestion) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !suggestions.isEmpty {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            onSelectSuggestion(suggestion)
                        } label: {
                            suggestionRow(for: suggestion)
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

    @ViewBuilder
    private func suggestionRow(for suggestion: PaletteSuggestion) -> some View {
        switch suggestion {
        case .folder(let path): folderRow(for: path)
        case .argument(let argument): argumentRow(for: argument)
        }
    }

    private func argumentRow(for argument: ArgSuggestion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(argument.displayLabel)
                    .font(.system(.body, design: .monospaced))
                    .bold()
                if let summary = argument.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
