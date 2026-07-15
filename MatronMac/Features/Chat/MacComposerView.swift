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
        lineHeight + inputVerticalPadding * 2
    }

    /// The input stops growing at 8 lines (the old `lineLimit` upper bound)
    /// and scrolls internally beyond that — see `composerBar`'s ScrollView.
    private static var maxInputHeight: CGFloat {
        lineHeight * 8 + inputVerticalPadding * 2
    }

    private static var lineHeight: CGFloat {
        let body = NSFont.preferredFont(forTextStyle: .body)
        return ceil(body.ascender - body.descender + body.leading)
    }

    /// Measured height of the input's content (text + padding), driving the
    /// grow-then-scroll frame below.
    @State private var inputContentHeight: CGFloat = 0

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
            if case let .recording(start) = recorder.state {
                recordingBar(start: start)
            } else {
                composerBar
            }
        }
        // The slash palette FLOATS above the composer instead of stacking
        // into layout: stacked, it pushed the bottom of the conversation
        // up every time it appeared. The alignment guide pins the panel's
        // bottom 4pt above the composer's top edge; SwiftUI doesn't clip
        // overlays, and the composer renders after the timeline in
        // `MacChatView`'s VStack, so the panel draws over the messages.
        //
        // The guide lives on a `ZStack` wrapper, OUTSIDE the `if`: a custom
        // alignment guide set inside conditional content is dropped by
        // SwiftUI's `ConditionalContent`, which left the panel top-aligned
        // INTO the composer, covering the input and clipped by the window
        // bottom (Dan, 2026-07-15).
        .overlay(alignment: .top) {
            ZStack {
                if viewModel.showPalette {
                    MacSlashCommandPalette(
                        commands: viewModel.filteredCommands,
                        folders: viewModel.folderSuggestions,
                        selection: viewModel.paletteSelection,
                        onSelect: { cmd in viewModel.selectCommand(cmd) },
                        onSelectFolder: { folder in viewModel.selectFolder(folder) }
                    )
                    .padding(.horizontal)
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 4 }
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

            // Grow-then-scroll input: the field grows with its content
            // (unbounded lineLimit) inside a ScrollView whose frame tracks
            // the measured content height up to `maxInputHeight` — past 8
            // lines the frame stops growing and the content scrolls. The
            // field editor's caret-tracking (`scrollRangeToVisible`) walks
            // up to the nearest NSClipView, which is this ScrollView's, so
            // typing at the end keeps the caret in view. A bare
            // `lineLimit(1...8)` couldn't do this: on macOS the overflow
            // was simply unreachable by scrolling (Dan, 2026-07-15).
            ScrollView(.vertical) {
                TextField(Self.placeholder, text: $viewModel.input, axis: .vertical)
                    .lineLimit(1...)
                    .textFieldStyle(.plain)
                    .padding(Self.inputVerticalPadding)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        inputContentHeight = height
                    }
            }
                .frame(height: min(
                    max(inputContentHeight, Self.singleLineInputHeight),
                    Self.maxInputHeight
                ))
                // White (dark-mode: elevated warm) input surface, same
                // as bot bubbles — `.regularMaterial` read muddy-dark
                // against the cream timeline gradient. Matches
                // matron-web's white composer on the cream ground.
                .background(Color.matronBubbleBot)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
                // An ACTIVE history walk owns Up/Down outright — a
                // recalled single-token slash line (e.g. "/start") pops
                // the palette open, and letting the palette grab the
                // arrows there would trap the walk on that entry (bugbot,
                // PR #41). Otherwise, while the palette shows, Up/Down
                // move its keyboard highlight; and failing both, Up
                // recalls older sent messages (terminal-style), but only
                // from an empty field — else the caret moves through a
                // multi-line draft.
                .onKeyPress(.upArrow) {
                    if viewModel.isNavigatingHistory {
                        viewModel.recallOlder()
                        return .handled
                    }
                    if viewModel.showPalette, viewModel.paletteItemCount > 0 {
                        viewModel.paletteMoveUp()
                        return .handled
                    }
                    if viewModel.input.isEmpty {
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
                    if viewModel.showPalette, viewModel.paletteItemCount > 0 {
                        viewModel.paletteMoveDown()
                        return .handled
                    }
                    return .ignored
                }
                // Return picks the highlighted palette row. Normally the
                // send button's `.keyboardShortcut(.return)` claims Return
                // before this key press fires (and its action runs the
                // same confirm-first check); this handler covers the
                // mic-button state, where no send shortcut exists — e.g.
                // the palette pinned open via ⌘K over an empty field.
                .onKeyPress(.return) {
                    viewModel.confirmPaletteSelection() ? .handled : .ignored
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
                    // Return with a palette row highlighted picks the row
                    // (this shortcut claims Return before the TextField's
                    // key-press handler sees it); only an un-highlighted
                    // Return sends.
                    if viewModel.confirmPaletteSelection() { return }
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
