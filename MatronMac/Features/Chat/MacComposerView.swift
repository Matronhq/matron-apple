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
    /// What the app-wide recording indicator calls this conversation.
    var voiceNoteTitle: String = "this conversation"
    /// The app's one voice-note recording (`VoiceNoteSession`, mission
    /// 5840), from the app root, so a note carries on when this composer
    /// leaves the screen. A private one for composers built without the
    /// root (tests, previews).
    @Environment(VoiceNoteSession.self) private var injectedVoiceNotes: VoiceNoteSession?
    @State private var fallbackVoiceNotes = VoiceNoteSession()
    private var voiceNotes: VoiceNoteSession { injectedVoiceNotes ?? fallbackVoiceNotes }
    private var voiceTarget: VoiceNoteSession.Target {
        .init(kind: .conversation(viewModel.roomID), title: voiceNoteTitle)
    }
    /// The global voice-note hotkey's seam (see `VoiceNoteCommandBus`).
    /// Optional so a composer built without the app root (tests,
    /// previews) simply has no hotkey.
    @Environment(VoiceNoteCommandBus.self) private var voiceBus: VoiceNoteCommandBus?
    /// This composer's identity on the bus, and the window it lives in so
    /// it can re-claim the bus when that window becomes key.
    @State private var voiceComposerID = UUID()
    @State private var hostWindow: NSWindow?
    /// Whether this composer's text view is first responder — a focused
    /// composer claims the voice hotkey.
    @State private var inputFocused = false

    /// Placeholder shown in the empty composer — drawn as a SwiftUI overlay,
    /// since `NSTextView` has no placeholder of its own.
    private static let placeholder = "Message…"

    /// Rendered height of a one-line input (`MacComposerField`'s). The
    /// paperclip and send buttons pin their icon container to this so both
    /// accessories sit centred against a single-line field (the HStack
    /// stays `.bottom` aligned, so on a grown multi-line field they drop to
    /// the bottom edge).
    private static var singleLineInputHeight: CGFloat {
        MacComposerField.singleLineHeight
    }

    /// Every accessory button (plus on the left; mic on an empty field or
    /// send arrow once text exists on the right) renders in this
    /// fixed-width container. Their glyphs are different sizes (`.title2`
    /// / `.title3` / `.title`), and letting each size its own container
    /// made the input field jump sideways on the first typed character
    /// and gave the plus a visibly wider gutter than the send side.
    /// Wide enough for the largest glyph, the send arrow.
    private static let trailingAccessoryWidth: CGFloat = 28

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
            // Determinate upload feedback — same rationale as iOS
            // ComposerView: a slow uplink must look like progress, not a
            // hang.
            if let upload = viewModel.uploadProgress {
                UploadProgressBar(label: upload.label, fraction: upload.fraction)
            }
            if voiceNotes.isRecording(for: voiceTarget.kind), let start = voiceNotes.recordingStart {
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
        // bottom.
        .overlay(alignment: .top) {
            ZStack {
                if viewModel.showPalette {
                    MacSlashCommandPalette(
                        commands: viewModel.filteredCommands,
                        suggestions: viewModel.paletteSuggestions,
                        selection: viewModel.paletteSelection,
                        onSelect: { cmd in viewModel.selectCommand(cmd) },
                        onSelectSuggestion: { suggestion in viewModel.selectSuggestion(suggestion) }
                    )
                    .padding(.horizontal)
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 4 }
            .animation(.easeInOut(duration: 0.18), value: viewModel.showPalette)
            .animation(.easeInOut(duration: 0.18), value: viewModel.sendError != nil)
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
            // A recording carries on without this composer (mission
            // 5840): the window's pill takes over its controls.
            voiceNotes.ownerDisappeared(voiceComposerID)
            voiceBus?.release(voiceComposerID)
        }
        .onAppear { voiceNotes.ownerAppeared(voiceComposerID, kind: voiceTarget.kind) }
        // Claimed once the window is known, and only if that window is key
        // (or nothing holds the bus): a composer remounting in a background
        // window must not steal the key window's claim.
        //
        // Only when the window is first learnt (or changes): the accessor
        // reports on every update. A caret in another composer of the
        // window keeps its claim on mount.
        .background(WindowAccessor { window in
            guard let window, window !== hostWindow else { return }
            hostWindow = window
            let anotherComposerFocused = Self.chatComposerHasCaret(in: window) && !inputFocused
            voiceBus?.claimIfKey(voiceComposerID, isKey: window.isKeyWindow && !anotherComposerFocused,
                                 window: ObjectIdentifier(window))
        })
        // With File → New Window, several composers share the bus; the
        // one whose window is key is the one a press should land in.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let hostWindow, let window = note.object as? NSWindow,
                  window === hostWindow else { return }
            // A caret in ANOTHER composer of this window keeps that
            // composer's claim across a re-key.
            guard inputFocused || !Self.chatComposerHasCaret(in: window) else { return }
            voiceBus?.claim(voiceComposerID, window: ObjectIdentifier(window))
        }
        // The global hotkey's START: a press while a note is recording
        // never reaches a composer — the app root stops and sends it to
        // wherever it began. Only the addressed composer reacts; the
        // no-chat-open refusal and the lock live at the root too.
        .onChange(of: voiceBus?.pressCount ?? 0) { _, _ in
            guard let voiceBus, voiceBus.pressTarget == voiceComposerID else { return }
            switch VoiceNoteHotkeyAction.resolve(isRecording: voiceNotes.isRecording(for: voiceTarget.kind),
                                                 hasComposer: true,
                                                 mediaAvailable: ComposerViewModel.mediaAvailable) {
            case .start:
                Task {
                    await startRecording()
                    if voiceNotes.isRecording(for: voiceTarget.kind) { VoiceNoteCommandBus.playStartSound() }
                }
            case .stopAndSend:
                stopRecordingAndSend()
                VoiceNoteCommandBus.playStopSound()
            case .refuse:
                VoiceNoteCommandBus.playRefuseSound()
            }
        }
    }

    /// Whether a CHAT composer's text view has the caret in `window`. The
    /// voice hotkey follows the chat composer being typed in; a tracker
    /// reply field (the same `ComposerTextView` class, no voice-bus
    /// identity) must not count as "another composer holds the caret".
    static func chatComposerHasCaret(in window: NSWindow) -> Bool {
        (window.firstResponder as? ComposerTextView)?.isChatComposer == true
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
                        // side visibly wider than the mic/send side. See `singleLineInputHeight`.
                        .frame(
                            width: Self.trailingAccessoryWidth,
                            height: Self.singleLineInputHeight
                        )
                }
                .buttonStyle(.plain)
                .help("Attach a file")
                .padding(.leading, 4)
            }

            // The shared input (`MacComposerField`, also the tracker
            // reply field): NSTextView editor, grow-then-scroll, placeholder.
            MacComposerField(
                text: $viewModel.input,
                placeholder: Self.placeholder,
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
                // confirm-first check); this handler covers the empty
                // field, where the send button carries no shortcut. Returning true on
                // the fall-through swallows the newline a bare Return
                // would otherwise insert into an unsendable field.
                onCommit: {
                    if viewModel.confirmPaletteSelection() { return true }
                    if viewModel.canSend, !viewModel.isSending {
                        Task { await viewModel.send() }
                    }
                    return true
                },
                // ⌘V of images/files stages them in the tray; text falls
                // through to the text view. See `PasteboardAttachmentBridge`.
                onPasteAttachments: { PasteboardAttachmentBridge.claimAttachments(on: .general, into: viewModel) },
                onAttachablePasteboardTypes: { PasteboardAttachmentBridge.readableTypesToOffer(on: .general) },
                onFocusChange: { focused, window in
                    inputFocused = focused
                    // Typing here is choosing this chat: the hotkey follows.
                    // The text view's own window covers focus arriving
                    // before `WindowAccessor` has reported `hostWindow`.
                    if focused {
                        voiceBus?.claim(voiceComposerID, window: (hostWindow ?? window).map(ObjectIdentifier.init))
                    }
                },
                isChatComposer: true
            )
                // Any user edit exits history navigation. The VM guards
                // its own recall writes so this doesn't fire falsely.
                .onChange(of: viewModel.input) { _, _ in
                    viewModel.handleInputChange()
                }

            // The mic stays beside a draft: a voice note
            // takes the typed text and the tray with it, as one message.
            // Send sits beside it throughout, greyed out until there's
            // something to send: swapping one for the other made the field
            // change width on the first typed character.
            if ComposerViewModel.mediaAvailable {
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
                .disabled(viewModel.isSending)
                .help("Record a voice note")
                .accessibilityIdentifier("composer.mic")
            }
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
            // The window's only composer, so Return sends its draft
            // wherever the caret is. Only while there's something to send:
            // with an empty field Return must reach the text view's
            // `onCommit`, which picks a highlighted palette row (⌘K) —
            // this button used to be absent then, and a shortcut on a
            // disabled button can still claim the key.
            .keyboardShortcut(isSendable ? KeyboardShortcut(.return, modifiers: []) : nil)
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
            Button("Cancel") { voiceNotes.cancel() }
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
    /// A note already recording elsewhere is refused the same way. The
    /// delivery closure holds the view model, so the note reaches this
    /// conversation however far the user has navigated since.
    private func startRecording() async {
        do {
            try await voiceNotes.start(voiceTarget) { [viewModel] url, duration in
                await viewModel.sendVoiceNote(url: url, duration: duration)
            }
        } catch {
            viewModel.reportAttachmentError(error.localizedDescription)
        }
    }

    private func stopRecordingAndSend() {
        voiceNotes.stopAndSend()
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
