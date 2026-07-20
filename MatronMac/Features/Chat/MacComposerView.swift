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

    /// Placeholder shown in the empty composer — drawn as a SwiftUI overlay,
    /// since `NSTextView` has no placeholder of its own.
    private static let placeholder = "Message…"

    /// The input's vertical padding (top and bottom). Reads the editor's
    /// own inset so the single-line height below stays tied to it: if the
    /// inset changes, the accessory-button height follows.
    private static var inputVerticalPadding: CGFloat {
        MacComposerTextEditor.textInset
    }

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

    /// Every accessory button (plus on the left; mic on an empty field or
    /// send arrow once text exists on the right) renders in this
    /// fixed-width container. Their glyphs are different sizes (`.title2`
    /// / `.title3` / `.title`), and letting each size its own container
    /// made the input field jump sideways on the first typed character
    /// and gave the plus a visibly wider gutter than the send side (Dan,
    /// 2026-07-16). Wide enough for the largest glyph, the send arrow.
    private static let trailingAccessoryWidth: CGFloat = 28

    /// Measured height of the input's content (text + padding), reported by
    /// `MacComposerTextEditor` and driving the grow-then-scroll frame below.
    @State private var inputContentHeight: CGFloat = 0

    /// Internal so `MacComposerViewBindingTests` can pin the predicate
    /// without scraping SwiftUI internals (mirrors the iOS surface).
    /// Delegates to `canSend` rather than re-deriving it: a staged
    /// attachment is a sendable message with no text at all.
    var isSendable: Bool { viewModel.canSend }

    var body: some View {
        VStack(spacing: 0) {
            // Send / attachment / voice-note failures all funnel into
            // `sendError` (see `ComposerViewModel.reportAttachmentError`),
            // but until now nothing rendered it — a failed send left the
            // user staring at a composer that silently did nothing. Sits
            // above BOTH the recording bar and the normal composer bar
            // (not nested inside `composerBar`) so an undismissed error
            // stays visible even while a voice recording is in progress,
            // matching iOS `ComposerView`, whose banner is a sibling of
            // that same recording/composerBar branch.
            if let sendError = viewModel.sendError {
                MacComposerErrorBanner(message: sendError) {
                    viewModel.dismissSendError()
                }
            }
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
        }
    }

    /// The normal composer row: plus (attach) on the left, growing text
    /// field with the Up/Down history + edit key handling, then a mic
    /// (empty input) or the send button. Plus + mic are gated on
    /// `mediaAvailable`, mirroring iOS `ComposerView`.
    private var composerBar: some View {
        VStack(spacing: 0) {
            // Above the input, so what's about to be sent sits next to the
            // words being written about it. Same shared tray as iOS.
            AttachmentTray(attachments: viewModel.stagedAttachments) { id in
                viewModel.removeAttachment(id: id)
            }
            inputRow
        }
    }

    private var inputRow: some View {
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
                        // Same fixed container as the trailing accessories
                        // so both sides of the input carry identical
                        // gutters — horizontal padding here made the left
                        // side visibly wider than the mic/send side (Dan,
                        // 2026-07-16). See `singleLineInputHeight`.
                        .frame(
                            width: Self.trailingAccessoryWidth,
                            height: Self.singleLineInputHeight
                        )
                }
                .buttonStyle(.plain)
                .help("Attach a file")
                .padding(.leading, 4)
            }

            // Grow-then-scroll input: an AppKit `NSTextView` whose text
            // container tracks the view width (so a live window resize
            // re-wraps the text — the SwiftUI field editor didn't, Dan
            // 2026-07-16), inside its own NSScrollView. The frame tracks
            // the reported content height up to `maxInputHeight` — past 8
            // lines the frame stops growing and the content scrolls, with
            // the text view keeping the caret in view as it always does.
            MacComposerTextEditor(
                text: $viewModel.input,
                onHeightChange: { inputContentHeight = $0 },
                // An ACTIVE history walk owns Up/Down outright — a
                // recalled single-token slash line (e.g. "/start") pops
                // the palette open, and letting the palette grab the
                // arrows there would trap the walk on that entry (bugbot,
                // PR #41). Otherwise, while the palette shows, Up/Down
                // move its keyboard highlight; and failing both, Up
                // recalls older sent messages (terminal-style), but only
                // from an empty field — else the caret moves through a
                // multi-line draft.
                onMoveUp: {
                    if viewModel.isNavigatingHistory {
                        viewModel.recallOlder()
                        return true
                    }
                    if viewModel.showPalette, viewModel.paletteItemCount > 0 {
                        viewModel.paletteMoveUp()
                        return true
                    }
                    if viewModel.input.isEmpty {
                        viewModel.recallOlder()
                        return true
                    }
                    return false
                },
                onMoveDown: {
                    if viewModel.isNavigatingHistory {
                        viewModel.recallNewer()
                        return true
                    }
                    if viewModel.showPalette, viewModel.paletteItemCount > 0 {
                        viewModel.paletteMoveDown()
                        return true
                    }
                    return false
                },
                // Plain Return: pick the highlighted palette row, else
                // send. Normally the send button's
                // `.keyboardShortcut(.return)` claims Return before the
                // text view sees it (and its action runs the same
                // confirm-first check); this handler covers the mic-button
                // state, where no send shortcut exists. Returning true on
                // the fall-through swallows the newline a bare Return
                // would otherwise insert into an unsendable field.
                onCommit: {
                    if viewModel.confirmPaletteSelection() { return true }
                    if viewModel.canSend, !viewModel.isSending {
                        Task { await viewModel.send() }
                    }
                    return true
                },
                onPasteAttachments: { claimPasteboardAttachments() }
            )
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
                // NSTextView has no placeholder — draw it in SwiftUI,
                // aligned with the editor's own text inset.
                .overlay(alignment: .topLeading) {
                    if viewModel.input.isEmpty {
                        Text(Self.placeholder)
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .padding(MacComposerTextEditor.textInset)
                            .allowsHitTesting(false)
                    }
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
                        .frame(
                            width: Self.trailingAccessoryWidth,
                            height: Self.singleLineInputHeight
                        )
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
                        .frame(
                            width: Self.trailingAccessoryWidth,
                            height: Self.singleLineInputHeight
                        )
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

    /// Decides whether a ⌘V in the text editor is an attachment paste.
    /// Bridges each `NSPasteboardItem` to an `NSItemProvider` so
    /// `PastedAttachment.classify(_:)` — the shared, probe-verified rule for
    /// what counts as an attachment vs text — applies unchanged. Items that
    /// classify as text are left alone; if nothing classifies as an
    /// attachment this returns `false` and the text view pastes normally.
    private func claimPasteboardAttachments() -> Bool {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let providers = items.map { item in
            let provider = NSItemProvider()
            for type in item.types where UTType(type.rawValue) != nil {
                provider.registerDataRepresentation(
                    forTypeIdentifier: type.rawValue, visibility: .all
                ) { completion in
                    completion(item.data(forType: type), nil)
                    return nil
                }
            }
            return provider
        }
        let attachments = providers.filter { PastedAttachment.classify($0) != .text }
        guard !attachments.isEmpty else { return false }
        Task { await attachPasted(attachments) }
        return true
    }

    /// Stages each pasted item to a temporary file and hands the lot to
    /// `ComposerViewModel.attachFiles(_:)`. Mirrors `ComposerDropDelegate`:
    /// a mixed paste attaches the items that read cleanly and reports the
    /// first failure, rather than dropping everything on one bad item.
    private func attachPasted(_ providers: [NSItemProvider]) async {
        var staged: [URL] = []
        var firstError: Error?
        for provider in providers {
            do {
                staged.append(try await PastedAttachment.stage(provider))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !staged.isEmpty {
            await viewModel.attachFiles(staged)
        }
        if let firstError {
            viewModel.reportAttachmentError(firstError.localizedDescription)
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

/// Dismissible strip for `ComposerViewModel.sendError`: surfaces send,
/// attachment, and voice-note failures that previously had a recording
/// spot (`sendError`) but nothing rendering it. Styled after the chat
/// timeline's own error banner (`MacChatView`'s `viewModel.error` strip)
/// so the two read as the same "the app is telling you something"
/// vocabulary, but sits directly above the tray/input rather than the
/// timeline, and adds a tap-to-dismiss control the timeline banner
/// doesn't need (that one clears itself when the stream recovers).
private struct MacComposerErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // No `.accessibilityElement(children: .combine)` here: combining
            // would merge this text into the dismiss button's element,
            // leaving the button's own "Dismiss error" label unreachable
            // and dismiss unverifiable via accessibility navigation. Each
            // control stays an independent accessibility element instead.
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Composer error: \(message)")
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.9))
    }
}
