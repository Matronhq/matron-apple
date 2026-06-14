import Foundation
import os
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
    public var input: String = ""
    public private(set) var isSending: Bool = false
    public private(set) var sendError: String?
    /// Mac slash palette is also openable via `⌘K`; iOS toggles purely via `/` typing.
    public var palettePinnedOpen: Bool = false

    /// Room this composer is bound to. Used by the View layer to key
    /// per-room draft persistence (`ComposerDraftMemory`) — the VM
    /// itself doesn't read or write the cache so it stays a pure input
    /// model. Empty string is acceptable for non-room composer surfaces
    /// (none today, but the future-proof seam mirrors Slack's cross-
    /// surface composer model).
    public let roomID: String

    private let timeline: TimelineService
    private let commands: [BotCommand]

    // DIAGNOSTIC (throwaway branch): always-on. Instance id ties a send (and
    // its input-clear) to a specific composer so we can tell if the visible
    // composer is the one that sent.
    private static let live = os.Logger(subsystem: "chat.matron", category: "live-update")
    private let instanceID = String(UUID().uuidString.prefix(4))

    public init(roomID: String, timeline: TimelineService, commands: [BotCommand]) {
        self.roomID = roomID
        self.timeline = timeline
        self.commands = commands
        Self.live.notice("Composer init id=\(self.instanceID, privacy: .public) room=\(roomID, privacy: .public)")
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
        do {
            try await timeline.sendText(trimmed)
            input = ""
            sendError = nil
            ComposerDraftMemory.forget(roomID: roomID)
            Self.live.notice("Composer send OK id=\(self.instanceID, privacy: .public) room=\(self.roomID, privacy: .public) input now empty=\(self.input.isEmpty, privacy: .public)")
        } catch {
            sendError = error.localizedDescription
            Self.live.notice("Composer send FAILED id=\(self.instanceID, privacy: .public) room=\(self.roomID, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
        }
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

    /// Allows views to surface attachment-staging errors that occur
    /// outside `attachFiles(_:)` itself — e.g. iOS `fileImporter` failure
    /// or security-scoped resource read errors. Using a method instead of
    /// a public setter keeps the existing `private(set)` invariant
    /// honest.
    public func reportAttachmentError(_ message: String) {
        sendError = message
    }
}
