import Foundation

/// A slash-command entry surfaced in the composer's slash palette.
///
/// The catalog is local — driven by a static list per bot kind — because
/// the bridge protocol doesn't expose a discovery endpoint yet. Phase 5+
/// will replace the static catalog with config-driven entries.
public struct BotCommand: Equatable, Hashable, Sendable {
    /// Full trigger including its leading character, e.g. `/start` or `!start`.
    public let trigger: String
    /// One-line user-facing description shown in the palette.
    public let summary: String
    /// Optional argument hint, e.g. `[workdir]` or `<path>`. Rendered in the
    /// palette next to the trigger.
    public let argHint: String?

    public init(trigger: String, summary: String, argHint: String? = nil) {
        self.trigger = trigger
        self.summary = summary
        self.argHint = argHint
    }
}

/// Static slash-command catalogs per bot kind, plus a small filter helper
/// used by the composer's slash palette.
public enum BotCommandCatalog {
    /// Static catalog for the Claude bridge. In Phase 5+ this becomes
    /// config-driven (per-bot, served by the bridge or its provisioner).
    public static let claudeBridge: [BotCommand] = [
        BotCommand(trigger: "/start", summary: "Start a Claude Code session", argHint: "[workdir]"),
        BotCommand(trigger: "/stop", summary: "Stop the current session"),
        BotCommand(trigger: "/restart", summary: "Restart and resume the session"),
        BotCommand(trigger: "/resume", summary: "Resume a previous session", argHint: "[n|id]"),
        BotCommand(trigger: "/sessions", summary: "List past sessions"),
        BotCommand(trigger: "/workdir", summary: "Change working directory", argHint: "<path>"),
        BotCommand(trigger: "/status", summary: "Show session info"),
        BotCommand(trigger: "/working", summary: "Toggle tool-call visibility"),
        BotCommand(trigger: "/mcp", summary: "Show MCP server status"),
        BotCommand(trigger: "/model", summary: "Show current model"),
        BotCommand(trigger: "/cost", summary: "Show session cost"),
        BotCommand(trigger: "/usage", summary: "Show token usage"),
        BotCommand(trigger: "/tools", summary: "List available tools"),
        BotCommand(trigger: "/help", summary: "Show command help"),
    ]

    /// Filters `commands` by typed prefix. Comparison is case-insensitive
    /// and ignores the leading `/` or `!` so users can type either prefix
    /// to discover the same command. An empty (or all-prefix-only) input
    /// returns the full list.
    public static func filter(_ commands: [BotCommand], byPrefix prefix: String) -> [BotCommand] {
        let normalized = String(prefix.lowercased().drop(while: { $0 == "/" || $0 == "!" }))
        guard !normalized.isEmpty else { return commands }
        return commands.filter { cmd in
            let trigger = String(cmd.trigger.lowercased().drop(while: { $0 == "/" || $0 == "!" }))
            return trigger.hasPrefix(normalized)
        }
    }
}
