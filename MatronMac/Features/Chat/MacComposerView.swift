import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronViewModels

/// Mac-tailored shell around the shared `ComposerViewModel`. Mirrors the
/// iOS `ComposerView` body — slash palette stacked above a growing-height
/// `TextField`, paperclip button on the left, send button on the right —
/// but uses `NSOpenPanel` for file picking and the `Pasteboard` cross-
/// platform helper instead of `UIPasteboard`.
///
/// `isSendable` mirrors the iOS predicate (trim → check for non-empty) so
/// the send button is disabled for whitespace-only input. Keeping the
/// predicate matched between the two app shells means
/// `ComposerViewModel.send()`'s no-op behaviour is consistent: the button
/// reflects what `send()` will actually do.
struct MacComposerView: View {
    @State var viewModel: ComposerViewModel

    /// Internal so `MacComposerViewBindingTests` can pin the predicate
    /// without scraping SwiftUI internals (mirrors the iOS surface).
    var isSendable: Bool {
        !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showPalette {
                MacSlashCommandPalette(commands: viewModel.filteredCommands) { cmd in
                    viewModel.selectCommand(cmd)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            HStack(alignment: .bottom, spacing: 4) {
                Button {
                    pickFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Attach a file")

                TextField("Message…", text: $viewModel.input, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(isSendable ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isSendable || viewModel.isSending)
                .padding(.trailing, 4)
                // Enter sends; Shift+Enter / Option+Enter inserts a
                // newline (the TextField handles the modifier path
                // natively — only plain Return is intercepted by this
                // shortcut, matching Slack / Discord conventions).
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
    }

    /// Opens an `NSOpenPanel` and forwards the selection to
    /// `ComposerViewModel.attachFiles(_:)`. The Mac sandbox grants the
    /// app read access to user-selected files via the
    /// `com.apple.security.files.user-selected.read-only` entitlement
    /// (set in `MatronMac.entitlements`), so we don't need
    /// security-scoped-resource bracketing here — the iOS
    /// `fileImporter` site does, but that's an iOS-specific quirk.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await viewModel.attachFiles(urls) }
    }
}
