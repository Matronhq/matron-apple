# Conversation Summaries TOC — design

**Date:** 2026-08-09
**Repos touched:** matron-bridge, matron-journal, matron-apple (iOS + Mac)
**Deploy order:** journal (dev-2) → bridge (needs `OPENAI_API_KEY`) → apps

## Problem

The bridge already generates rolling conversation summaries (`maybeUpdatePinnedSummary`,
every 5 recorded text messages, via `gemini-3-flash-preview`), but:

- The cumulative bullet summary lives only in the bridge's session persistence
  (`pinnedSummaryText`) and is destructively compacted past 15 bullets — history is lost
  and the apps never see it.
- Only the title and the "roster" paragraph reach the journal (as `convo_upsert`
  metadata, latest-wins — no history).
- Nothing ties a summary to a position in the conversation, so there's no way to
  navigate back to "when that happened".
- The trigger runs on every assistant flush, so passes fire mid-turn — a bad anchor
  point for navigation.
- The model is hardcoded; Gemini 3 Flash Preview ($0.50/$3.00 per M tokens) is now
  ~2.5× the price of GPT-5.6 Luna ($0.20/$1.20 after OpenAI's 2026-07-30 cut).

## Goal

Every summary pass becomes a persistent, anchored **TOC entry**. Tapping the
conversation title in either app opens a panel listing all entries for that
conversation — collapsed row = one-line "what just happened", expand = the fuller
rolling paragraph, tap = navigate to that point in the transcript.

## Non-goals

- No backfill for conversations that predate the feature (they accrue entries from
  deploy onward; the panel shows an empty state until then).
- No change to the pinned cumulative summary, its >15-bullet compaction, or the
  roster `convo_upsert` — those keep working exactly as today.
- No per-device summarization; generation stays on the bridge.

## Design

### Approach (decided)

Summaries ride the existing journal event stream as a new first-class kind,
`summary` — like `text`/`diff`/`file`. The event's own journal `seq` **is** the
anchor: it lands in the stream at the moment the pass ran, so "navigate to this
entry" = "scroll to the messages just before this seq". Apps receive entries through
the existing sync/replay/catch-up machinery (offline catch-up included), store them
in a local table, and exclude the kind from transcript rendering.

Rejected: a separate journal summary table + fetch endpoint (new sync path, new
catch-up logic, and an invented anchor field for the same result); app-side
summarization (keys and firehose live on the bridge; would bill once per device).

### Bridge (matron-bridge)

1. **Trigger moves to turn end.** Remove the `maybeUpdatePinnedSummary` call from
   `flushResponse`; call it where the turn-finish transition is handled instead.
   Gate: `chatHistory.length - (session._lastSummaryMsgCount || 0) >= 5`. On a
   successful pass, set `_lastSummaryMsgCount = chatHistory.length` and persist it
   with the session (survives bridge restarts; prevents double-fire on resume).
   Counting semantics are unchanged: only user/assistant *text* bubbles count
   (interim narration included, tool calls excluded).
2. **Publish a TOC event per pass.** New publisher method
   `publishSummary(convoId, payload)` → journal frame kind `summary`, payload:
   - `toc` — the incremental one-liner: `NEW:` when a cumulative summary exists,
     `SUMMARY:` on the first pass (collapsed row text).
   - `detail` — the `ROSTER:` paragraph (expanded row text).
   - `model` — the model id that produced it (debuggability).
   Published only when the pass parsed a usable `toc`; a failed/unparsable pass
   publishes nothing (same silent-skip contract as today's title path, same
   `console.warn`).
3. **Provider-configurable model.** New `lib/summary-model.js` exposing
   `generateSummary(prompt) -> string`:
   - If `OPENAI_API_KEY` is set → OpenAI chat completions via plain `fetch` (no new
     dependency), model from `SUMMARY_MODEL` (default `gpt-5.6-luna`).
   - Else if `GEMINI_API_KEY` is set → existing Gemini client (model from
     `SUMMARY_MODEL`, default `gemini-3-flash-preview`).
   - Else → summarization off (title fallback naming still runs, as today).
   `maybeUpdatePinnedSummary` calls this instead of `genAI` directly; prompt text,
   parsing (`parseTitlePassResponse`), and the ROSTER-must-be-last constraint are
   unchanged. `.env.example` and README document the new envs.

### Journal (matron-journal)

1. Add `'summary'` to `MESSAGE_TYPES`.
2. **Silence, everywhere except the stream:** `summary` events must not
   - update the conversation's chat-list snippet (`snippetOf` returns null / callers
     skip snippet update for this kind),
   - increment unread counts or badges,
   - trigger push notifications (`push.js` classify ignores the kind).
   They do fan out live over WS like any event, so an open app gets TOC entries in
   real time.
3. **Retention:** summary events follow the same retention policy as ordinary
   messages — no special pinning. If a TOC entry outlives the messages around it,
   navigation degrades gracefully (see Apps).
4. Older apps must tolerate the new kind. Verify the apps' event decoder skips
   unknown kinds (believed true — confirm during implementation); if not, journal
   deploy waits for the app release instead of preceding it.

### Apps (matron-apple, both platforms)

1. **Storage:** new GRDB table `summary_entries`
   (`convo_id`, `seq` PK-with-convo, `toc`, `detail`, `created_at`), populated from
   both live events and replay/catch-up. `summary` events are excluded from the
   message transcript store/rendering.
2. **Panel:** tapping the conversation title (iOS: navigation-bar title button →
   sheet; Mac: clickable title in the header → popover) shows entries
   newest-first. Row: `toc` line, disclosure to expand `detail`. Empty state:
   "No summaries yet — they appear as the conversation grows."
3. **Navigation:** tapping a row dismisses the panel and scrolls the transcript to
   the nearest message with `seq <= entry.seq`, reusing the existing
   jump-to-message machinery (search navigation path). If the target is outside the
   loaded window, load around that seq first; if the region was pruned by
   retention, land on the oldest available message.

### Cost note

A pass sends ≤50 messages (~10–25k input tokens worst case) and returns ~150
tokens. At Luna prices that's well under a cent per pass; the switch is for
direction-of-travel, not material savings.

## Error handling

- Bridge pass failure (network, parse): `console.warn`, no retry, no event — next
  qualifying turn end tries again. `_lastSummaryMsgCount` is only advanced on
  success, so a failed pass doesn't swallow its window.
- Journal rejecting the kind (stale journal deploy): bridge publish path already
  tolerates journal errors (fail-open publisher); deploy order avoids it.
- App receiving `summary` for an unknown conversation: same drop-or-create rules as
  any other event kind (follow existing convo upsert-on-event behavior).

## Testing

- **Bridge:** unit tests for the turn-end gate (threshold, persistence of
  `_lastSummaryMsgCount`, no mid-turn fire), provider selection (OpenAI present /
  Gemini only / neither), and the published payload shape.
- **Journal:** kind accepted and fanned out; no snippet change, no unread
  increment, no push for `summary` events.
- **Apps:** decoder → `summary_entries` row (live + replay); transcript excludes the
  kind; panel renders collapsed/expanded states (snapshot tests, Mac layout pinned
  like existing panels); navigation scrolls to the right message including the
  outside-loaded-window case.
- **End-to-end (manual):** real conversation on the deployed stack — entries appear
  after turns, panel navigates, no pushes/badges from summary traffic.
