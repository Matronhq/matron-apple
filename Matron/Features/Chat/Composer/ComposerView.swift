import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MatronChat
import MatronDesignSystem
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
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var recorder = VoiceRecorder()

    /// The text field's padding (all edges). Named so the single-line
    /// height below stays tied to it: if the padding changes, the
    /// accessory-button height follows.
    private static let inputPadding: CGFloat = 8

    /// Rendered height of a one-line input: the body font's line height
    /// plus the field's vertical padding top and bottom. The plus, mic,
    /// and send buttons pin their icon containers to this so they sit
    /// centred against a single-line field (the HStack stays `.bottom`
    /// aligned, so on a grown multi-line field they drop to the bottom
    /// edge). Mirrors `MacComposerView.singleLineInputHeight`.
    private static var singleLineInputHeight: CGFloat {
        let body = UIFont.preferredFont(forTextStyle: .body)
        return ceil(body.lineHeight) + inputPadding * 2
    }

    /// Mirrors `ComposerViewModel.send()`'s own no-op guard so the send
    /// button is never active for something `send()` would ignore.
    /// Delegates to `canSend` rather than re-deriving it: a staged
    /// attachment is a sendable message with no text at all, and having the
    /// view decide that separately is how the two drift apart.
    /// `internal` so `ComposerViewBindingTests` can assert this matches
    /// `send()`'s behaviour without scraping SwiftUI internals.
    var isSendable: Bool { viewModel.canSend }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showPalette {
                SlashCommandPalette(
                    commands: viewModel.filteredCommands,
                    folders: viewModel.folderSuggestions,
                    onSelect: { cmd in viewModel.selectCommand(cmd) },
                    onSelectFolder: { folder in viewModel.selectFolder(folder) }
                )
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            if case let .recording(start) = recorder.state {
                recordingBar(start: start)
            } else {
                composerBar
            }
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
                // Surface load failures via `reportAttachmentError` instead
                // of silently dropping the selection — the previous `try?`
                // swallowed iCloud-not-downloaded / corrupt-asset / unsupported-
                // format errors and the user got no feedback (bugbot caught it).
                do {
                    if let data = try await newItem.loadTransferable(type: Data.self) {
                        let ext = preferredExtension(for: newItem) ?? "jpg"
                        let tmp = ComposerView.photoTempURL(ext: ext)
                        await ComposerView.stagePhotoData(data, to: tmp, viewModel: viewModel)
                    } else {
                        viewModel.reportAttachmentError("Couldn't load that photo. If it's stored in iCloud, try downloading it first.")
                    }
                } catch {
                    viewModel.reportAttachmentError(error.localizedDescription)
                }
                photoItem = nil
            }
        }
        // Presented HERE, not from the plus menu's row: a PhotosPicker
        // inside a Menu never appears (the menu's dismissal takes its
        // presentation context with it). `photoLibrary: .shared()` is
        // required for `PhotosPickerItem.supportedContentTypes` to be
        // populated — without it every selection falls back to jpg and
        // HEIC/PNG are mislabelled `image/jpeg`.
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoItem,
            matching: .images,
            photoLibrary: .shared()
        )
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
        // Restore any draft the user typed in this room earlier in the
        // session. `.task` runs on view appear; the per-room cache
        // survives navigation but resets on app quit (mirrors
        // `ChatScrollPositionMemory`). Only restores on a fresh, empty
        // composer so we don't clobber a slash-command selection that
        // already populated `input` synchronously above the timeline.
        .task {
            if viewModel.input.isEmpty,
               let draft = ComposerDraftMemory.retrieve(roomID: viewModel.roomID) {
                viewModel.input = draft
            }
        }
        // Capture whatever is in the composer when this view leaves the
        // hierarchy (back-nav to chat list, sheet dismiss, etc.). Empty
        // input clears the entry inside `store(roomID:text:)` so a sent
        // composer doesn't ghost text into the next visit.
        .onDisappear {
            ComposerDraftMemory.store(roomID: viewModel.roomID, text: viewModel.input)
            // An in-flight recording has no UI once this composer is gone —
            // abort it (discarding the temp file) rather than letting the
            // mic keep capturing with nothing to stop or send it.
            recorder.cancel()
        }
    }

    /// The normal composer row: plus (attach) on the left, growing text
    /// field, then either a mic (empty input) or the send button. The
    /// plus + mic are gated on `mediaAvailable` — the same one-flag gate the
    /// attach button already used — so both media surfaces disappear together
    /// if the server-side whitelist is ever turned back off.
    private var composerBar: some View {
        VStack(spacing: 0) {
            // Above the input, so what's about to be sent sits next to the
            // words being written about it.
            AttachmentTray(attachments: viewModel.stagedAttachments) { id in
                viewModel.removeAttachment(id: id)
            }
            inputRow
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if ComposerViewModel.mediaAvailable {
                AttachmentPicker(showPhotosPicker: $showPhotosPicker,
                                 showFileImporter: $showFileImporter)
                    .frame(height: Self.singleLineInputHeight)
            }

            TextField("Message…", text: $viewModel.input, axis: .vertical)
                .lineLimit(1...8)
                .padding(Self.inputPadding)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                // Lets the field accept pasted photos and files (it only
                // offers Paste for text on its own). Sits in a background so
                // it lands as a sibling of the field's backing text view,
                // which is what it goes looking for.
                .background(ComposerPasteSupport(viewModel: viewModel))

            // Mic when the field is empty (WhatsApp-style), send once the
            // user has typed. Falls back to the send button when media is
            // gated off so there's always a trailing action.
            if !isSendable && ComposerViewModel.mediaAvailable {
                Button {
                    Task { await startRecording() }
                } label: {
                    Image(systemName: "mic")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(height: Self.singleLineInputHeight)
                }
                .padding(.trailing, 4)
            } else {
                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(isSendable ? Color.accentColor : Color.secondary)
                        .frame(height: Self.singleLineInputHeight)
                }
                .disabled(!isSendable || viewModel.isSending)
                .padding(.trailing, 4)
            }
        }
        .padding()
    }

    /// The recording pill shown in place of the composer while a voice note
    /// is being captured: a pulsing red dot, live elapsed time, a Cancel
    /// affordance, and a prominent stop-and-send button.
    private func recordingBar(start: Date) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
            Text(start, style: .timer)
                .monospacedDigit()
                .foregroundStyle(.primary)
            Spacer()
            Button("Cancel") { recorder.cancel() }
                .foregroundStyle(.secondary)
            Button {
                stopRecordingAndSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding()
    }

    /// Starts a recording, surfacing permission / hardware failures through
    /// the same `sendError` channel the composer already uses for send and
    /// attachment errors.
    private func startRecording() async {
        do {
            try await recorder.start()
        } catch {
            viewModel.reportAttachmentError(error.localizedDescription)
        }
    }

    /// Stops the recording and hands the resulting file to the view model,
    /// which uploads it as an audio attachment and deletes the temp file.
    private func stopRecordingAndSend() {
        guard let result = recorder.stop() else { return }
        Task { await viewModel.sendVoiceNote(url: result.url, duration: result.duration) }
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

    /// Builds a unique temporary URL for a staged `fileImporter` selection.
    /// The previous impl appended `url.lastPathComponent` directly, so two
    /// source files with the same filename (different parent dirs) wrote
    /// to the same temp path — the second `data.write(to:)` clobbered the
    /// first before `attachFiles(_:)` had finished reading it. Embedding a
    /// `UUID` per selection guarantees distinct paths. `static internal`
    /// so `ComposerViewBindingTests` can assert the uniqueness directly.
    /// Mirrors `photoTempURL(ext:)` (round-2 fix #4). Forwards to
    /// `PastedAttachment.stagingURL(forName:)` so a staged pick and a staged
    /// paste can't drift apart on naming.
    static func stagedTempURL(for source: URL) -> URL {
        PastedAttachment.stagingURL(forName: source.lastPathComponent)
    }

    /// Writes `data` to `tmp` and hands the resulting URL to
    /// `ComposerViewModel.attachFiles(_:)`. On write failure, surfaces the
    /// real error via `reportAttachmentError(_:)` and skips the attach
    /// call — the previous `try? data.write(to: tmp)` silently swallowed
    /// disk-full / quota / sandbox-denial failures, then proceeded to
    /// `attachFiles`, which `Data(contentsOf:)`-failed with a confusing
    /// "No such file" instead of the original cause. `@MainActor` because
    /// `ComposerViewModel.reportAttachmentError(_:)` is main-actor-isolated.
    /// `static internal` so `ComposerViewBindingTests` can exercise the
    /// success and failure branches without rendering the SwiftUI view.
    @MainActor
    static func stagePhotoData(
        _ data: Data,
        to tmp: URL,
        viewModel: ComposerViewModel
    ) async {
        do {
            try data.write(to: tmp)
            await viewModel.attachFiles([tmp])
        } catch {
            viewModel.reportAttachmentError(error.localizedDescription)
        }
    }

    /// Reads each security-scoped URL into a temporary file so
    /// `ComposerViewModel.attachFiles(_:)` can read it without needing the
    /// scope (which only the `fileImporter` callback owns). Surfaces read
    /// errors via the view model instead of dropping them.
    ///
    /// The View owns the security-scoped wrap because the `Data(contentsOf:)`
    /// of the *original* URL has to happen inside the start/stop window —
    /// this is the only call site that touches a security-scoped URL.
    /// `attachFiles(_:)` no longer wraps because everything reaching it
    /// from this path is a temp URL we wrote ourselves (not security-scoped),
    /// and the Mac drop-delegate path passes URLs the sandbox already
    /// grants transparent read access to. Avoiding the redundant inner
    /// wrap keeps the scope contract on a single owner per call.
    private func stageAndAttach(_ urls: [URL]) async {
        var staged: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let tmp = ComposerView.stagedTempURL(for: url)
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
