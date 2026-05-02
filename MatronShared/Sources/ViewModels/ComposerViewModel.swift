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
    public var showPalette: Bool {
        if palettePinnedOpen { return true }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("!") else { return false }
        return trimmed.split(separator: " ").count == 1
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
    /// timeline. URLs that fail to read or send are skipped; the last error
    /// surfaced is recorded in `sendError`.
    public func attachFiles(_ urls: [URL]) async {
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
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
}
