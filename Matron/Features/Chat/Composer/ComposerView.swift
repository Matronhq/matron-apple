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
                        .foregroundStyle(viewModel.input.isEmpty ? Color.secondary : Color.accentColor)
                }
                .disabled(viewModel.input.isEmpty || viewModel.isSending)
                .padding(.trailing, 4)
            }
            .padding()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                // Photo path: the picker hands back transferable Data + a
                // suggested filename. We materialise the Data to a temporary
                // URL so we can reuse `attachFiles(_:)` (which keys MIME off
                // the path extension).
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    let suggestedName = newItem.itemIdentifier.flatMap { id in
                        URL(string: id)?.lastPathComponent
                    } ?? "photo.jpg"
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
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
                Task { await viewModel.attachFiles(urls) }
            case .failure:
                // Importer cancellation/failure surfaces here; ComposerViewModel's
                // own error reporting is reserved for actual send failures.
                break
            }
        }
    }
}
