import XCTest
@testable import MatronModels

final class BotCommandCatalogTests: XCTestCase {
    func test_filter_emptyPrefix_returnsAll() {
        let all = BotCommandCatalog.claudeBridge
        let filtered = BotCommandCatalog.filter(all, byPrefix: "")
        XCTAssertEqual(filtered.count, all.count)
    }

    func test_filter_matchesPrefixCaseInsensitive() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "/STA")
        XCTAssertTrue(filtered.contains { $0.trigger == "/start" })
        XCTAssertTrue(filtered.contains { $0.trigger == "/status" })
        XCTAssertFalse(filtered.contains { $0.trigger == "/stop" })
    }

    func test_filter_acceptsBangPrefix() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "!resu")
        XCTAssertTrue(filtered.contains { $0.trigger == "/resume" })
    }

    func test_filter_noMatch_returnsEmpty() {
        let filtered = BotCommandCatalog.filter(BotCommandCatalog.claudeBridge, byPrefix: "/doesnotexist")
        XCTAssertTrue(filtered.isEmpty)
    }

    /// Pins the claude-native passthrough commands the palette must surface
    /// (Dan, 2026-07-15): context/compaction plus account login/logout —
    /// the bridge forwards these into the session rather than intercepting.
    func test_claudeBridge_includesContextAndAccountCommands() {
        let triggers = Set(BotCommandCatalog.claudeBridge.map(\.trigger))
        for expected in ["/context", "/compact", "/login", "/logout"] {
            XCTAssertTrue(triggers.contains(expected), "catalog must include \(expected)")
        }
    }

    /// Pins the 2026-08-05 palette audit against the bridge's command set:
    /// /timer and /switch were missing entirely, and the rescue keystrokes
    /// must be the bang forms — the bridge only intercepts "!esc"/"!enter";
    /// a typed "/esc" passes through into the agent's terminal as junk.
    func test_claudeBridge_includesTimerSwitchAndBangRescues() {
        let triggers = Set(BotCommandCatalog.claudeBridge.map(\.trigger))
        for expected in ["/timer", "/switch", "!esc", "!enter"] {
            XCTAssertTrue(triggers.contains(expected), "catalog must include \(expected)")
        }
        XCTAssertFalse(triggers.contains("/esc"), "slash-form esc is not a bridge command")
    }

    func test_claudeBridge_isNonEmpty_andHasUniqueTriggers() {
        let all = BotCommandCatalog.claudeBridge
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(Set(all.map(\.trigger)).count, all.count, "command triggers must be unique")
    }

    // MARK: - Static argument suggestions (2026-08-10 spec, phase 1)

    private func command(_ trigger: String) -> BotCommand? {
        BotCommandCatalog.claudeBridge.first { $0.trigger == trigger }
    }

    /// Pins the two flags the 2026-08-10 audit found documented as
    /// nonexistent: the catalog said /restart took no arguments at all,
    /// so the palette denied flags the bridge accepts.
    func test_claudeBridge_restartOffersForceAndBrowser() {
        let values = command("/restart")?.argSuggestions.map(\.value)
        XCTAssertEqual(values, ["--force", "--browser"])
    }

    /// Every session-creating command accepts the agent-picker flags.
    func test_claudeBridge_agentFlagsOnSessionCommands() {
        for trigger in ["/start", "/resume", "/sessions", "/workdir"] {
            let values = Set(command(trigger)?.argSuggestions.map(\.value) ?? [])
            XCTAssertTrue(values.isSuperset(of: ["--claude", "--codex"]),
                          "\(trigger) must offer --claude and --codex")
        }
    }

    func test_claudeBridge_startOffersBrowser() {
        let values = command("/start")?.argSuggestions.map(\.value) ?? []
        XCTAssertTrue(values.contains("--browser"))
    }

    /// /switch and /mode had their values only as an argHint; the spec
    /// makes them selectable rows.
    func test_claudeBridge_switchAndModeValuesSelectable() {
        XCTAssertEqual(command("/switch")?.argSuggestions.map(\.value), ["claude", "codex"])
        XCTAssertEqual(command("/mode")?.argSuggestions.map(\.value), ["interactive", "print"])
    }

    func test_claudeBridge_timerOffersCancel() {
        XCTAssertEqual(command("/timer")?.argSuggestions.map(\.value), ["cancel"])
    }
}

/// `BotCommandCatalog.argSuggestions(for:in:)` — the pure resolver behind
/// the palette's argument-completion mode: given the raw composer input,
/// which of the matched command's static suggestions apply. Sibling of
/// `BotCommandCatalog.filter` and tested the same way.
final class ArgSuggestionResolutionTests: XCTestCase {
    private func resolve(_ input: String) -> [String] {
        BotCommandCatalog.argSuggestions(for: input, in: BotCommandCatalog.claudeBridge).map(\.value)
    }

    func test_completeCommandWithEmptyPartial_offersAll() {
        XCTAssertEqual(resolve("/restart "), ["--force", "--browser"])
    }

