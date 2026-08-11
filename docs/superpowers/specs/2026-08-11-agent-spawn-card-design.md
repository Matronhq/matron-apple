# Agent-spawn consent card — design (matron-apple)

**Date:** 2026-08-11
**Status:** approved (Dan, 2026-08-11 — campaign design approved in session; this doc is the apple slice)
**Depends on:** matron-journal PR #62 (`spawn_outcome` events; spec `2026-08-11-spawn-outcome-events-design.md` in that repo) and the merged agent-spawn protocol (protocol.md "Agent-spawned sessions").

## Goal

Render the journal's `agent_spawn` consent card on iPhone and Mac, answer via
`POST /agent-spawn/answer`, and derive resolved state from the journaled
`spawn_outcome` event — restart-proof and cross-device consistent, with an
"Open" affordance into the spawned room on `started`.

## Wire contract

- **Card:** `permission_request` event, payload `{kind:'agent_spawn',
  request_id, from_device_id, from_name, from_convo_id, from_convo_title,
  target_device_id, target_name, workdir, task, topic?}` (strings
  server-sanitised; empty `topic`/titles → treat as nil).
- **Resolution:** `spawn_outcome` event in the same conversation, payload
  `{request_id, outcome:'started'|'declined'|'expired'|'failed', room_id?
  (started), child_convo_id? (started), error_code? (failed)}`.
- **Answer:** `POST /agent-spawn/answer` body EXACTLY `{request_id,
  decision:'approve'|'deny'}` → 200; 409 = resolved elsewhere/expired; 404 =
  gone; any `always_allow` key = 400 (never send one).

## Design

Mirror the agent-chat card stack end to end, with ONE deliberate divergence:
**no UserDefaults answered-state** — resolution is derived from
`spawn_outcome` events in the timeline (the whole point of the journal-side
work). State precedence in `ChatViewModel.agentSpawnState(_:request:)`:
derived outcome wins → transient in-flight (`.sending`, in-memory only) →
`.idle` when an answerer is wired, else read-only resolved rendering.

- **MatronEvents:** `AgentSpawnRequest` (parse gate: `kind == "agent_spawn"`
  + string `request_id` + non-empty `task`; unanswerable → nil → generic
  permission rendering, same rule as `AgentChatRequest.parse`) with the
  label helpers the card needs (`headline` = topic ?? first line of task,
  requester/target labels mirroring agent-chat's); `SpawnOutcome` (parse +
  `displayLine`: `🚀 Spawned session started` / `🚫 Spawn declined` /
  `⌛ Spawn request expired` / `❌ Spawn failed` (+" — code") / unknown →
  `Spawn request resolved`); `AgentSpawnCardState` enum
  (`idle | sending | resolved(SpawnOutcome) | failed(String)`).
- **MatronChat:** `TimelineItem` cases `agentSpawnRequest(eventID:_:)` and
  `spawnOutcomeRow(eventID:_:)` (eventID = seq string); mapper's
  `permissionRequest` branch tries `AgentChatRequest.parse` first
  (unchanged), then `AgentSpawnRequest.parse`, else the generic `.askUser`
  fallback; new `spawn_outcome` event type maps to `spawnOutcomeRow`
  (parse-fail → existing unknown handling). `JournalStore` snippet mapping
  mirrors the server: ask → `🤝 Agent spawn request`, outcomes → the
  `displayLine` strings.
- **MatronJournal:** `JournalAPI.answerAgentSpawn(requestID:decision:)`
  (body exactly two keys; 409→`.conflict`, 404→`.notFound` via the existing
  status mapping); protocol slice `AgentSpawnAnswering` beside
  `AgentChatAnswering`.
- **MatronViewModels:** `ChatViewModel` — `spawnOutcomes` derived from the
  mapped items; `answerAgentSpawn` guards re-answer/double-send, `.conflict`
  → synthetic resolved (`expired`-style copy "This request is no longer
  waiting for an answer."), `.notFound` → `.failed("That request is no
  longer on the server.")`, transport → `.failed(...)` still answerable,
  `CancellationError` → drop transient and rethrow. No persistence writes.
- **MatronDesignSystem:** `AgentSpawnRequestCard` (values + closures only,
  snapshot-friendly) mirroring `AgentChatRequestCard`: header, headline,
  Detail rows From/Target/Folder, the task verbatim in a monospaced block,
  Decline (`.bordered`) + Approve (`.borderedProminent`) + spinner;
  `.resolved` renders icon + copy and, for `started`, an "Open" button
  calling `onOpen(roomID)`.
- **App targets (iOS + Mac):** `TimelineItemView` / `MacTimelineItemView`
  dispatch both cases with injected `agentSpawnState` / `onAnswerAgentSpawn`
  / `onOpenSpawnRoom` closures (nil state resolver → read-only, exactly the
  agent-chat convention); `spawnOutcomeRow` renders its `displayLine` as a
  modest status row with Open on started. "Open" navigates to `room_id`
  using the sub-chat navigation precedent (`NavigationLink(value:)` on iOS,
  `onOpenSubChat`-style callback on Mac), after
  `AppDependencies.prepareConversation(for:id:)` so navigation holds if the
  room's first journal frame hasn't landed.

## Error handling

Per the state machine above; unknown outcome strings render neutrally and
never crash; a card in a read-only context shows no buttons.

## Testing

All logic in MatronShared so CI job 1 (`swift test`) gates it fast:
`EventsTests/AgentSpawnRequestTests` + `SpawnOutcomeTests` (payload literals
copied from the wire contract), mapper dispatch + fallback tests,
`ChatViewModelAgentSpawnTests` mirroring the agent-chat suite (derived
resolution replaces persistence — including a "new VM for the same room still
resolves WITHOUT UserDefaults" contrast), `JournalAPITests` body-key
invariant, `JournalStoreTests` snippets. App targets: extend the
`shouldRender` binding tests. This dev box has no Swift toolchain — CI
(macos-15) is the only gate; keep the app-target surface minimal.

## Out of scope

Push-notification copy for spawn outcomes (journal sends no push);
agent-chat card changes; snapshot tests for the new card (repo has none for
`AgentChatRequestCard` either — parity, not regression).
