# Conversation Summaries TOC — design

**Date:** 2026-08-09
**Repos touched:** matron-bridge, matron-journal, matron-apple (iOS + Mac)
**Deploy order:** journal (dev-2) → apps → bridge (needs `OPENAI_API_KEY`).
Apps must precede the bridge: current apps render unknown event kinds visibly
(`[unsupported event: summary]`), so the transcript exclusion has to be installed
before the bridge starts emitting. The journal change is inert until the bridge
publishes, so it can go first.

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
   **Prompt window is incremental, not fixed:** each pass sends only the messages
   since the last successful pass (`chatHistory.slice(_lastSummaryMsgCount)`),
   capped at 200 bubbles, plus the previous `ROSTER:` paragraph as a short context
   preamble so the title and rolling summary stay coherent. This replaces today's
   fixed `slice(-50)`, which re-sent ~45 already-summarized messages every pass
   (~10× re-billing per message over its lifetime) and never actually included the
   prior summary text in the prompt. If a turn exceeds the cap, the oldest overflow
   is dropped from the prompt but `_lastSummaryMsgCount` still advances past it, so
   nothing is double-summarized later.
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
   `maybeUpdatePinnedSummary` calls this instead of `genAI` directly; the prompt
   gains the prior-`ROSTER:` preamble and the incremental window (see #1), while
   the response format, parsing (`parseTitlePassResponse`), and the
   ROSTER-must-be-last constraint are unchanged. `.env.example` and README document the new envs.

### Journal (matron-journal)

1. Add `'summary'` to `AGENT_PUBLISH_TYPES` (the ws.js validation whitelist) but
   **not** to `MESSAGE_TYPES` (journal.js) — that array drives snippet writes and
   unread increment/recompute, so omission gives us "no snippet, no unread" by the
   same accepted design precedent as the `edit` kind. `last_seq` still advances.
2. **Push opt-out is the one real edit:** `push.js` `classify()` fails open (its
   final return treats unknown kinds as routine activity), so add an explicit
   `if (type === 'summary') return null` alongside the `convo_meta` case.
3. Fanout, cursor replay, and `/messages` pagination are type-agnostic — no
   changes needed. Summaries stay out of the FTS index (`indexableBody` already
   excludes unknown kinds). Accepted side effect: the chat-list `last_ts` moves on
   a summary event, but since passes fire at turn end — seconds after real
   messages — this is unobservable in practice.
4. **Retention:** the journal never deletes events (retention only rewrites
   `tool_output` payloads), so TOC entries persist and replay indefinitely.
5. Current apps render unknown kinds visibly (`[unsupported event: summary]`), so
   the app-side transcript exclusion must be installed before the bridge emits —
   hence the journal → apps → bridge deploy order.

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
   the nearest message with `seq <= entry.seq`. There is no existing
   jump-to-message machinery (search hits currently just open the room — precise
   scroll was deferred as a "Phase 6 follow-up"), so this feature builds it: a
   shared `ChatViewModel.focus(seq:)` that pages history backward until the target
   region is loaded (respecting the `reachedHistoryStart` latch), widens the row
   window, and hands the anchor to the per-platform scroll glue with tail-follow
   disengaged. Search-hit navigation can adopt the same API later.

### Cost note

A typical pass now sends 5–15 new bubbles plus the prior rolling paragraph
(~1–5k input tokens; the 200-bubble cap bounds the worst case at roughly
50–100k, ≈ $0.02 on Luna) and returns ~150 tokens. The incremental window is
the bigger saving — each message is summarized ~once instead of ~10× — with the
Luna switch (2.5× cheaper per token) on top.

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
  `_lastSummaryMsgCount`, no mid-turn fire), the incremental window (slice from
  last pass, 200-bubble cap with cursor advancing past overflow, prior-roster
  preamble present), provider selection (OpenAI present / Gemini only / neither),
  and the published payload shape.
- **Journal:** kind accepted and fanned out; no snippet change, no unread
  increment, no push for `summary` events.
- **Apps:** decoder → `summary_entries` row (live + replay); transcript excludes the
  kind; panel renders collapsed/expanded states (snapshot tests, Mac layout pinned
  like existing panels); navigation scrolls to the right message including the
  outside-loaded-window case.
- **End-to-end (manual):** real conversation on the deployed stack — entries appear
  after turns, panel navigates, no pushes/badges from summary traffic.
