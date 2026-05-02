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
    public var input: String = ""
    public private(set) var isSending: Bool = false
    public private(set) var sendError: String?
    /// Mac slash palette is also openable via `⌘K`; iOS toggles purely via `/` typing.
    public var palettePinnedOpen: Bool = false

    private let timeline: TimelineService
    private let commands: [BotCommand]

    public init(timeline: TimelineService, commands: [BotCommand]) {
        self.timeline = timeline
        self.commands = commands
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

    /// Filtered command list driven by the current `input`.
    public var filteredCommands: [BotCommand] {
        BotCommandCatalog.filter(commands, byPrefix: input)
    }

    /// Replaces the current input with the chosen command's trigger plus a
    /// trailing space, ready for arguments. Closes the pinned palette.
    public func selectCommand(_ command: BotCommand) {
        input = command.trigger + " "
        palettePinnedOpen = false
    }

    /// Sends the trimmed input as a text message. No-op for empty input.
    /// On failure, records `sendError` and preserves the input so the user
    /// can retry.
    public func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await timeline.sendText(trimmed)
            input = ""
            sendError = nil
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Mac drag-and-drop entry point. Wired by `ComposerDropDelegate` in
    /// `MatronMac/Features/Chat/ComposerDropDelegate.swift` (Task 14c). Sends
    /// each URL as the appropriate attachment kind (image vs file) via the
    /// timeline. URLs that fail to read or send are recorded in
    /// `sendError`; the previous behaviour silently dropped read failures
    /// via `try?`, which masked iOS security-scoped-URL permission errors.
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
