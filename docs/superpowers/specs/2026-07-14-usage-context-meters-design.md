# Usage + context meters in the chat header

**Date:** 2026-07-14
**Repos:** apps (this repo) + a small claude-matrix-bridge PR.
**Decided with Dan:** Mac shows the meters inline in the chat header —
context gauge left of the title, three usage bars right of it, caption-sized
text. iOS shows the same component in a sheet behind the header ⓘ. The
bot-profile sheet (bot name / Matrix ID / start new chat / all chats) is
removed on both platforms; the Mac ⓘ button goes away entirely. The bridge
parses reset times into normalised ISO timestamps; the app renders them in
local time, switching to a countdown when the reset is near.

## Goal

The bridge already publishes a per-convo `status` frame at turn end
(`{model?, context?: {tokens, window, pct}, limits?: [{label, percent,
resets}]}`; absent parts omitted). The journal caches the last status per
convo, fans it out as `{kind: 'ephemeral', convo_id, status: {…}}`, and
replays it on `viewing`. The apps currently drop the frame (no decode
branch). This feature consumes it:

- **Mac chat header:** `Context: 265k/1m` on the left of the title; on the
  right a stacked three-bar component — `Session:` / `Week:` / `Fable:`
  labels, colored horizontal bars, reset time at the right of each bar.
- **iOS:** the header ⓘ opens a sheet with the same component, replacing
  the current bot-profile sheet.

## Bridge (claude-matrix-bridge)

### 1. `resets_at` on limits entries

`lib/usage-limits.js` gains a pure exported helper:

```js
// "Jul 9, 12:59am (UTC)" -> ISO string, or null when unparseable.
// `now` injected for testability; year chosen so the result is the next
// future occurrence (tolerating up to 24h in the past for clock skew).
export function parseResetsAt(resetsText, now = new Date())
```

- Regex on the fixed format claude prints: `/^([A-Za-z]{3})\s+(\d{1,2}),\s*(\d{1,2}):(\d{2})(am|pm)\s*\(UTC\)$/i`,
  explicit 3-letter month map, `Date.UTC` construction.
- No year in the source string: build with `now`'s UTC year; if the result
  is earlier than `now - 24h`, add one year.
- `parseUsageLimits` calls it per line and adds `resets_at` (ISO 8601
  string) alongside the raw `resets` when parsing succeeds; omits the field
  when it fails. Fail-open: the raw string always survives, the app falls
  back to showing it verbatim.
- No other bridge changes: `index.js` already caches `parsed.lines` and
  `buildSessionStatus` passes `limits` through untouched, so `resets_at`
  flows to the journal for free. The Matrix `/limits` formatter ignores the
  extra field.
- Tests (`test/usage-limits.test.js`): happy parse, pm/am, year rollover
  (Dec now → Jan reset), just-past tolerance, unparseable → null / field
  omitted.

## Apps (matron-apple)

### 2. Value types + decode

The value types live in **MatronModels** (`Sources/Models/SessionStatus.swift`),
not MatronJournal — the design system and view models consume them and
neither depends on the journal module:

```swift
/// Held per-convo status; parts merge (absent = unchanged).
public struct SessionStatus: Equatable, Sendable {
    public struct Context: Equatable, Sendable {
        public let tokens: Int
        public let window: Int
        public let pct: Int
    }
    public struct Limit: Equatable, Sendable {
        public let label: String
        public let percent: Int
        public let resets: String?    // raw text fallback
        public let resetsAt: Date?    // parsed from resets_at (ISO 8601)
    }
    public var model: String?
    public var context: Context?
    public var limits: [Limit]?
    public mutating func apply(_ update: SessionStatusUpdate)
}

/// One decoded `status` ephemeral frame. Ephemeral; the journal replays
/// the last one on `viewing`, so a missed frame is harmless.
public struct SessionStatusUpdate: Equatable, Sendable {
    public let convoID: String
    public let model: String?
    public let context: SessionStatus.Context?
    public let limits: [SessionStatus.Limit]?
}
```

`ServerFrame` gains `case sessionStatus(SessionStatusUpdate)`. The decode
branch slots into the ephemeral section keyed on the `status` object —
after `tool_stream`, before the `message_ref` guard, mirroring the
`activity` branch. `resets_at` parses with `ISO8601DateFormatter`
(`.withInternetDateTime, .withFractionalSeconds` first, plain fallback);
a malformed timestamp degrades to nil, keeping the raw string. A `context`
object missing any of `tokens`/`window`/`pct` decodes as nil context;
malformed limit entries are skipped individually.

### 3. Engine fan-out

`JournalSyncEngine` gains `sessionStatus(convoID:) -> AsyncStream<SessionStatusUpdate>`
mirroring `activities(convoID:)` — same continuation bookkeeping, same
per-convo filtering. The journal replays the cached status when the client
sends `viewing`, which the engine already does on convo open — but that
replay and the stream's continuation registration run in separate tasks, so
a replay frame arriving in the registration gap would otherwise be dropped.
The engine closes that race itself: it caches the last `SessionStatusUpdate`
per convo (stored before fan-out, since status frames are cumulative and
replaying only the latest is lossless) and yields the cached value to a new
subscriber immediately upon registration, before it can observe live
frames. Registration and the frame loop are both actor-isolated, so the
cache-read + yield happens atomically with respect to incoming frames.

