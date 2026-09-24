# Coordinator redesign: a delegating assistant beside everything — design

**Date:** 2026-09-23 · **Requested by:** Dan (2026-09-23: "make the
coordinator more separate from the rest … clear instructions that it is a
coordinator and should never do work itself … perhaps it shouldn't have
its own task list … see it alongside other conversations like an
assistant"). Decisions in tracker #2719 (panel, option A) and #2750
(unassigned missions, own step list, Opus default).

Sub-project 3 of the move away from conversation-as-the-main-interface
(spec `2026-09-09-app-shell-tabs-design.md`: 1 = app shell, 2 = missions,
3 = Coordinator). Three repos: journal, bridge, apps.

## Problem

The Coordinator is today one conversation the apps put behind a tab / nav
entry. Nothing else knows about it:

- The choice lives in each device's `UserDefaults`
  (`coordinator.convoID.<userID>`), so the phone and the Mac can disagree
  and the bridge and journal cannot tell which conversation it is.
- Its agent runs with the same instructions as every session, so it does
  the work itself instead of handing it out.
- It owns a task list like any chat, which pulls it further into doing
  work.
- It replaces whatever you were looking at: opening it leaves the chat,
  mission or decision you were on.

## Goal

1. **One Coordinator per user, stored on the journal**, read by every
   device and by the bridge.
2. **It coordinates and never does the work.** Its session gets a
   coordinator instruction block, cannot edit files, and hands work out
   as missions to other agents.
3. **Missions are what it hands out.** It can create a mission without
   joining it (*unassigned*), and start a session that is joined to that
   mission from its first turn.
4. **A short list of its own steps.** It keeps its own tasks only for
   coordination steps; anything that is work becomes a mission.
5. **Always to hand.** Mac: a right-hand panel you open from anywhere
   that stays as you move between chats, Missions and Decisions. iPhone: a
   button that slides it up over the current screen. The Coordinator tab
   and nav entry go away.
6. **Defaults to Opus with the 1M context** (`opus[1m]`), so it runs out
   of room less often.

## Non-goals

- Telling the Coordinator what you are currently looking at. Worth doing
  once the panel exists; a later spec.
- Memory, scheduled compaction and rules (named for sub-project 3 in the
  app-shell spec). Deferred; nothing here blocks them.
- Android. It keeps its current behaviour; the journal changes are
  additive so it keeps working unchanged.
- More than one Coordinator per user.

## 1. Journal

### 1a. Coordinator setting

New table `user_settings (user_id TEXT PRIMARY KEY, coordinator_convo_id
TEXT NULL, updated_at INTEGER)`. A table rather than a `users` column so
later per-user settings have a home.

- `GET /coordinator` (user or agent token) → `{convo_id: string|null}`.
- `PUT /coordinator {convo_id: string|null}` (user token only). The convo
  must be owned by the user; `null` clears. Idempotent.
- On a change, the journal appends a `coordinator` event into the
  conversation that gained the role (`{role: "assigned"}`) and the one
  that lost it (`{role: "released"}`), through the normal
  `appendAndBroadcast` path, so the owning bridge and every open app hear
  it live. The apps render it as a one-line marker ("This chat is now the
  Coordinator").
- Snapshot/ws hello carries `coordinator_convo_id` so an app knows it on
  connect without a separate fetch.

### 1b. Unassigned missions

`createMission` gains `attach` (default `true`, today's behaviour). With
`attach: false` the mission is created with `origin_convo_id` set (for
provenance) but the creating conversation's `mission_id` is not touched
and none of its items move. `POST /missions/create` accepts
`attach: false`.

A mission is **unassigned** while it is open and has no member
conversations. The list and detail routes already return the
`conversations` count, so no new state column: "unassigned" is derived.

### 1c. Spawning onto a mission

`agent_spawn_requests` gains `mission_num INTEGER NULL`. When a spawn with
a mission starts and its conversation is minted, the journal runs
`joinMission` for it before the first turn, so the new session is on the
mission from the start (instead of relying on it obeying "run
mission_join #N"). A closed or missing mission fails the spawn request
with a visible reason rather than starting an unattached session.

## 2. Bridge

### 2a. Knowing it is the Coordinator

- At every Claude/Codex spawn and resume, the bridge asks the journal
  `GET /coordinator` (cached per box, refreshed on the `coordinator`
  event) and, for the matching room, appends `BRIDGE_COORDINATOR.md` to
  the system prompt (`--append-system-prompt` at both Claude spawn sites;
  `developerInstructions` for Codex).
- On a live `coordinator` event for a running session, the input router
  (which today drops non-`user:` senders) accepts this event type and
  injects a turn: *"[coordinator] You are now this user's Coordinator …"*
  with the same block, or *"… no longer the Coordinator; you are an
  ordinary session"* on release. The next spawn/resume picks up the
  system-prompt form.

### 2b. Instructions (`BRIDGE_COORDINATOR.md`)

The block says, in short:

- You are the user's Coordinator. You never do the work yourself: no
  editing files, no builds, no investigations beyond a quick look to
  route work well.
- Turn requests into missions (`mission_create`), one per independent
  piece of work, with the goal in the body and its tasks filed into it.
- Assign a mission by starting a session on a suitable box
  (`agent_boxes` → `agent_session_start` with `mission`), or by asking a
  running agent in its chat room to `mission_join`.
- Keep your own tasks only for coordination steps ("check back on #N",
  "tell the user when all three are done"). Work is never your task.
- Questions for the user go in the tracker as usual; they reach the user
  through Decisions.
- Read the state of the world with `mission_get`, `item_list scope:all`
  and journal search, not by opening repos.

### 2c. Enforcement

For the Coordinator's session the bridge adds `--disallowedTools Edit
Write NotebookEdit` (Claude) and the equivalent read-only sandbox for
Codex. `Bash` stays available for journal search and quick look-ups. The
instructions carry the rest; this just makes "never edits files" true by
construction.

### 2d. Tools

- New `mission_create {title, body?}` → `POST /missions/create` with
  `attach: false`; returns the number. `mission_start` is unchanged
  (creates and joins, for ordinary sessions).
- `agent_session_start` gains optional `mission` (number), passed through
  the spawn request (§1c). Its consent card shows "joins mission #N".

### 2e. Model

- "New coordinator chat…" in the apps starts the session with model
  `opus[1m]`.
- Assigning an existing conversation as Coordinator: if the room has no
  model the user picked explicitly, the bridge persists `opus[1m]` for it
  and switches the running session the same way the `/model` command does.
  A model the user picked stays.

## 3. Apps

### 3a. Setting moves to the journal

`CoordinatorSetting` reads and writes the journal (`GET/PUT
/coordinator`, plus the hello field), keeping the `UserDefaults` value only
as an offline cache. First launch after upgrade: if the journal has no
Coordinator and this device has one cached, the app `PUT`s it; a device
that finds the journal already has one adopts it, even if this device
cached a different id. `PUT /coordinator` is last-write-wins on the
journal, not first-device-wins: if two devices race with different
cached ids, the last `PUT` sticks, and every device converges on the
journal's value through the live `assigned` event that `PUT` produces,
or through its own next hello if it missed that event. The chooser
(existing conversations, or *New coordinator chat…* on a chosen box)
stays in Settings and in the panel's empty state.

### 3b. Mac panel

- The window gets a trailing **Coordinator panel**: a `MacChatView` for
  the Coordinator's conversation, outside the per-nav detail so it
  survives moving between Conversations, Missions and Decisions.
- Toggled by a toolbar button in the sidebar section (never under the
  chat header accessory; see `technique_titlebar_accessory_toolbar_clipping`),
  **Go ▸ Coordinator** and **⌘0**. Open/closed and its width persist per
  window.
- Width: resizable, min 320 pt, ideal 380 pt. Below a window width where
  the detail column would drop under its minimum, the panel overlays the
  detail's trailing edge instead of squeezing it.
- The panel keeps its chat's Tasks toggle (its own steps, §Goal 4) and
  sub-chat pane behaviour.
- `MacNav.coordinator` goes. The nav column is Missions, Decisions,
  Conversations; ⌘1/⌘2/⌘3 map to those. History (`MacPlace`) drops its
  `.coordinator` case; the panel's open state is not part of Back/Forward.
- The Coordinator's conversation is left out of the Conversations list. A
  search hit or item link into it opens the panel.

### 3c. iPhone

- The Coordinator tab goes. On the tabs' root screens (Missions,
  Decisions, the Conversations list) a floating Coordinator button sits at
  the bottom trailing corner above the tab bar, with the unread dot the
  tab had.
- Inside a conversation there is no floating button (it would sit over
  the composer). The Coordinator opens from that chat's ⓘ sheet
  (`SessionStatusSheet`, a *Coordinator* row, handed off in `onDismiss`
  like the media browser) and from a Coordinator button at the top of its
  tasks page (Dan, #2757).
- Every entry presents the Coordinator chat as a sheet (detents `.large`
  and `.medium`), swiped away to return to the same screen. Its tasks
  page stays reachable inside the sheet the same way as in any chat. The
  entries are hidden inside the Coordinator's own sheet.
- The conversation is left out of the Conversations list; notification
  taps and links into it open the sheet.

### 3d. Missions list

Open missions with no conversations show in an **Unassigned** section at
the top of Missions (both apps), with who created them ("from
Coordinator"). Everything else about the list is unchanged.

### 3e. Markers

`coordinator` events render as a one-line system marker in the timeline,
like mission markers.

## Rollout order

1. **Journal**: §1a–§1c, all additive. Deploy first.
2. **Bridge**: §2, needs the journal routes. Fleet deploy.
3. **Apps**: §3, needs both. The migration in §3a runs on first launch.

Until the bridge is deployed on a box, a Coordinator there behaves as
today (no block, no enforcement); nothing breaks.

## Testing

- **Journal:** route tests for `/coordinator` (ownership, clear, events
  emitted to both convos), `createMission attach:false` (convo and items
  untouched; counted as unassigned), spawn-with-mission joining before the
  first turn, closed-mission spawn rejection.
- **Bridge:** spawn args include the coordinator block and
  `--disallowedTools` only for the Coordinator room; live assign/release
  inject the right turns; `mission_create` and `agent_session_start
  mission` payloads; model switch respects an explicit user choice.
- **Apps:** setting migration (local only / journal only / both
  different); Mac panel persists across nav changes and Back/Forward,
  title bar stays 52 pt with it open, no toolbar items in `»`; iPhone
  button on every tab root and none inside a chat, ⓘ-sheet and tasks-page entries open the sheet, and it dismisses to the same screen;
  Coordinator excluded from Conversations; Unassigned section.
- **End to end:** give the Coordinator a three-part request; it creates
  three unassigned missions, starts a session on one, and that session's
  conversation appears under the mission.

## Open points for review

- `Bash` stays available to the Coordinator (§2c). Removing it too would
  make "never does the work" stricter but breaks journal search; the
  instructions carry it instead.
- ⌘0 for the panel on Mac.
