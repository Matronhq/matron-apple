import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MatronChat
import MatronDesignSystem
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
    @State private var recorder = VoiceRecorder()

    /// Placeholder shown in the empty composer. Extracted to a single
    /// constant because the Shift+Return key monitor scopes itself to *this*
    /// field by matching the field editor's delegate `placeholderString`
    /// against it — the TextField initializer and the monitor must read the
    /// same value or the scope check silently breaks.
    private static let placeholder = "Message…"

    /// The input's vertical padding (top and bottom). Named so the
    /// single-line height below stays tied to it: if the padding changes,
    /// the accessory-button height follows.
    private static let inputVerticalPadding: CGFloat = 8

    /// Rendered height of a one-line input: the body font's line height plus
    /// the input's vertical padding top and bottom. The paperclip and send
    /// buttons pin their icon container to this so both accessories sit
    /// centred against a single-line field (the HStack stays `.bottom`
    /// aligned, so on a grown multi-line field they drop to the bottom edge).
    private static var singleLineInputHeight: CGFloat {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let lineHeight = ceil(body.ascender - body.descender + body.leading)
        return lineHeight + inputVerticalPadding * 2
    }

    /// Token for the Shift+Return local key monitor, installed in
    /// `.onAppear` and removed in `.onDisappear`. `Any?` because
    /// `NSEvent.addLocalMonitorForEvents` returns an opaque object.
    @State private var keyMonitor: Any?

    /// Internal so `MacComposerViewBindingTests` can pin the predicate
    /// without scraping SwiftUI internals (mirrors the iOS surface).
    var isSendable: Bool {
        !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showPalette {
                MacSlashCommandPalette(
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
        // Restore any draft the user typed in this room earlier in the
        // session. `.task` runs on view appear; the per-room cache
        // survives sidebar selection changes but resets on app quit
        // (mirrors `ChatScrollPositionMemory`). Only restores on a
        // fresh, empty composer so we don't clobber a slash-command
        // selection that already populated `input` synchronously.
        .task {
            if viewModel.input.isEmpty,
               let draft = ComposerDraftMemory.retrieve(roomID: viewModel.roomID) {
                viewModel.input = draft
            }
        }
        // Capture whatever is in the composer when this view leaves the
        // hierarchy (sidebar swap, window close, etc.). Empty input
        // clears the entry inside `store(roomID:text:)` so a sent
        // composer doesn't ghost text into the next visit.
        .onDisappear {
            // Mid-walk, `input` shows a recalled sent line, not the user's
            // draft — restore the stashed draft first so the store below
            // persists the real one.
            viewModel.exitHistoryNavigation()
            ComposerDraftMemory.store(roomID: viewModel.roomID, text: viewModel.input)
            // An in-flight recording has no UI once this composer is gone —
            // abort it (discarding the temp file) rather than letting the
            // mic keep capturing with nothing to stop or send it.
            recorder.cancel()
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
        // Shift+Return inserts a newline at the caret. A local key monitor
        // (rather than a `.keyboardShortcut`) is needed because SwiftUI's
        // `axis: .vertical` TextField doesn't newline on Shift+Return on its
        // own, and a shortcut can't insert at the caret position. The
        // monitor is scoped to THIS composer by matching the field editor's
        // delegate placeholder against `placeholder`, so the sidebar search
        // field (a different NSTextField) keeps plain Return behaviour.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 36,  // 36 = Return
                      event.modifierFlags.contains(.shift),
                      let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                      textView.isFieldEditor,
                      let field = textView.delegate as? NSTextField,
                      field.placeholderString == Self.placeholder else {
                    return event
                }
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return nil
            }
        }
    }

    /// The normal composer row: plus (attach) on the left, growing text
    /// field with the Up/Down history + edit key handling, then a mic
    /// (empty input) or the send button. Plus + mic are gated on
    /// `mediaAvailable`, mirroring iOS `ComposerView`.
    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // Journal stack: media DISPLAY is live server-side, but the
            // client send whitelist is text-only, so composing an
            // attachment would fail server-side. Gated on the VM flag
            // rather than deleted outright. Mirrors iOS `ComposerView`.
            if ComposerViewModel.mediaAvailable {
                Button {
                    pickFiles()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        // Centre the icon in a one-line-tall container so
                        // it lines up with the send button and the
                        // single-line input; horizontal padding keeps the
                        // hit target. See `singleLineInputHeight`.
                        .frame(height: Self.singleLineInputHeight)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
                .help("Attach a file")
            }

            TextField(Self.placeholder, text: $viewModel.input, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .padding(Self.inputVerticalPadding)
                // White (dark-mode: elevated warm) input surface, same
                // as bot bubbles — `.regularMaterial` read muddy-dark
                // against the cream timeline gradient. Matches
                // matron-web's white composer on the cream ground.
                .background(Color.matronBubbleBot)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
                // Up recalls older sent messages (terminal-style), but
                // only from an empty field or once a walk is already
                // active — otherwise the caret moves through a multi-line
                // draft. Down walks forward, and only while navigating.
                .onKeyPress(.upArrow) {
                    if viewModel.input.isEmpty || viewModel.isNavigatingHistory {
                        viewModel.recallOlder()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.downArrow) {
                    if viewModel.isNavigatingHistory {
                        viewModel.recallNewer()
                        return .handled
                    }
                    return .ignored
                }
                // Any user edit exits history navigation. The VM guards
                // its own recall writes so this doesn't fire falsely.
                .onChange(of: viewModel.input) { _, _ in
                    viewModel.handleInputChange()
                }

            // Mic when the field is empty (WhatsApp-style), send once the
            // user has typed. Falls back to the send button when media is
            // gated off so there's always a trailing action.
            if !isSendable && ComposerViewModel.mediaAvailable {
                Button {
                    Task { await startRecording() }
                } label: {
                    Image(systemName: "mic")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(height: Self.singleLineInputHeight)
                }
                .buttonStyle(.plain)
                .help("Record a voice note")
                .padding(.trailing, 4)
            } else {
                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(isSendable ? Color.accentColor : Color.secondary)
                        // Same one-line-tall container as the plus so
                        // the arrow centres against a single-line input.
                        .frame(height: Self.singleLineInputHeight)
                }
                .buttonStyle(.plain)
                .disabled(!isSendable || viewModel.isSending)
                .padding(.trailing, 4)
                // Enter sends; Shift+Enter inserts a newline. Plain Return is
                // intercepted by this shortcut; the Shift+Return newline is
                // handled by the local key monitor installed in `.onAppear`
                // (the `axis: .vertical` TextField doesn't insert a newline
                // for Shift+Return on its own), matching Slack / Discord.
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
    }

    /// The recording pill shown in place of the composer while a voice note
    /// is being captured: a red dot, live elapsed time, a Cancel affordance,
    /// and a prominent stop-and-send button. Mirrors iOS `ComposerView`.
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
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button {
                stopRecordingAndSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(height: Self.singleLineInputHeight)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    /// Starts a recording, surfacing permission / hardware failures through
    /// the same `sendError` channel the composer already uses.
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
