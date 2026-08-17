import Foundation

/// One selectable argument for a slash command — a flag (`--browser`) or an
/// enumerated value (`interactive`). Static entries cover values that are
/// part of the command's grammar; session-derived entries (model aliases,
/// effort levels) arrive in a later phase via the bridge's status frame
/// (see docs/superpowers/specs/2026-08-10-composer-argument-suggestions-design.md).
public struct ArgSuggestion: Equatable, Hashable, Sendable {
    /// Inserted verbatim into the composer: `--browser`, `claude`, `cancel`.
    public let value: String
    /// Shown instead of `value` when they differ (e.g. "X-High" for `xhigh`).
    public let label: String?
    /// One-line description, same role as `BotCommand.summary`.
    public let summary: String?
    /// Lowercased values that suppress this suggestion when already on the
    /// line. Encodes the bridge's static grammar constraints — mutual
    /// exclusion is two suggestions listing each other (`--claude` ↔
    /// `--codex`), a dependency is one-way (`--browser` is Claude-only, so
    /// `--codex` suppresses it). The palette must not build a command line
    /// the bridge will refuse.
    public let conflictsWith: Set<String>

    public init(
        value: String,
        label: String? = nil,
        summary: String? = nil,
        conflictsWith: Set<String> = []
    ) {
        self.value = value
        self.label = label
        self.summary = summary
        self.conflictsWith = conflictsWith
    }

    /// What the palette row displays.
    public var displayLabel: String { label ?? value }

    /// Flags (`--x`) compose, so several can ride one command line; plain
    /// values fill a single slot. The resolver keys re-offering off this.
    public var isFlag: Bool { value.hasPrefix("--") }
}

/// Which of the bridge's session-scoped lists supplies a command's
/// argument values. These lists are agent-dependent and the bridge owns
/// them, so they ride the status frame (`SessionStatus.modelOptions` /
/// `effortLevels`) instead of being copied into the catalog — the catalog
/// names the source, never the values.
public enum SessionArgSource: Equatable, Hashable, Sendable {
    case modelOptions
    case effortLevels
}

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
    /// Statically-known argument completions, offered by the palette once
    /// the command is typed in full. Empty for free-text arguments.
    public let argSuggestions: [ArgSuggestion]
    /// The bridge-owned list this command's values come from, when they
    /// aren't static. `nil` for every command whose grammar the catalog
    /// knows in full; the resolver appends the session's list to
    /// `argSuggestions` when it's set.
    public let sessionArgSource: SessionArgSource?

    public init(
        trigger: String,
        summary: String,
        argHint: String? = nil,
        argSuggestions: [ArgSuggestion] = [],
        sessionArgSource: SessionArgSource? = nil
    ) {
        self.trigger = trigger
        self.summary = summary
        self.argHint = argHint
        self.argSuggestions = argSuggestions
        self.sessionArgSource = sessionArgSource
    }
}

/// Static slash-command catalogs per bot kind, plus a small filter helper
/// used by the composer's slash palette.
public enum BotCommandCatalog {
    /// The agent-picker flags every session-creating command accepts.
    /// Summaries match the bridge's /help text.
    private static let agentFlags = [
        ArgSuggestion(value: "--claude", summary: "Use the Claude agent",
                      conflictsWith: ["--codex"]),
        ArgSuggestion(value: "--codex", summary: "Use the Codex agent",
                      conflictsWith: ["--claude"]),
    ]

    /// Claude-only session extra; ~400M of headless Chrome, so opt-in.
    /// The bridge refuses it on a Codex line, hence the conflict.
    private static let browserFlag = ArgSuggestion(
        value: "--browser", summary: "Add browser tools (chrome-devtools MCP)",
        conflictsWith: ["--codex"])