    func test_partialFlag_filtersCaseInsensitive() {
        XCTAssertEqual(resolve("/restart --B"), ["--browser"])
    }

    func test_typedFlag_isNotReoffered() {
        XCTAssertEqual(resolve("/restart --force "), ["--browser"])
    }

    func test_partialIdenticalToSuggestion_offersNothing() {
        // Mirrors the folder rule: a suggestion equal to what's already
        // typed offers nothing, so the palette doesn't linger once the
        // flag is complete.
        XCTAssertEqual(resolve("/restart --browser"), [])
    }

    func test_incompleteCommandToken_offersNothing() {
        // No whitespace after the command yet — the command list, not the
        // argument list, owns this input.
        XCTAssertEqual(resolve("/restart"), [])
    }

    func test_commandPrefixIsNotACommand() {
        // "/rest" prefix-matches /restart in the COMMAND palette, but the
        // argument resolver needs the full trigger.
        XCTAssertEqual(resolve("/rest --f"), [])
    }

    func test_unknownCommand_offersNothing() {
        XCTAssertEqual(resolve("/doesnotexist --x"), [])
    }

    func test_freeTextCommands_offerNothing() {
        XCTAssertEqual(resolve("/stop "), [])
        XCTAssertEqual(resolve("/compact tighten it "), [])
    }

    /// Value suggestions (no `--`) fill a single slot: once any argument
    /// token is down, they stop being offered — `/switch claude codex`
    /// is junk and the palette must not build it.
    func test_values_offeredOnlyForFirstArgument() {
        XCTAssertEqual(resolve("/switch "), ["claude", "codex"])
        XCTAssertEqual(resolve("/switch claude "), [])
        XCTAssertEqual(resolve("/timer cancel "), [])
    }

    /// Flags compose, so later slots keep offering the remaining ones.
    func test_flags_remainOfferedAfterEarlierFlags() {
        XCTAssertEqual(resolve("/restart --force "), ["--browser"])
    }

    /// Mutually exclusive flags must not be offered together — the bridge
    /// refuses "/start --claude --codex" ("Choose only one agent"), so the
    /// palette must not build it from two taps. --browser is Claude-only,
    /// so a --codex line drops it too.
    func test_exclusiveFlags_notOfferedTogether() {
        XCTAssertEqual(resolve("/start --claude "), ["--browser"])
        XCTAssertEqual(resolve("/start --codex "), [])
        XCTAssertEqual(resolve("/resume --claude "), [])
    }

    /// Phone keyboards auto-correct a leading "--" into an em dash; the
    /// bridge normalizes leading unicode dashes before parsing
    /// (LEADING_UNICODE_DASHES in lib/command-dispatch.js), so the
    /// resolver must match — both in the partial being completed and in
    /// tokens already on the line.
    func test_smartDashes_normalizedLikeTheBridge() {
        XCTAssertEqual(resolve("/restart \u{2014}f"), ["--force"],
                       "an em-dash partial still completes the flag")
        XCTAssertEqual(resolve("/restart \u{2014}browser "), ["--force"],
                       "an em-dash flag counts as typed and is not re-offered")
    }

    /// The bridge's grammar is `[flags] [path]` — once the positional slot
    /// is filled the command line is complete, and the palette must not
    /// re-open over it to offer trailing flags.
    func test_flagsNotOffered_oncePositionalSlotFilled() {
        XCTAssertEqual(resolve("/start ~/proj "), [])
        XCTAssertEqual(resolve("/workdir ~/proj "), [])
    }

    func test_bangPrefix_resolvesLikeSlash() {
        XCTAssertEqual(resolve("!restart "), ["--force", "--browser"])
    }

    func test_leadingWhitespace_isIgnored() {
        XCTAssertEqual(resolve("  /restart "), ["--force", "--browser"])
    }

    func test_plainText_offersNothing() {
        XCTAssertEqual(resolve("just chatting about --force"), [])
    }
}

/// Session-derived argument suggestions (2026-08-10 spec, phase 2): the
/// model aliases and effort levels are lists the BRIDGE owns and publishes
/// on the status frame, so `/model` and `/effort` take their values from
/// `SessionStatus` rather than the catalog. Same resolver, same filtering
/// and single-slot rules as the static values.
final class SessionDerivedArgSuggestionTests: XCTestCase {
    private let status = SessionStatus(
        modelOptions: [
            SessionStatus.Option(value: "opus", label: "Opus"),
            SessionStatus.Option(value: "sonnet", label: "Sonnet"),
            SessionStatus.Option(value: "opusplan", label: "Opus Plan"),
        ],
        effortLevels: [
            SessionStatus.Option(value: "low", label: "Low"),
            SessionStatus.Option(value: "high", label: "High"),
            SessionStatus.Option(value: "xhigh", label: "X-High"),
        ])

