# Missions dashboard — design

Date: 2026-09-28. Status: design approved by Dan (tracker questions on
scope, liveness, Coordinator status and the v2 design); spec awaiting review.

## Why

Dan never opens the Missions page: it is a static list of titles and
last-milestone lines. What he does instead is ask the Coordinator "what's
the current status of everything?" and read its roll-up. The page should
be that answer, always current: a dashboard of everything being worked
on, the latest step on each, and anything that needs him — with the
Coordinator keeping a written status on every mission.

## Decisions already made

| Question | Answer |
|---|---|
| What counts as "everything" | Missions, plus a "Not on a mission" group of loose running sessions (B) |
| Where "what's happening now" comes from | The roster summary per session (`GET /roster`), polled while the page shows; latest TOC summary heading as fallback (B) |
| How the Coordinator's roll-up feeds the page | A status paragraph on every mission, kept current by agents, plus an "Ask the Coordinator to update" button (A) |
| Out of scope | Live thinking/tool activity per session; colleagues' shared missions; editing the status in the apps; scheduled automatic refresh |

## Overview

Three repos, shipped in order:

1. **matron-journal** — missions gain a `status` (text + who + when),
   settable with `PATCH /missions/:id`, returned everywhere a mission is.
2. **matron-bridge** — a `mission_status` tool, and instructions telling
   agents when to use it and the Coordinator how to refresh all of them.
3. **matron-apple** — the Missions list is replaced by the dashboard on
   iOS (Missions tab root) and Mac (Missions nav entry, full width).

Each ships independently: an app against an old journal shows no status
lines; an old bridge simply never writes one.

## 1. Journal: mission status

### Schema

`missions` gains four nullable columns (migration, no backfill):

| Column | Type | Meaning |
|---|---|---|
| `status` | TEXT | Markdown, 1–600 chars after trimming (UTF-16 length, as other limits) |
| `status_by` | TEXT | `'user'` or `'agent'` — the caller's device kind |
| `status_convo_id` | TEXT | The writing agent's conversation (null for a client write) |
| `status_updated_at` | INTEGER | ms epoch |

### Routes

- `PATCH /missions/:id` accepts `status?: string | null` beside `title?`
  and `body?`.
  - A string sets the four columns. Trimmed; empty after trimming or over
    600 → 400 `bad_request`. Control characters other than `\n`/`\t`
    rejected as for item titles.
  - `null` clears all four.
  - `status_convo_id` comes from an optional `convo_id` in the body, only
    honoured for agent callers and only if the conversation belongs to
    the caller's user; otherwise null.
  - A closed mission → 409 `{blocked_by:'closed'}` (unchanged rule).
  - Visibility rules are those of the existing PATCH: an ordinary agent
    can set the status of any mission it can see; a mission it can't see
    is 404.
  - A status-only PATCH still bumps `updated_at` and appends the existing
    `mission` marker with `action: 'updated'` to the origin conversation,
    so every client refetches. The marker payload gains
    `status_changed: true` when the status changed (clients may ignore it).
- `GET /missions`, `GET /missions/:id`, and the `mission` object in every
  other response carry `status`, `status_by`, `status_convo_id` and
  `status_updated_at` (null when unset).
- **Privacy sieve:** a status written from a private-owned conversation
  is withheld from ordinary agents exactly as milestone bodies are
  (fields returned as null). Clients always see it.

### Docs and tests

`docs/protocol.md` (Missions → Routes, Marker events) and `src/help.js`
updated. Route tests: set, overwrite, clear, trim, 600 limit, control
characters, closed mission, agent vs client `status_by`, `convo_id`
ownership, marker appended with `status_changed`, sieve for a private
writer, GET list and detail carry the fields.

## 2. Bridge: `mission_status` tool

### Tool

```
mission_status({ status: string, mission?: number })
```

- Sets the status of this conversation's mission, or of mission `#N`
  when `mission` is given (the Coordinator refreshes missions it is not
  on). Calls `PATCH /missions/:id {status, convo_id}` with the current
  conversation as `convo_id`.
- Description (what the agent reads): "Set the mission's status — one
  short paragraph (≤600 chars) saying where the work is, what's next,
  and anything blocked or waiting on the user. It is the headline on the
  mission's card in the apps, so write it for the user at a glance, not as a
  log. Replace it whenever that picture changes: after a progress
  milestone, when you get blocked, when you hand off. Pass `mission` only
  to set another mission's status (the Coordinator does this)."
- Errors surface as today's mission tools do (`mission_status failed:
  …`); a conversation with no mission and no `mission` argument gets the
  same "start or join a mission first" instruction milestone_post gives.

### Instructions

- `BRIDGE_CLAUDE.md` / `BRIDGE_CODEX.md` missions section: after a
  `progress` milestone, or on becoming blocked or handing off, call
  `mission_status` with the new picture. Keep it current rather than
  frequent: one status, overwritten, not a second milestone log.
- Coordinator instructions: when asked to refresh mission statuses (the
  apps send a fixed message, §3.4), `mission_get` each open mission and
  `mission_status` it from its latest milestones, conversations and open
  items. Missions whose status is newer than their last milestone and
  whose sessions are idle may be skipped. Reply in the chat with one line
  per mission changed.

### Tests

Tool wiring test (`test/missions-wiring.test.js` pattern): own mission,
explicit `mission`, no-mission error, PATCH body carries `convo_id`.

## 3. Apps: the dashboard

### 3.1 Placement

- **iOS:** replaces `MissionsListView` as the Missions tab root
  (`MissionsTabRoot`). The Memories toolbar button stays. Tapping a card
  pushes the existing mission page; tapping a session pushes/opens its
  chat as mission-page conversation rows do today; tapping a needs-you
  row opens the item.
- **Mac:** the Missions nav entry shows the dashboard full width in the
  detail area instead of the list column + page. Opening a mission shows
  the existing `MacMissionPage` with Back returning to the dashboard
  (a `MacPlace` entry, so Back/Forward history records it).
- **Closed missions:** a collapsed "Closed (n)" section at the bottom
  with today's compact rows.
- **Unassigned missions** (open, no conversations) render as mission
  cards with no sessions and their attribution line ("from Coordinator").

### 3.2 Mission card

Top to bottom:

1. **Header:** `#num` · title (2 lines) · red "Needs you · n" pill when
   `needsYou > 0`.
