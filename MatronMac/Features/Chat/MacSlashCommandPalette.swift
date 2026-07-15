import SwiftUI
import MatronDesignSystem
import MatronModels

/// Mac-side mirror of `Matron/Features/Chat/Composer/SlashCommandPalette`,
/// extended with Mac affordances the iOS palette doesn't need: a keyboard
/// highlight (`selection`, driven by the composer's arrow keys), per-row
/// hover highlighting, and shrink-to-fit height. Duplicated rather than
/// promoted to `MatronDesignSystem` to avoid pulling `MatronModels` into
/// the design-system target's dependency graph for one view.
///
/// The panel floats over the timeline (the composer overlays it above the
/// input instead of stacking it in layout), so it hugs its rows: the row
/// stack's measured height caps the scroll frame, and only lists taller
/// than `maxHeight` scroll. A fixed-height panel here would hold a mostly
/// empty pane over the conversation for short lists.
struct MacSlashCommandPalette: View {
    let commands: [BotCommand]
    /// Recent-folder suggestions for `/start` / `/workdir` completion. When
    /// non-empty, the palette shows folder rows instead of commands (the
    /// two modes are mutually exclusive upstream, but folders win here).
    let folders: [String]
    /// Keyboard-highlighted row index (`ComposerViewModel.paletteSelection`),
    /// or `nil` when the arrow keys haven't picked a row.
    let selection: Int?
    let onSelect: (BotCommand) -> Void
    let onSelectFolder: (String) -> Void

    /// Measured height of the row stack — drives shrink-to-fit.
    @State private var contentHeight: CGFloat = 0
    private static let maxHeight: CGFloat = 220

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !folders.isEmpty {
                        ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                            PaletteRow(index: index, isSelected: index == selection) {
                                onSelectFolder(folder)
                            } label: {
                                folderRow(for: folder)
                            }
                            Divider()
                        }
                    } else {
                        ForEach(Array(commands.enumerated()), id: \.element) { index, cmd in
                            PaletteRow(index: index, isSelected: index == selection) {
                                onSelect(cmd)
                            } label: {
                                row(for: cmd)
                            }
                            Divider()
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    contentHeight = $0
                }
            }
            // Keep the keyboard highlight visible when the list is tall
            // enough to scroll.
            .onChange(of: selection) { _, newValue in
                if let newValue {
                    proxy.scrollTo(newValue)
                }
            }
        }
        .frame(height: min(contentHeight, Self.maxHeight))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // The panel floats over timeline content, so it needs elevation
        // the stacked-in-layout version didn't.
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
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

/// One palette row: click to pick, tinted when it carries the keyboard
/// highlight, lightly washed under the pointer. `.id(index)` anchors the
/// composer-driven `scrollTo` for lists taller than the panel.
private struct PaletteRow<Label: View>: View {
    let index: Int
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .background(
                    isSelected
                        ? Color.matronAccent.opacity(0.18)
                        : hovering ? Color.primary.opacity(0.06) : Color.clear
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .id(index)
    }
}