### 4. View-model state + merge

The shared `ChatViewModel` (used by both platforms) holds
`public private(set) var sessionStatus: SessionStatus?` and subscribes to
the stream while the convo is open (via a `TimelineService.sessionStatus()`
passthrough, defaulted to an empty stream so fakes need no changes). Merge
semantics per the protocol's "absent means unchanged": each of `model` /
`context` / `limits` replaces the held value only when present in the
incoming frame — `SessionStatus.apply(_:)` (§2) owns that merge and
unit-tests in isolation.

Status can't bleed across convos: the view model is per-room and cached by
room ID, so held status always belongs to its own conversation.

### 5. `UsageMetersView` (DesignSystem)

New `MatronShared/Sources/DesignSystem/UsageMetersView.swift` with two
public pieces so Mac can split them across the header:

- **`ContextGaugeLabel(context:)`** — `Context: 265k/1m` (secondary
  foreground, caption font). Token counts compact-formatted: `< 1000` →
  raw, `< 1m` → `265k` (rounded), else `1m` / `1.5m`. Window `1_000_000` →
  `1m`, `200_000` → `200k`.
- **`UsageBarsView(limits:scale:fixedNow:)`** — one row per limit (max
  three shown, in server order): trailing-aligned label, a capsule track,
  fill proportional to `percent`, and the reset text on the right. A
  `Scale` parameter picks the form: `.compact` (Mac header — 9pt text,
  90pt/3pt bars) or `.regular` (iOS sheet — caption text, 160pt/6pt bars).
  `fixedNow` freezes the clock for deterministic snapshots.
- **Bar colors** match the bridge's thresholds: green `< 50`, orange
  `< 80`, red `>= 80` (system `.green`/`.orange`/`.red` — no new palette
  entries).
- **Label mapping** (pure helper, unit-tested): `"Session"` → `Session`,
  `"Week (all models)"` → `Week`, any other label ending in a
  parenthesized name → that inner name (`"Week (Fable)"` → `Fable`);
  anything else passes through verbatim. Future model renames just work.
- **Reset formatting** (pure helper `resetDisplay(limit:now:)`,
  unit-tested): with `resetsAt`, interval `< 60s` → `now`; `< 1h` → `45m`;
  `< 6h` → `3h20` (hours + zero-trimmed minutes); otherwise local-time
  `EEE h a` lowercased → `Fri 12pm` (same-week resets; year+ away is not a
  real case). Without `resetsAt`, the raw `resets` string verbatim.
  `now` injected for tests. The view refreshes the countdown on a
  1-minute `TimelineView(.periodic)` so `3h20` doesn't go stale between
  status frames.
- **Accessibility:** each bar row is one element, label e.g.
  "Session, 39 percent used, resets in 3 hours 20 minutes"; the context
  gauge reads "Context: 265 thousand of 1 million tokens".

Empty states: nil context hides the gauge; nil/empty limits hides the bars
(Mac header simply shows the title alone until the first status frame).

### 6. Mac header integration

`MacChatToolbar` (MacChatView.swift) changes signature: drop
`onShowBotProfile`, take `status: SessionStatusMerged?`. Layout:
`ContextGaugeLabel` — spacer — title (unchanged, centered) — spacer —
`UsageBarsView`, caption text so three bars fit the existing header height
(bump the header a few points only if squeezed). The ⓘ button is deleted;
`MacBotProfileSheet.swift` is deleted; the `.matronCommand`/state plumbed
for it is removed. New-chat creation is unaffected —
`MacChatListView.swift:120` keeps its own button.

### 7. iOS ⓘ sheet

`ChatView`'s `topBarTrailing` ⓘ button now presents a new
`SessionStatusSheet` (Matron/Features/Chat/): a compact sheet
(`presentationDetents([.medium])`) titled "Session", containing
`ContextGaugeLabel` + `UsageBarsView` at full width, plus the model name as
a footnote when known. No status yet → "No usage data yet — appears after
the next reply." placeholder. `BotProfileView.swift` and its
`onShowBotProfile` plumbing are deleted; `ChatListView.swift:97` keeps
new-chat.

### 8. Tests

- **Bridge:** `parseResetsAt` cases above + `parseUsageLimits` emits
  `resets_at`.
- **Apps (SPM):** decode tests (full frame, partial frame, malformed
  `resets_at`, non-status ephemeral untouched), engine fan-out test
  (mirrors the activities test), `SessionStatusMerged.apply` merge cases,
  label-mapping and reset-formatting table tests, token compact-format
  tests, snapshot tests for `UsageMetersView` (green/orange/red bars,
  raw-string fallback, long label) and `SessionStatusSheet` empty state.
- Full SPM suite + both app builds; manual check on the installed Mac
  build that a live turn populates the header.

## Out of scope

- Status in the chat *list* rows (per-convo header only).
- Rendering the model name on Mac (iOS sheet footnote only).
- Journal server changes (none needed — `status` op already shipped).
- matron-web.
