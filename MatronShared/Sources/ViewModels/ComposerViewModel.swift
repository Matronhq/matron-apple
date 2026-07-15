import Foundation
import MatronChat
import MatronModels
import UniformTypeIdentifiers

/// Drives the message composer: text input, slash-command palette, and the
/// send / attach actions. Both iOS (`ComposerView`) and macOS
/// (`MacChatView` / `ComposerDropDelegate`) bind against the same instance.
///
/// On Mac, `palettePinnedOpen` is toggled by the `⌘K` keyboard shortcut.
/// On iOS the palette appears purely from typing `/` or `!`.
@Observable
@MainActor
public final class ComposerViewModel {
    /// Whether the attachment (photo/file) and voice-note controls are
    /// available. `true` now that the server's send whitelist accepts
    /// `file`/`image` sends backed by a `POST /media` upload (media DISPLAY
    /// was already live). Views gate the attach/mic buttons on this flag,
    /// so the surfaces are one flip away from being hidden again.
    ///
    /// Deployed-server dependency: this requires the matron-journal server
    /// that whitelists `file`/`image` client sends and serves `POST /media`;
    /// against an older server the send round-trips to a whitelist rejection.
    public static let mediaAvailable = true

    public var input: String = ""
    public private(set) var isSending: Bool = false
    public private(set) var sendError: String?
    /// Mac slash palette is also openable via `⌘K`; iOS toggles purely via `/` typing.
    public var palettePinnedOpen: Bool = false

    /// True while the user is walking sent-message history via Up/Down.
    /// The Mac composer reads this to decide whether Up should recall
    /// (empty field or already navigating) or move the caret through a
    /// multi-line draft. iOS doesn't drive history recall, so it stays
    /// `false` there.
    public private(set) var isNavigatingHistory: Bool = false

    /// Terminal-style recall of previously-sent messages, keyed by room.
    /// Owned here (not injected) so the sole instance's lifetime tracks the
    /// view model — the same "used directly, not passed in" shape as
    /// `ComposerDraftMemory`. The cursor state lives inside the history
    /// object; this view model only mirrors the `isNavigatingHistory` flag
    /// for the view.
    private let history = SentMessageHistory()

    /// Persistent recent-folder store powering `/start` / `/workdir`
    /// completion. Injected (defaulting to the `.standard`-backed store)
    /// so tests can point it at a throwaway UserDefaults suite. Unlike
    /// `history`, this survives app relaunches — folders are worth
    /// remembering across sessions.
    private let recentFolders: RecentStartFolders

    /// The last value `recallOlder`/`recallNewer` wrote into `input`. The
    /// view's `onChange(of: input)` can't tell a programmatic recall write
    /// from a user keystroke by timing (SwiftUI defers `onChange` past the
    /// synchronous set), so `handleInputChange()` compares against this
    /// instead: an `input` that still equals the recalled value is our own
    /// write and must not exit navigation; anything else is a real edit.
    private var lastRecalledValue: String?

    /// Room this composer is bound to. Used by the View layer to key
    /// per-room draft persistence (`ComposerDraftMemory`) — the VM
    /// itself doesn't read or write the cache so it stays a pure input
    /// model. Empty string is acceptable for non-room composer surfaces
    /// (none today, but the future-proof seam mirrors Slack's cross-
    /// surface composer model).
    public let roomID: String

    private let timeline: TimelineService
    private let commands: [BotCommand]

    public init(
        roomID: String,
        timeline: TimelineService,
        commands: [BotCommand],
        recentFolders: RecentStartFolders = RecentStartFolders()
    ) {
        self.roomID = roomID
        self.timeline = timeline
        self.commands = commands
        self.recentFolders = recentFolders
    }

    /// Whether the slash palette should be visible. True when the input is
    /// a single token that starts with `/` or `!`, or when the palette is
    /// pinned open via the Mac shortcut.
    ///
    /// We deliberately do *not* trim trailing whitespace before checking —
    /// `selectCommand(_:)` sets input to `"/start "` (note the trailing
    /// space) to position the caret for arguments. Trimming would collapse
    /// this back to a single token and re-open the palette immediately
    /// after selection. A trailing space means "command chosen, ready for
    /// arguments" → palette closed.
    public var showPalette: Bool {
        if palettePinnedOpen { return true }
        // Folder-completion mode: `/start`/`/workdir` followed by a partial
        // path with at least one matching recent folder. Takes priority
        // over the command list (which only shows for single-token input,
        // so the two never both qualify).
        if !folderSuggestions.isEmpty { return true }
        let leading = input.drop(while: { $0 == " " || $0 == "\t" })
        guard leading.hasPrefix("/") || leading.hasPrefix("!") else { return false }
        return leading.split(separator: " ", omittingEmptySubsequences: false).count == 1
    }