    private func resolve(_ input: String, _ status: SessionStatus? = nil) -> [String] {
        BotCommandCatalog.argSuggestions(
            for: input, in: BotCommandCatalog.claudeBridge, status: status).map(\.value)
    }

    /// The catalog declares WHERE a command's values come from; it can't
    /// hold the values themselves, because they're agent-dependent.
    func test_claudeBridge_modelAndEffortDeclareSessionSources() {
        let catalog = BotCommandCatalog.claudeBridge
        XCTAssertEqual(catalog.first { $0.trigger == "/model" }?.sessionArgSource, .modelOptions)
        XCTAssertEqual(catalog.first { $0.trigger == "/effort" }?.sessionArgSource, .effortLevels)
        XCTAssertNil(catalog.first { $0.trigger == "/switch" }?.sessionArgSource,
                     "statically-known values keep their catalog list")
    }

    func test_emptyArgument_offersEveryOption() {
        XCTAssertEqual(resolve("/model ", status), ["opus", "sonnet", "opusplan"])
        XCTAssertEqual(resolve("/effort ", status), ["low", "high", "xhigh"])
    }

    func test_partialFiltersByPrefix_caseInsensitively() {
        XCTAssertEqual(resolve("/model op", status), ["opus", "opusplan"])
        XCTAssertEqual(resolve("/effort X", status), ["xhigh"])
    }

    func test_noMatch_dismisses() {
        XCTAssertEqual(resolve("/model gpt", status), [])
    }

    func test_partialIdenticalToOption_offersNothing() {
        XCTAssertEqual(resolve("/model opus", status), ["opusplan"],
                       "an exact match drops out, longer values still complete")
        XCTAssertEqual(resolve("/effort high", status), [])
    }

    /// These are values, not flags: one fills the slot and the palette is
    /// done — "/model opus sonnet" is a line the bridge would refuse.
    func test_valuesFillASingleSlot() {
        XCTAssertEqual(resolve("/model opus ", status), [])
        XCTAssertEqual(resolve("/effort high ", status), [])
    }

    /// An older bridge never sends the lists. Absent means "this bridge
    /// doesn't say" and offers nothing — exactly today's behaviour, no
    /// version negotiation.
    func test_absentLists_offerNothing() {
        XCTAssertEqual(resolve("/model "), [])
        XCTAssertEqual(resolve("/effort "), [])
        XCTAssertEqual(resolve("/model ", SessionStatus(model: "opus")), [])
    }

    /// Empty means "this agent offers nothing" — same rendering, different
    /// statement (a Codex session with no switchable models).
    func test_emptyLists_offerNothing() {
        let none = SessionStatus(modelOptions: [], effortLevels: [])
        XCTAssertEqual(resolve("/model ", none), [])
        XCTAssertEqual(resolve("/effort ", none), [])
    }

    /// The label rides through to the palette row; a value without one
    /// displays as itself.
    func test_labelsSurviveResolution() {
        let suggestions = BotCommandCatalog.argSuggestions(
            for: "/model ", in: BotCommandCatalog.claudeBridge, status: status)
        XCTAssertEqual(suggestions.map(\.displayLabel), ["Opus", "Sonnet", "Opus Plan"])

        let unlabelled = SessionStatus(modelOptions: [SessionStatus.Option(value: "opus", label: nil)])
        XCTAssertEqual(
            BotCommandCatalog.argSuggestions(
                for: "/model ", in: BotCommandCatalog.claudeBridge, status: unlabelled)
                .map(\.displayLabel),
            ["opus"])
    }

    /// A session's lists belong to the command that declared them —
    /// nothing leaks into the statically-catalogued commands.
    func test_sessionListsDoNotLeakToOtherCommands() {
        XCTAssertEqual(resolve("/switch ", status), ["claude", "codex"])
        XCTAssertEqual(resolve("/restart ", status), ["--force", "--browser"])
    }

    func test_bangPrefixAndCaseResolveLikeSlash() {
        XCTAssertEqual(resolve("!MODEL son", status), ["sonnet"])
    }

    /// The pool is remote-controlled now, so a bridge that publishes the
    /// same value twice must not produce two rows — the palette's `ForEach`
    /// identifies rows by value, and duplicate ids drop or duplicate rows.
    /// First occurrence wins, so the bridge's ordering survives.
    func test_duplicateOptions_collapseKeepingBridgeOrder() {
        let repeated = SessionStatus(modelOptions: [
            SessionStatus.Option(value: "opus", label: "Opus"),
            SessionStatus.Option(value: "sonnet", label: "Sonnet"),
            SessionStatus.Option(value: "OPUS", label: "Opus (again)"),
        ])
        XCTAssertEqual(resolve("/model ", repeated), ["opus", "sonnet"])
        XCTAssertEqual(
            BotCommandCatalog.argSuggestions(
                for: "/model ", in: BotCommandCatalog.claudeBridge, status: repeated)
                .map(\.displayLabel),
            ["Opus", "Sonnet"],
            "the first occurrence is the one kept, label and all")
    }
}