    /// Static catalog for the Claude bridge. In Phase 5+ this becomes
    /// config-driven (per-bot, served by the bridge or its provisioner).
    public static let claudeBridge: [BotCommand] = [
        // Sessions
        BotCommand(trigger: "/start", summary: "Start a new session",
                   argHint: "[--claude|--codex] [--browser] [workdir]",
                   argSuggestions: agentFlags + [browserFlag]),
        BotCommand(trigger: "/stop", summary: "Stop the current session"),
        BotCommand(trigger: "/restart", summary: "Stop and immediately resume the session",
                   argHint: "[--force] [--browser]",
                   argSuggestions: [
                       ArgSuggestion(value: "--force", summary: "Restart immediately, even mid-turn"),
                       browserFlag,
                   ]),
        BotCommand(trigger: "/resume", summary: "Resume a previous session",
                   argHint: "[--claude|--codex] [n|id]",
                   argSuggestions: agentFlags),
        BotCommand(trigger: "/sessions", summary: "List past sessions",
                   argHint: "[--claude|--codex]",
                   argSuggestions: agentFlags),
        BotCommand(trigger: "/workdir", summary: "Start a session in a different directory",
                   argHint: "[--claude|--codex] <path>",
                   argSuggestions: agentFlags),
        // Info
        BotCommand(trigger: "/status", summary: "Show current session info"),
        BotCommand(trigger: "/agent", summary: "Show the current agent"),
        BotCommand(trigger: "/switch", summary: "Hand this conversation to the other coding agent",
                   argHint: "<claude|codex>",
                   argSuggestions: [
                       ArgSuggestion(value: "claude", summary: "Hand over to Claude"),
                       ArgSuggestion(value: "codex", summary: "Hand over to Codex"),
                   ]),
        BotCommand(trigger: "/working", summary: "Toggle tool call visibility"),
        BotCommand(trigger: "/mcp", summary: "Show MCP server status"),
        // The values for these two are the bridge's to publish: the model
        // aliases are agent-dependent, and the effort levels are a list the
        // bridge enumerates. No suggestions until a status frame carries
        // them — honest where a stale hardcoded copy would not be.
        BotCommand(trigger: "/model", summary: "Show or switch the model",
                   argHint: "[alias]", sessionArgSource: .modelOptions),
        BotCommand(trigger: "/effort", summary: "Show or set effort level",
                   argHint: "[level]", sessionArgSource: .effortLevels),
        BotCommand(trigger: "/mode", summary: "Show or switch interactive vs print",
                   argHint: "[interactive|print]",
                   argSuggestions: [
                       ArgSuggestion(value: "interactive", summary: "Interactive TUI mode"),
                       ArgSuggestion(value: "print", summary: "Non-interactive print mode"),
                   ]),
        BotCommand(trigger: "/cost", summary: "Show session cost"),
        BotCommand(trigger: "/usage", summary: "Show token usage"),
        BotCommand(trigger: "/limits", summary: "Show subscription usage limits"),
        BotCommand(trigger: "/tools", summary: "List available tools"),
        // Context
        BotCommand(trigger: "/context", summary: "Show what's using the context window"),
        BotCommand(trigger: "/compact", summary: "Compact the conversation to free context", argHint: "[instructions]"),
        // Account
        BotCommand(trigger: "/login", summary: "Log in to your Anthropic account"),
        BotCommand(trigger: "/logout", summary: "Log out of your Anthropic account"),
        // Misc
        BotCommand(trigger: "/timer", summary: "Send a message to this chat later",
                   argHint: "<duration> <message> | cancel <id|all>",
                   argSuggestions: [
                       ArgSuggestion(value: "cancel", summary: "Cancel a pending timer"),
                   ]),
        // The rescue keystrokes are bang-only on the bridge: a typed "/esc"
        // is NOT intercepted — it falls through as a TUI slash passthrough
        // and lands in the agent's terminal as a junk command. The palette
        // must complete the bang form. (The filter matches either prefix,
        // so typing "/es…" still surfaces it.)
        BotCommand(trigger: "!esc", summary: "Cancel the current turn"),
        BotCommand(trigger: "!enter", summary: "Press Enter in the agent's terminal"),
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

    /// Mirrors the bridge's `LEADING_UNICODE_DASHES` rule
    /// (lib/command-dispatch.js): phone keyboards auto-correct a leading
    /// `--` into a single em/en dash, and the bridge normalizes it back
    /// before parsing — so anything comparing typed tokens to flags must
    /// do the same.
    public static func normalizeLeadingDashes(_ token: some StringProtocol) -> String {
        String(token).replacingOccurrences(
            of: "^[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}]+",
            with: "--", options: .regularExpression)
    }

    /// The values `status` supplies for a command that draws them from the
    /// session rather than the catalog. Absent and empty lists both come
    /// back empty here — the distinction lives in the model, and matters
    /// only to the merge that produced it.
    ///
    /// Values repeated by the bridge collapse to their first occurrence,
    /// keeping the order it sent. This pool is remote-controlled input, and
    /// the palette identifies rows by value: duplicates would give a
    /// `ForEach` two rows with one identity.
    private static func sessionSuggestions(
        _ source: SessionArgSource?, _ status: () -> SessionStatus?
    ) -> [ArgSuggestion] {
        guard let source, let status = status() else { return [] }
        let options: [SessionStatus.Option]?
        switch source {
        case .modelOptions: options = status.modelOptions
        case .effortLevels: options = status.effortLevels
        }
        var seen: Set<String> = []
        return (options ?? []).compactMap { option in
            guard seen.insert(option.value.lowercased()).inserted else { return nil }
            return ArgSuggestion(value: option.value, label: option.label)
        }
    }

    /// Resolves the argument suggestions for a raw composer input: the
    /// matched command's suggestions — static, plus whatever `status`
    /// supplies for a session-derived command — filtered by the trailing
    /// partial token. Empty unless the input is a fully-typed command
    /// (either `/` or `!` prefix) followed by whitespace.
    ///
    /// A nil `status` (no bridge has spoken, or the caller has no session)
    /// leaves session-derived commands offering nothing, which is exactly
    /// the pre-status-frame behaviour. `status` is an autoclosure and is
    /// evaluated only once a session-derived command has actually matched:
    /// the composer's reads it out of the chat view model, and doing that
    /// on every keystroke would make the composer observe every status
    /// frame for input that isn't a command at all.
    ///
    /// Flags compose, so a flag stays offered until it's on the line or a
    /// conflicting one is (`conflictsWith`) — but only while the trailing
    /// positional slot is open: the grammar is `[flags] [path]`, so a
    /// completed non-flag token ends the offering. Plain values fill a
    /// single slot and are only offered while no argument token is down
    /// yet (`/switch claude codex` is junk the palette must not build).
    /// A suggestion identical to the partial offers nothing — same rule
    /// as folder completion, so the palette doesn't linger over a
    /// completed flag.
    public static func argSuggestions(
        for input: String, in commands: [BotCommand],
        status: @autoclosure () -> SessionStatus? = nil
    ) -> [ArgSuggestion] {
        let leading = Substring(input.drop(while: { $0 == " " || $0 == "\t" }))
        guard let first = leading.first, first == "/" || first == "!" else { return [] }
        let body = leading.dropFirst()
        // The command must be complete: whitespace after its token.
        guard let commandEnd = body.firstIndex(where: { $0.isWhitespace }) else { return [] }
        let name = body[body.startIndex..<commandEnd].lowercased()
        guard let command = commands.first(where: {
            $0.trigger.lowercased().drop(while: { $0 == "/" || $0 == "!" }) == name
        }) else { return [] }

        // Trailing partial = everything after the last whitespace (empty
        // when the input ends mid-separator); earlier tokens are complete.
        let args = body[commandEnd...]
        let partialStart = args.lastIndex(where: { $0.isWhitespace })
            .map(args.index(after:)) ?? args.startIndex
        let partial = normalizeLeadingDashes(args[partialStart...]).lowercased()
        let earlier = Set(args[..<partialStart]
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalizeLeadingDashes($0).lowercased() })
        let positionalFilled = earlier.contains { !$0.hasPrefix("--") }

        let pool = command.argSuggestions
            + sessionSuggestions(command.sessionArgSource, status)
        return pool.filter { suggestion in
            let value = suggestion.value.lowercased()
            if suggestion.isFlag {
                if positionalFilled || earlier.contains(value) { return false }
            } else if !earlier.isEmpty {
                return false
            }
            guard suggestion.conflictsWith.isDisjoint(with: earlier) else { return false }
            return value.hasPrefix(partial) && value != partial
        }
    }
}