    /// Filtered command list driven by the current `input`. Leading
    /// whitespace is stripped before filtering so `"  /sta"` matches the
    /// same set as `"/sta"` — `showPalette` already ignores leading spaces
    /// when deciding whether to *show* the palette, so the filter must
    /// agree, otherwise the palette shows but is empty.
    public var filteredCommands: [BotCommand] {
        let leading = String(input.drop(while: { $0 == " " || $0 == "\t" }))
        return BotCommandCatalog.filter(commands, byPrefix: leading)
    }

    /// Replaces the current input with the chosen command's trigger plus a
    /// trailing space, ready for arguments. Closes the pinned palette.
    public func selectCommand(_ command: BotCommand) {
        input = command.trigger + " "
        palettePinnedOpen = false
    }

    /// Index of the keyboard-highlighted palette row, or `nil` when no row
    /// is highlighted. Arrow keys drive it (Mac composer); `nil` means
    /// Return falls through to `send()` instead of picking a row. Any user
    /// edit clears it (`handleInputChange`) — the row list just changed
    /// under the highlight, so a stale index would pick the wrong row.
    public private(set) var paletteSelection: Int?

    /// Number of rows the palette is showing: folder suggestions when in
    /// folder-completion mode, filtered commands otherwise. Must mirror
    /// the palette view's "folders win" display rule so the keyboard
    /// highlight and the rendered rows agree.
    public var paletteItemCount: Int {
        folderSuggestions.isEmpty ? filteredCommands.count : folderSuggestions.count
    }

    /// Down-arrow while the palette shows: highlight the first row, or
    /// step the highlight down, stopping at the last row. No-op during a
    /// history walk — a recalled single-token slash line (e.g. "/start")
    /// pops the palette open, and the arrows must keep walking history,
    /// not get captured by the palette (bugbot, PR #41). The view routes
    /// the keys the same way; this guard pins the policy model-side.
    public func paletteMoveDown() {
        let count = paletteItemCount
        guard showPalette, !isNavigatingHistory, count > 0 else { return }
        paletteSelection = min(paletteSelection.map { $0 + 1 } ?? 0, count - 1)
    }

    /// Up-arrow while the palette shows: step the highlight up, stopping
    /// at the first row; with no highlight yet, start from the last row.
    /// No-op during a history walk — see `paletteMoveDown()`.
    public func paletteMoveUp() {
        let count = paletteItemCount
        guard showPalette, !isNavigatingHistory, count > 0 else { return }
        paletteSelection = max(paletteSelection.map { $0 - 1 } ?? (count - 1), 0)
    }

    /// Return-key handler: picks the highlighted palette row. Returns
    /// `true` when a row was picked (the caller must not send), `false`
    /// when nothing is highlighted — Return then means "send the input".
    public func confirmPaletteSelection() -> Bool {
        guard showPalette, let index = paletteSelection else { return false }
        paletteSelection = nil
        let folders = folderSuggestions
        if !folders.isEmpty {
            guard folders.indices.contains(index) else { return false }
            selectFolder(folders[index])
            return true
        }
        let commands = filteredCommands
        guard commands.indices.contains(index) else { return false }
        selectCommand(commands[index])
        return true
    }

    /// Recent-folder suggestions for the current input, limited to a
    /// palette-friendly count. Non-empty only in folder-completion mode:
    /// a `/start` or `/workdir` command followed by a single (possibly
    /// empty) partial path token. Empty otherwise.
    public var folderSuggestions: [String] {
        guard input != folderSuggestionsSuppressedFor,
              let partial = folderCompletionPartial else { return [] }
        // A suggestion identical to what's already typed offers nothing —
        // filtering it also keeps the palette from lingering over the
        // composer once a path is complete (picked or fully typed).
        let matches = recentFolders.matches(prefix: partial)
            .filter { $0.caseInsensitiveCompare(partial) != .orderedSame }
        return Array(matches.prefix(8))
    }

    /// Input string for which folder suggestions are suppressed — set by
    /// `selectFolder` so the palette closes on pick instead of re-matching
    /// the completed path. Cleared on any differing edit
    /// (`handleInputChange`) and on a successful `send()`, so a later
    /// re-type of the identical command line completes normally.
    private var folderSuggestionsSuppressedFor: String?

    /// Rewrites the input so the trailing partial path token is replaced by
    /// the chosen folder, keeping everything typed before it (the command
    /// and any flags). No trailing space is appended — the caret sits at
    /// the end of the path so the user can send or keep editing.
    public func selectFolder(_ path: String) {
        if let range = input.range(of: "\\S*$", options: .regularExpression) {
            input.replaceSubrange(range, with: path)
        } else {
            input = path
        }
        folderSuggestionsSuppressedFor = input
        palettePinnedOpen = false
    }

