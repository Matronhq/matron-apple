# Composer argument suggestions, and a status frame that carries what it knows

The slash palette completes the command and then stops. Type `/restart` and it
offers nothing further, though the bridge accepts `--force` and `--browser`.
Type `/model` and it offers nothing, though the bridge has eight aliases ready
to switch to. The information exists; it just never reaches the composer.

This design carries it there, and takes two adjacent asks along the way: the
session's effort level, which nothing currently reports, and the working
directory, which the Mac header shows and the iPhone header does not.

## What is wrong today

The app's command catalog — `BotCommandCatalog.claudeBridge` in
`MatronShared/Sources/Models/BotCommand.swift` — has drifted behind the bridge
it describes. Against the bridge's own `/help` text:

| Command | The catalog says | The bridge accepts |
|---|---|---|
| `/restart` | no arguments | `--force`, `--browser` |
| `/start` | `[workdir]` | `--claude\|--codex`, `--browser`, `[workdir]` |
| `/resume` | `[n\|id]` | `--claude\|--codex` as well |
| `/sessions` | no arguments | `--claude\|--codex` |
| `/workdir` | `<path>` | `--claude\|--codex` as well |
| `/effort` | `[level]` | `low, medium, high, xhigh, max, auto, ultracode` |
| `/timer` | `<duration> <message>` | also bare (lists), and `cancel <id\|all>` |
| `/model` | no arguments | eight aliases, agent-dependent |

Two of these are worse than incomplete: `/restart` and `/model` are documented
as taking nothing at all, so a user reading the palette would conclude the
flags don't exist.

The drift is not an oversight to be corrected once. The catalog is a hand-kept
copy of a list that lives somewhere else, and it will drift again the moment
the bridge gains a command — which is the argument for fixing the mechanism
for the one list that actually moves, rather than only refreshing the copy.

## Argument suggestions

The palette already has a second-parameter mode. `ComposerViewModel`'s
`folderSuggestions` switches it from commands to recent folders when the input
is `/start ` or `/workdir ` followed by a partial path, and
`SlashCommandPalette` renders folder rows instead of command rows. The
mechanism exists; it is hardcoded to two commands and one kind of suggestion.

Generalise it. `BotCommand` gains a list of argument suggestions, and the
palette's second mode becomes "the selected command's suggestions, filtered by
what has been typed after it" — with recent folders as one source among
several rather than the only one.

```swift
public struct ArgSuggestion {
    public let value: String     // inserted verbatim: "--browser", "high", "cancel"
    public let label: String?    // shown instead of value when they differ: "X-High"
    public let summary: String?  // one line, same role as BotCommand.summary
}
```

Three sources feed it, and the distinction between them is the whole point:

- **Static** — flags and enumerated values that are part of the command's
  grammar and change only when the bridge's command surface changes:
  `--force`, `--browser`, `--claude`, `--codex`, `interactive`, `print`,
  `claude`, `codex`, and `/timer`'s `cancel`. These are safe to hold in the
  catalog because they are the same shape as the trigger itself.
- **Local** — recent folders, already implemented, now expressed as one
  command's suggestion source instead of a special case in the view model.
- **Session-derived** — the model aliases and effort levels, which come from
  the bridge over the status frame. See the next section.

