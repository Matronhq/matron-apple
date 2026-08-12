# New Chat chooser: per-box activity, usage limits, and account

**Date:** 2026-08-11
**Status:** Approved
**Companion specs:** matron-bridge `2026-08-11-recent-folders-account-design.md`
(account block); matron-journal `2026-08-09-agent-spawns-session-design.md`
(where the capacity blocks were introduced for agents). The Android app ports
this design 1:1 (`matron-android`, same VM/UI split).

## Problem

Agents picking a box for a spawned session can now see each box's live
sessions and usage limits (`spawn_targets`). The human picking a box in the
New Chat sheet sees only "Connected / Offline". The user wants the same
signals — how busy is each box, how much quota is left, and **which account
it's logged in to** — on the machine-picker step itself.

## What already flows

The bridge attaches capacity blocks to its `recent_folders` RPC reply:

```json
{
  "folders": [{"path": "...", "last_used": 123}],
  "activity": { "live_sessions": 2, "last_hour": [{"path": "...", "sessions": 1}] },
  "limits": { "as_of": 1754900000000, "lines": [
      {"id": "session", "label": "Current session", "percent": 39,
       "resets": "…", "resets_at": "2026-08-11T23:59:00Z"} ] },
  "account": { "email": "pat@yearbook.com" }
}
```

The journal's RPC relay forwards this verbatim to the requesting client, so
the app already receives everything; it currently parses only `folders`.
(`account` is new — bridge companion spec.) Every capacity key is optional:
an old bridge simply omits them.

## Design

### Fetch strategy: fan out on sheet open

`NewChatViewModel.load()` keeps its current shape (roster from `devices()`,
auto-skip when exactly one connected agent). After the roster is shown, the
VM fires `recent_folders` at **every connected agent in parallel** (2–5
boxes in practice) and fills a `capacities: [DeviceID: BoxCapacity]` map as
replies land. Rules:

- The roster renders immediately; each connected row shows a subtle
  placeholder ("Checking…") until its reply lands, then the capacity lines.
- A timeout/failure for one box leaves that row exactly as today (name +
  "Connected") — capacity is a convenience, never a gate; the row stays
  pickable throughout, even while "Checking…".
- Replies also populate a folders cache, so `select(agent:)` renders the
  folder step instantly from cache (still falling back to a live RPC if that
  box's fan-out reply failed or hasn't landed).
- Replies arriving after the user has moved on (sheet dismissed, agent
  picked) are applied to the map harmlessly; stale-phase guards as today.
- The auto-skip path (single connected agent) is unchanged — it goes
  straight to folders and needs no picker-row data.

### Parsing

New file `MatronShared/Sources/Models/BoxCapacity.swift` (`MatronModels`, like
`SessionStatus`, so the design-system row can see it without depending on
the view models):

```swift
struct LimitLine: Equatable, Sendable { id, label: String; percent: Int; resetsAt: Date? }
struct BoxAccount: Equatable, Sendable { email: String }
struct BoxCapacity: Equatable, Sendable {
    liveSessions: Int?          // activity.live_sessions
    limitLines: [LimitLine]     // limits.lines, bridge order preserved
    account: BoxAccount?
}
```

Parsed defensively field-by-field from the same reply JSON as the folders: a
malformed or missing block degrades that block to nil/empty and never fails
the folders parse. `last_hour` is parsed but **not displayed** (spawn-side
detail; the folder step already shows recent paths). `percent` is clamped to
0…999. `resets_at` (ISO-8601) parses in fractional-second and plain form
alike, as `WireModels` does; unparseable → nil (line still shown, without a
reset).

### Row UI (Mac `MacNewChatSheet`, iOS `NewChatSheet`)

Each connected agent row becomes:

```
[icon]  studio-mac                    pat@yearbook.com
        2 active sessions
        Current session          39%  · resets 11:59 pm
        Current week (all)       66%  · resets Jul 15
```

- Name line: device name (as today) with the account email trailing in
  secondary style (caption). No account block → nothing shown.
- Sessions line: "N active session(s)"; 0 → "No active sessions";
  no activity block → line omitted.
- Limit lines: **all** lines, bridge order, each showing `label`,
  `percent` and a compact reset ("resets " + time-only if today in the local
  calendar, else abbreviated date). Percent text tinted by the shared
  thresholds: green < 50, orange < 80, red ≥ 80 (matches the `/usage` card
  idiom). No limits block → lines omitted.
- Offline rows unchanged ("Offline · Last seen …", not pickable).
- Layout: rows are now variable-height; the Mac sheet's fixed
  `frame(height: 200)` list grows to fit (cap the sheet height and let the
  list scroll); iOS is already a scrolling list.

Percent-threshold colors live in one shared helper (DesignSystem) so both
platforms and any future surfaces agree.

### Error handling

- No new error surfaces: fan-out failures are silent per-row degradation.
- The existing `foldersError` path on the folder step still covers a live
  `recent_folders` failure after selection.

## Testing

- `NewChatViewModelTests`: fan-out fires once per connected agent only;
  capacity map fills per-reply; one failing box doesn't touch others; folder
  cache hit skips the second RPC; late reply after phase change is harmless.
- `BoxCapacity` parsing: full block, each block missing, malformed entries,
  clamps, ISO date; account block with a non-string email → nil.
- Mac snapshot test pinning a chooser with: full capacity row, capacity-less
  row (old bridge), offline row. (`MATRON_APP_SUPPORT_OVERRIDE` as always.)