    /// The partial path token when the input is in folder-completion mode:
    /// a `/start`/`/workdir` command (either `/` or `!` prefix) followed by
    /// whitespace and at most one more token with no trailing whitespace.
    /// Returns the (possibly empty) partial token, or `nil` when the input
    /// isn't such a command line. Flag-laden inputs (a second token before
    /// the partial) don't qualify — the `\S*` tail must be the only
    /// argument token so far.
    private var folderCompletionPartial: String? {
        let leading = Substring(input.drop(while: { $0 == " " || $0 == "\t" }))
        guard let first = leading.first, first == "/" || first == "!" else { return nil }
        let body = leading.dropFirst()
        // The command name runs up to the first whitespace; there must be
        // whitespace after it for the command to be complete.
        guard let commandEnd = body.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let command = body[body.startIndex..<commandEnd]
        guard command == "start" || command == "workdir" else { return nil }
        // Everything after the separating whitespace is the partial arg; it
        // must be a single token (no further whitespace).
        let partial = body[commandEnd...].drop(while: { $0.isWhitespace })
        guard !partial.contains(where: { $0.isWhitespace }) else { return nil }
        return String(partial)
    }

    /// Extracts the folder-path argument to record from a sent `/start` or
    /// `/workdir` command line (either `/` or `!` prefix), or `nil` when the
    /// line isn't such a command or carries no path. Leading `--flag`
    /// tokens (e.g. `--claude`, `--codex`, `--browser`) are skipped; the
    /// first non-flag token is the path. Returns `nil` when only flags
    /// follow the command. A pure function so it unit-tests directly.
    static func recentFolderArgument(from text: String) -> String? {
        let trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = trimmed.first, first == "/" || first == "!" else { return nil }
        let tokens = trimmed.dropFirst().split(whereSeparator: { $0.isWhitespace })
        guard let command = tokens.first, command == "start" || command == "workdir" else { return nil }
        for token in tokens.dropFirst() where !token.hasPrefix("--") {
            return String(token)
        }
        return nil
    }

