import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronViewModels

/// iOS message composer. Stacks an optional `SlashCommandPalette` on top of
/// a single-line-but-growing `TextField`, with the `AttachmentPicker` and
/// the send button on either side. PhotosPicker selections and file-importer
/// URLs both route through `ComposerViewModel.attachFiles(_:)`, which
/// already dispatches to `sendImage` / `sendFile` based on MIME prefix
/// (`MatronShared/Sources/ViewModels/ComposerViewModel.swift`).
struct ComposerView: View {
    @State var viewModel: ComposerViewModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false

    /// Mirrors `ComposerViewModel.send()`'s own trim so the send button is
    /// disabled for whitespace-only input. Without this, the button looks
    /// active but `send()` no-ops on the trimmed empty string.
    /// `internal` so `ComposerViewBindingTests` can assert this matches
    /// `send()`'s behaviour without scraping SwiftUI internals.
    var isSendable: Bool {
        !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showPalette {
                SlashCommandPalette(commands: viewModel.filteredCommands) { cmd in
                    viewModel.selectCommand(cmd)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            HStack(alignment: .bottom, spacing: 4) {
                AttachmentPicker(photoItem: $photoItem, showFileImporter: $showFileImporter)

                TextField("Message…", text: $viewModel.input, axis: .vertical)
                    .lineLimit(1...8)
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
                .disabled(!isSendable || viewModel.isSending)
                .padding(.trailing, 4)
            }
            .padding()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                // Photo path: the picker hands back transferable Data; we
                // materialise it to a temporary URL so we can reuse
                // `attachFiles(_:)` (which keys MIME off the path
                // extension). The previous impl tried to parse a filename
                // out of `itemIdentifier`, but that value is a PHAsset
                // local identifier (UUID-shaped) — never a URL — so the
                // fallback `"photo.jpg"` always won and HEIC / PNG
                // selections were sent as `image/jpeg`. We instead pick
                // the best file extension from the item's
                // `supportedContentTypes`, which the picker populates
                // accurately (HEIC for HEIC, PNG for PNG, …).
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let ext = preferredExtension(for: newItem) ?? "jpg"
                    let tmp = ComposerView.photoTempURL(ext: ext)
                    try? data.write(to: tmp)
                    await viewModel.attachFiles([tmp])
                }
                photoItem = nil
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                // URLs from `fileImporter` are security-scoped on physical
                // devices; reading them without
                // `startAccessingSecurityScopedResource()` returns
                // permission-denied errors that the previous `try?` was
                // silently swallowing. We materialise the bytes here, then
                // hand the staged temporary URL to `attachFiles(_:)`.
                Task { await stageAndAttach(urls) }
            case .failure(let error):
                viewModel.reportAttachmentError(error.localizedDescription)
            }
        }
    }

    /// Picks the best filename extension for a `PhotosPickerItem` using
    /// its `supportedContentTypes`. Returns `nil` when the picker hasn't
    /// declared a content type with a preferred extension. The first
    /// type whose preferred extension is concrete (heic / png / gif /
    /// jpeg / …) wins, which keeps HEIC / PNG / GIF selections in their
    /// native format instead of always being relabelled JPEG.
    private func preferredExtension(for item: PhotosPickerItem) -> String? {
        for type in item.supportedContentTypes {
            if let ext = type.preferredFilenameExtension { return ext }
        }
        return nil
    }

    /// Builds a unique temporary URL for a `PhotosPicker` selection. The
    /// previous fixed `"photo.\(ext)"` filename collided when the user
    /// picked two photos of the same type in quick succession — the
    /// second `data.write(to:)` clobbered the first file before
    /// `attachFiles(_:)` had finished reading it. Including a `UUID`
    /// guarantees each selection lands at its own URL. `static internal`
    /// so `ComposerViewBindingTests` can assert the uniqueness.
    static func photoTempURL(ext: String) -> URL {
        let filename = "photo-\(UUID().uuidString).\(ext)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    /// Reads each security-scoped URL into a temporary file so
    /// `ComposerViewModel.attachFiles(_:)` can read it without needing the
    /// scope (which only the `fileImporter` callback owns). Surfaces read
    /// errors via the view model instead of dropping them.
    private func stageAndAttach(_ urls: [URL]) async {
        var staged: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try data.write(to: tmp)
                staged.append(tmp)
            } catch {
                viewModel.reportAttachmentError(error.localizedDescription)
            }
        }
        if !staged.isEmpty {
            await viewModel.attachFiles(staged)
        }
    }
}
