# Subagent sub-chats — coordinating design (journal + bridge + apps)

**Date:** 2026-07-15
**Status:** approved by Dan (chat), implementation pending
**Scope:** three repos, dependency-ordered: matron-journal → matron-bridge →
matron-apple. Each repo's PR is independently harmless (see Rollout).

## Problem

When a bridge session spawns subagents, everything they do is flattened into
the parent conversation as `🔀[label]`-prefixed text — and the parent's
context meter gets clobbered by subagent events (see § Meter bug). Rich
subagent identity (agentId, label, agentType, its own event stream, its own
model + token usage) already exists inside the bridge's subagent-watcher but
is dropped before the journal.

## Design decisions (all approved by Dan)

1. **Durable child conversations.** Every subagent becomes a real journal
   conversation linked to its parent via `parent_convo_id`. This reuses the
   entire existing per-conversation machinery — timeline, tool cards, diffs,
   live streaming, status caching, replay — with nothing bespoke to render.
2. **Hidden from the sidebar.** Child conversations never appear in the chat
   list. They are reachable only through the parent: a sticky strip of
   running subagents pinned in the parent chat, and the Task tool card in the
   timeline as the permanent entry once finished.
3. **Output moves entirely.** All subagent text / tool cards / diffs /
   streams flow only into the child conversation. The parent keeps just the
   Task card (label, status, final summary — the Task tool_result already
   carries it) and the sticky strip. No `🔀` inline copies remain.
4. **Read-only viewer.** The sub-chat has the full timeline plus a
   mini-header (name, model, its own context gauge, running/finished state,
   switcher between active subagents) and **no composer**. Mid-run injection
   into a subagent isn't possible in the SDK; a finished one has nothing to
   receive.
5. **iOS navigation**: push the child onto the existing `chatPath`
   NavigationStack — nesting (a subagent's subagent) is just pushing deeper.
6. **Mac layout**: the sub-chat opens as a resizable right-hand pane
   splitting the detail area with the parent chat (min widths, ✕ to close);
   when the window is too narrow it takes over the detail area with a back
   chevron.
7. **Silent children**: no unread badges, no push notifications, no sidebar
   snippet churn from child conversations.
8. **Nesting recurses naturally**: the bridge's watcher already re-triggers
   discovery for nested subagents; a child conversation can itself have
   children.

## Per-repo work

### matron-journal (first)

- Migration: `conversation` gains nullable `parent_convo_id` (indexed).
- `convo_upsert` accepts an optional `parent_convo_id` (set at creation,
  immutable afterwards — later upserts without it must not clear it).
- The field is exposed everywhere conversation metadata already flows: hello
  replay's conversation list and the fanned-out `convo_meta`/`convo_upsert`
  shapes. Event delivery needs **no** change — journal delivery is user-wide
  and events are tagged with their `convo_id`; children ride along.
- Push: child conversations are exempt from APNs and unread counting
  (`parent_convo_id IS NOT NULL` short-circuits the push pipeline and unread
  increments). This enforces decision 7 server-side, and keeps stale app
  versions silent too.
- Ships the column unused: harmless before the bridge sends it.

### matron-bridge (second)

Two PRs:

**PR A — meter guard fix (ship immediately, deployable at next restart).**
`index.js:2498-2499` captures `modelFromEvent(event)` into
`session.currentModel` with no `parent_tool_use_id`/`isSidechain` guard, so a
subagent's assistant event clobbers the parent's model label — and since the
context window is derived from the model (`contextWindowFor`), the gauge pct
corrupts too. The token capture 40 lines down (`session-status.js:48-52`) IS
guarded; apply the same guard to model capture. This is Dan's original
observation and stands alone.

**PR B — child conversation publishing.**
- On subagent discovery (`notifyTaskStarted` → watcher), publish a
  `convo_upsert` for a child conversation: stable id derived from the parent
  convo id + the watcher's agentId; `title` from the sidecar meta (label,
  falling back to agentType); `parent_convo_id` = parent's convo id;
  `session_state` running. Include the spawning Task call's `tool_use_id` as
  `task_ref` inside `session_state` so apps can link the Task card to the
  child (when the watcher can't associate one, apps still reach the child
  via the strip).
- Route subagent events to the child convo id instead of prefixing into the
  parent: text (drop the `🔀[label]` path), tool_output, diff, streams.
- Publish per-subagent `status` (its own model + context tokens from its own
  events) on the child convo — the existing per-convo status cache does the
  rest.
- On subagent completion (Task tool_result observed / transcript closes),
  set the child's `session_state` to finished.
- Nested subagents recurse with the child as parent.

### matron-apple (third)

- Store: `conversation.parent_convo_id` column (GRDB migration);
  `ChatSummary.parentConvoID`; chat-list queries filter
  `parent_convo_id IS NULL`; a `children(of:)` query for the strip/switcher.
- Wire: `convo_upsert`/`convo_meta` decode gains `parent_convo_id` and
  `task_ref`.
- Parent chat: sticky strip of running children (name + spinner, tap to
  open); Task tool cards whose `tool_use_id` matches a child's `task_ref`
  become tappable entries (chevron affordance).
- Sub-chat screen: the existing chat timeline reused read-only (no composer),
  with a mini-header — title, model, own context gauge (`ContextGaugeLabel`),
  running/finished state, and a menu to switch among the parent's active
  children.
- Navigation: iOS `chatPath.append(childID)`; Mac split detail pane with the
  narrow-window take-over fallback.
- Child conversations produce no unread badges and no local notification
  surfaces (defense in depth alongside the server rule).

## Meter bug (context for reviewers)

Dan observed the top-of-chat meter showing the subagent's model/context while
a subagent runs. Root cause confirmed: unguarded model capture (bridge
`index.js:2498`), inconsistent with the guarded token capture. Fixed by
bridge PR A regardless of the rest of this design.

## Rollout

1. Journal PR: column + pass-through + push/unread exemption. Deployable
   any time (Dan deploys chat.yearbooks.be).
2. Bridge PR A (guard fix), then PR B (child publishing). Both take effect at
   the next deliberate bridge restart.
3. Apps PR: schema + strip + Task-card link + sub-chat viewer + navigation.
   Renders whatever exists; older bridges simply never create children.

## Testing

- Journal: upsert with/without `parent_convo_id`; immutability (later upsert
  won't clear it); list/replay shapes carry it; push + unread short-circuit
  for children; `:memory:` DB + real WS pairs per repo idiom.
- Bridge: watcher → child convo_upsert with title/parent/task_ref; event
  routing (no `🔀` prefix remains); per-subagent status isolation (parent
  model never clobbered — regression test for PR A); finished-state publish;
  nested recursion. `node:test` per repo idiom.
- Apps: migration; list filtering; strip presence/ordering; card link by
  `task_ref`; read-only viewer (no composer); per-child status stream keyed
  by child convo id (already routed by convoID — regression only); snapshot
  tests for strip, mini-header, Mac pane, iOS push.