    /// Sends the trimmed input as a text message. No-op for empty input.
    /// On failure, records `sendError` and preserves the input so the user
    /// can retry. On success, also drops the per-room draft entry so a
    /// subsequent open of this room lands on an empty composer instead
    /// of restoring the just-sent text.
    public func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }

        // Clear in the SAME tick as the tap, before the round-trip — not
        // after it. Clearing post-await left a window the length of the
        // network call in which the focused TextField still held the text
        // and could write its cached value back over the late clear: the
        // message sent, but the text stayed sitting in the composer (Dan,
        // 2026-07-15, iOS — rare, because it needs a slow enough send).
        let pending = input
        input = ""
        lastRecalledValue = nil
        isNavigatingHistory = false
        folderSuggestionsSuppressedFor = nil
        ComposerDraftMemory.forget(roomID: roomID)

        do {
            try await timeline.sendText(trimmed)
            // Record the sent line for Up/Down recall. `record` also ends
            // any in-progress walk.
            history.record(trimmed, room: roomID)
            // If this was a `/start`/`/workdir` with a folder argument,
            // remember the folder for future completion.
            if let folder = Self.recentFolderArgument(from: trimmed) {
                recentFolders.record(folder)
            }
            sendError = nil
        } catch {
            sendError = error.localizedDescription
            // Put the user's text back — the optimistic clear must never
            // eat a message that didn't actually go out.
            input = pending
            ComposerDraftMemory.store(roomID: roomID, text: pending)
        }
    }

    /// Up-arrow handler: recalls an older sent message into `input`,
    /// terminal-style. The first call stashes the current draft (restored by
    /// walking back down past the newest). No-op when there's no older entry
    /// to show, so the caller can safely swallow the key. Enters navigation
    /// mode on success.
    public func recallOlder() {
        guard let text = history.recallOlder(room: roomID, currentDraft: input) else { return }
        applyRecalled(text)
        isNavigatingHistory = true
    }

    /// Down-arrow handler: walks forward toward newer sent messages, and
    /// finally restores the stashed draft (exiting navigation) on stepping
    /// past the newest. No-op unless a walk is already active.
    public func recallNewer() {
        guard isNavigatingHistory, let text = history.recallNewer(room: roomID) else { return }
        applyRecalled(text)
        isNavigatingHistory = history.isNavigating
    }

    /// Called by the composer view's `onChange(of: input)` on every input
    /// mutation. A user edit — any `input` that isn't our own recall write —
    /// exits history navigation, matching terminals where typing abandons
    /// the recalled line.
    public func handleInputChange() {
        // Any input mutation invalidates the keyboard highlight — the row
        // list it indexed into has changed shape.
        paletteSelection = nil
        // Any differing edit lifts the post-pick folder suppression so the
        // suppressed string doesn't linger and block a later identical
        // command line (e.g. re-typed after a send).
        if let suppressed = folderSuggestionsSuppressedFor, input != suppressed {
            folderSuggestionsSuppressedFor = nil
        }
        if input == lastRecalledValue { return }
        lastRecalledValue = nil
        if isNavigatingHistory {
            isNavigatingHistory = false
            history.endRecall()
        }
    }

    /// Exits an active history walk, restoring the stashed in-progress
    /// draft into `input`. The composer view calls this on disappear BEFORE
    /// persisting the draft — mid-walk, `input` holds a recalled sent line,
    /// and persisting that would overwrite the user's real draft. No-op
    /// outside navigation.
    public func exitHistoryNavigation() {
        guard isNavigatingHistory else { return }
        isNavigatingHistory = false
        guard let draft = history.cancelRecall() else { return }
        applyRecalled(draft)
    }

    /// Writes a recalled value into `input` and remembers it so the view's
    /// deferred `onChange` doesn't mistake the programmatic write for a user
    /// edit (see `lastRecalledValue`).
    private func applyRecalled(_ text: String) {
        lastRecalledValue = text
        input = text
    }

    /// Mac drag-and-drop entry point. Wired by `ComposerDropDelegate` in
    /// `MatronMac/Features/Chat/ComposerDropDelegate.swift` (Task 14c). Sends
    /// each URL as the appropriate attachment kind (image vs file) via the
    /// timeline. URLs that fail to read or send are recorded in
    /// `sendError`; the previous behaviour silently dropped read failures
    /// via `try?`, which masked iOS security-scoped-URL permission errors.
    ///
    /// Security-scoped wrap policy: `attachFiles(_:)` is *only* reached
    /// with URLs the caller has already prepared for unscoped reading.
    /// - iOS `fileImporter`: the View's `stageAndAttach` wraps the
    ///   original URL with `start/stopAccessingSecurityScopedResource()`,
    ///   reads its bytes inside that window, and writes them to a temp
    ///   URL — temp URLs are not security-scoped, so no wrap needed here.
    /// - iOS `PhotosPicker`: data is staged to a temp URL via
    ///   `photoTempURL(ext:)` before the call — same as above.
    /// - Mac `ComposerDropDelegate`: drop URLs are granted transparent
    ///   read access by the
    ///   `com.apple.security.files.user-selected.read-only` entitlement
    ///   (see `MacChatView.swift` comment on `.onDrop`).
    /// Removing the inner wrap eliminates the round-3 bugbot finding #4
    /// double-wrap on staged temp URLs (where the inner wrap was a no-op
    /// but misleading).
    public func attachFiles(_ urls: [URL]) async {
        for url in urls {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                sendError = error.localizedDescription
                continue
            }
            let mime = (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) ?? "application/octet-stream"
            do {
                if mime.hasPrefix("image/") {
                    try await timeline.sendImage(data, filename: url.lastPathComponent, mimeType: mime)
                } else {
                    try await timeline.sendFile(data, filename: url.lastPathComponent, mimeType: mime)
                }
            } catch {
                sendError = error.localizedDescription
            }
        }
    }

    /// Sends a recorded voice note (a temp `.m4a` file produced by
    /// `VoiceRecorder`) as a `file` attachment with an `audio/*` content
    /// type — the bridge transcribes audio sends. The temp file is deleted
    /// afterwards whether or not the send succeeds; send failures surface
    /// via `sendError` (the same channel as `attachFiles`). `duration` is
    /// currently informational (the wire payload carries only the bytes and
    /// metadata), kept in the signature for the recording UI's benefit.
    public func sendVoiceNote(url: URL, duration: TimeInterval) async {
        do {
            let data = try Data(contentsOf: url)
            try await timeline.sendFile(data, filename: "voice-note.m4a", mimeType: "audio/mp4")
            // A successful send clears any prior composer error, same as
            // `send()` — a stale failure line must not outlive a voice note
            // that actually went through.
            sendError = nil
        } catch {
            sendError = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Allows views to surface attachment-staging errors that occur
    /// outside `attachFiles(_:)` itself — e.g. iOS `fileImporter` failure
    /// or security-scoped resource read errors. Using a method instead of
    /// a public setter keeps the existing `private(set)` invariant
    /// honest.
    public func reportAttachmentError(_ message: String) {
        sendError = message
    }
}