`/effort`'s seven levels sit awkwardly between static and session-derived.
They are enumerated in the bridge (`EFFORT_LEVELS` in `lib/effort-command.js`)
and have been stable, but they are a list the bridge owns, so they travel the
same route as the model aliases rather than being copied into the app. One
mechanism for both is simpler than two, and the fallback (no suggestions when
the bridge hasn't said) is honest in a way a stale hardcoded list is not.

Selection inserts `value` plus a trailing space, matching what
`selectCommand(_:)` already does, so `/timer cancel ` immediately offers the
next thing. Keyboard selection goes through the existing `rowCount` and
index-based selection path, which already has to mirror the palette's display
rule — that mirroring requirement does not change, it just now has more than
two modes to mirror.

Commands with a free-text argument — `/compact [instructions]`, `/timer`'s
message, `/workdir`'s path beyond the recent-folder matches — have no
suggestions and the palette dismisses, as it does today.

## What the status frame should carry

The bridge already publishes a session status object — `buildSessionStatus` in
`lib/session-status.js` — carrying `model`, context tokens, limits, email,
`workdir` and `vitals`. The apps merge it into `SessionStatus` field by field
and stickily: `if let model = update.model { self.model = model }`. A field,
once received, persists until something newer overwrites it.

That merge behaviour is what makes the status frame the right carrier for
suggestions rather than a new endpoint. It gives, with no new machinery:

- population when the session starts, since status is built then;
- caching, because the sticky merge means the app holds the last list and the
  palette never fetches on open — `/model` opens instantly;
- periodic refresh, because it rides the existing status repaint
  (`statusRepaintDue`), so a bridge that learns a new model publishes it on the
  next status without being asked;
- graceful degradation, because an older bridge omits the field and the app
  shows no suggestions — exactly today's behaviour, no version negotiation.

It also settles the Claude-versus-Codex split for free. Status is
session-scoped, so the bridge sends whichever list fits that session's agent —
aliases for Claude, model ids for Codex — and the app never needs to know
which agent it is talking to.

### `model_options`

```
status.model_options: [{ value: "opus", label: "Opus" }, …]
```

Built from the bridge's existing `SWITCHABLE_ALIASES` (`lib/model-aliases.js`),
which already carries exactly these two fields and already decides what is
offered as a button. `best` remains valid to type and absent from the list,
matching the buttons today. For a Codex session the bridge sends what Codex
accepts, or omits the field.

### `effort_levels` and `effort`

`effort_levels` mirrors `model_options`, built from `EFFORT_LEVELS`.

`effort` is the current level, and it is the one field here the bridge does not
already know.

## Effort: what the bridge can honestly report

`/effort <level>` is fire-and-forget. The bridge writes `/effort <level>` into
the PTY and replies "Switching effort to X… (Claude may ask you to confirm.)",
hedged because the TUI raises a "Change effort level?" confirmation the user
can decline. Nothing reads the level back: no event carries it (there is no
counterpart to `modelFromEvent`'s `message.model`), no config file holds it,
and the bridge passes `--model` but no effort flag at spawn, so even the
starting value is unknown to it. For Codex it is not exposed at all — the
bridge says so in its own reply text.

So the bridge cannot report the effort level by reading it. It has to track it,
and the tracking must be honest about its own gaps.

**Optimistic tracking, with the confirmation loop closed.** The bridge already
surfaces the TUI's confirmation as buttons (`lib/prompt-detector.js`,
`lib/prompt-buttons.js`), so the answer passes through it. The rule:

- effort starts **unknown**, and unknown is published as absent, not as a
  guess;
- writing `/effort X` into the PTY does not itself set it — a confirmed
  change does;
- when no confirmation appears, the write stands — "no confirmation" means the
  prompt detector saw none before the session went idle again, which is the
  same signal the bridge already uses to decide a TUI prompt is not coming;
- a declined confirmation leaves the previous value, including unknown;
- session start, restart and resume reset it to unknown.

The last rule is the one that matters. Carrying a value across a restart would
be the one case where the app confidently shows something false, because the
restarted session's effort comes from Claude Code's own default rather than
from anything the bridge did. Dropping to unknown costs a blank field until
the user next sets effort through Matron; carrying it costs a lie.

The gap this design accepts: effort changed by typing `/effort` directly into
the terminal on the host is invisible to the bridge, and the app will show the
last level Matron set until the next restart clears it. That is a real
staleness window, accepted because the alternative is showing nothing ever, and
because setting effort through Matron is the path this feature exists to serve.

The apps render effort where they render the model — beside it in the status
sheet and the Mac toolbar — and render nothing when it is absent.

## The iPhone header

`MacChatToolbar` is documented as "Center: title (+ workdir and account email
underneath when known)" and shows the workdir home-abbreviated beneath the
title. The iPhone receives `status.workdir` already and buries it in
`SessionStatusSheet`, which costs a tap to answer "which checkout is this?" —
the question most worth answering at a glance when several sessions are open.

Show it in the iPhone header beneath the title, home-abbreviated through the
existing `UsageMetersFormat.homeAbbreviated`, matching the Mac's treatment.
Absent workdir shows nothing and the title keeps its current position; the
header must not reserve space for a line it may not have, which is the failure
mode `Text("")` produced in the compact banner work.

## Testing

The pure parts carry the weight, and all three are pure:

- **Suggestion resolution** — given a command and the text typed after it,
  which suggestions and in what order. Covers the empty-argument case (all of
  them), prefix filtering, no-match dismissal, and free-text commands offering
  nothing. This is `BotCommandCatalog.filter`'s sibling and tests the same way.
- **Status decoding and merge** — `model_options`, `effort_levels` and
  `effort` decode; each merges stickily; an omitted field leaves the previous
  value standing; a bridge that never sends them leaves the app in today's
  behaviour. The absent-versus-empty distinction matters: an empty list means
  "this agent offers nothing", absent means "this bridge doesn't say", and both
  must render as no suggestions without being conflated in the model.
- **Effort tracking (bridge)** — a confirmed change sets it, a declined one
  does not, a change with no confirmation sets it, and start/restart/resume
  clear it. These are the four rules above, one test each, and they are the
  only place the design can silently start lying.

The palette views get the same snapshot treatment the existing rows have. The
iPhone header needs one test that an absent workdir does not shift the title.

## Shipping

Two changes, in this order, because the second depends on a bridge deploy and
the first does not:

1. **Apps only** — the `ArgSuggestion` mechanism, the static suggestions, the
   iPhone header workdir, and every catalog correction in the table above
   *except* `/model`'s aliases and `/effort`'s levels, which are session-derived
   and arrive in (2). Concretely that is `/restart`'s two flags, the agent flags
   on `/start`, `/resume`, `/sessions` and `/workdir`, `/timer`'s three forms,
   and making `/switch` and `/mode`'s values selectable rather than hinted.
   Ships and is useful with today's bridge.
2. **Bridge, then apps** — `model_options`, `effort_levels` and `effort` on the
   status frame, effort tracking behind them, and the app consuming all three.
   The bridge half must be deployed before the app half is useful, and the app
   half degrades to (1)'s behaviour until it is.

Android follows the apps in each case, as it does for every composer and status
change.