2. **Status** (when set): markdown, up to 4 lines, then "Updated 12m ago
   by an agent / by you". When unset, nothing — no placeholder text.
3. **Latest step:** kind glyph, milestone title, relative age, one line
   of its body. "No milestones yet" when none.
4. **Needs you:** up to three open items awaiting the user (questions and
   consent asks), each a tappable row with the item's title; then "+n
   more" opening the mission page.
5. **Sessions:** one row per conversation on the mission: box tag, title,
   state dot (running green / waiting amber / done grey), then two lines
   of summary text (§3.5). Sessions sorted running → waiting → done, then
   by last activity. More than four → "+n more sessions".

Card width: full width on iPhone; on iPad and Mac an adaptive grid of
cards, minimum 340 pt wide (2–3 columns typical).

### 3.3 Loose sessions

Section "Not on a mission", below the mission cards. Members: top-level
conversations (no `parentConvoID`) that are not on any mission, are not
the Coordinator, and are either `running`, or `waiting` with last
activity in the last 24 h. Compact cards: box tag, title, state dot,
two-line summary, needs-you count badge. Tap opens the chat. Hidden when
empty.

### 3.4 "Ask the Coordinator to update"

A button in the page header (iOS toolbar; Mac page header). Sends the
Coordinator conversation this exact text through the normal send path
(the offline outbox, so it survives a flaky connection):

> Refresh the status of every open mission from its latest milestones,
> sessions and open items.

Then shows "Asked just now" (relative, from the send time, kept in the
view model for the session) until a status update arrives. Hidden when
the app has no Coordinator conversation. Cards change as the
Coordinator's `mission_status` calls land (mission markers → refetch).

### 3.5 Session summary text

For each session shown: the roster `summary` if non-empty; else the
newest `SummaryEntryRecord.toc` for that conversation; else the chat
snippet (last message line); else nothing.

### 3.6 Ordering

Mission cards: (1) `needsYou > 0`, (2) any session running, (3) the
rest; within each, most recent activity first — the max of last
milestone time, status time and its sessions' last activity. Loose
session cards: running first, then last activity.

### 3.7 Data and liveness

New `MissionsDashboardViewModel` (MatronShared/ViewModels), replacing
`MissionsListViewModel` on the dashboard (the list VM stays for the nav
badge's `needsYouTotal` until the dashboard VM provides it; then remove
the old VM).

Inputs:

- `store.missionsStream(state: nil)` — missions incl. status (existing
  sync; `Mission` gains `status`, `statusBy`, `statusUpdatedAt`, decoded
  leniently; `JournalStore+Missions` migration adds the columns).
- Per open mission: `missionConversationsStream` and open items. On page
  appear the VM asks `MissionsSync` to refresh the detail of every open
  mission, at most four requests in flight. Mission/milestone markers
  already trigger per-mission refetch.
- **Fix:** item markers (`item` events) whose item has a `mission_id`
  also trigger that mission's refetch, so `needs_you`/`open_items` stay
  current (today they go stale until reconnect).
- Session state, last activity, snippet, needs-you per chat: the existing
  chat summaries and `sessionState` streams in the store.
- Summaries: new `JournalAPI.roster()` → `[convoID: summary]` (only the
  fields used are decoded). Fetched on start, every 60 s while started,
  and on refresh. `stop()` (page disappears) cancels the timer. A failed
  fetch keeps the last good map and is not shown as an error.
- The Coordinator conversation id comes from the same source the
  Coordinator page uses.

Everything else about loading/error states follows `MissionsListView`:
retry banner when the mission list fails, pull-to-refresh on iOS, a
refresh button on Mac.

### 3.8 Tests

- **VM (shared):** grouping (mission / loose / closed / unassigned),
  ordering rules, loose-session membership (parent, Coordinator, 24 h
  waiting window), summary fallback chain, roster poll starts/stops with
  the page and keeps the last map on failure, detail refresh fan-out
  capped at four, item marker → mission refetch, "Asked" state.
- **Model:** `Mission` decodes status fields and tolerates their absence.
- **Snapshots (shared DesignSystem):** mission card with status + needs
  you + sessions; card without status; unassigned card; loose-session
  card; empty dashboard; grid at iPad/Mac widths — light and dark.
- **Navigation (iOS + Mac):** card → mission page; session → chat; item
  row → item; Mac Back returns to the dashboard; Coordinator button sends
  the exact message to the Coordinator conversation.

## Rollout

1. Journal PR → deploy to services-1.
2. Bridge PR → fleet deploy.
3. Apple PR(s): shared model + VM + views, then iOS and Mac hosts. May be
   split into a shared-layer PR and a hosts PR.

Until 2 is deployed, statuses only appear once an agent is on an updated
bridge; the dashboard is still useful without them.
