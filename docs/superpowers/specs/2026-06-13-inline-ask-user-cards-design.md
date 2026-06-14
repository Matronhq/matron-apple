# Inline ask-user cards — design

> **Status:** approved (2026-06-13). Next: implementation plan via writing-plans.
> **Branch:** `inline-ask-user-cards` (off `main`, independent of Phase 6 / PR #9).

## Problem

Bot questions — including the live buttons-protocol prompt the bridge sends when
a message is queued ("message queued" + Cancel / Send buttons) — currently
present as a **blocking modal sheet** (`AskUserSheet` on iOS, `MacAskUserSheet`
on Mac), driven off `ChatViewModel.pendingAsk()`. The timeline shows only a
centered "❓ <prompt>" pill; the real interaction is the sheet.

This diverges from matron-x-ios and matron-web/desktop, where questions render
**inline in the conversation** and are **non-blocking** — the user can scroll,
keep reading, and answer in place. The sheet steals focus and hides the chat.

## Goal

Render every ask-user prompt as an **inline, non-blocking card** in the timeline
(the same way `.toolCall` already renders as an inline `ToolCallCard`), and
remove the sheet path entirely. Behaviour matches matron-x / matron-web.

## Scope (decided during brainstorming)

- **All prompt kinds inline** — buttons (choice / multi-choice), free-text
  (`ask_user`), and yes/no — not just the buttons protocol. Free-text becomes an
  inline text field. The sheet is deleted, not kept as a fallback.
- **Answered state echoes the choice** — once answered, the card shows the prompt
  plus the selected answer (e.g. "✓ You chose: Send"), derived so cross-device
  answers display too.

## Non-goals

- No change to the wire protocols (`chat.matron.ask_user`, `chat.matron.buttons`,
  `chat.matron.button_response`) or to `AskUserEvent` parsing.
- No change to how answers are *sent* (`AskUserSheetViewModel.send()` is reused
  verbatim — text reply for `.textReply`, `button_response` for `.buttonResponse`).
- Search / Phase 6 is untouched.

## Current architecture (what we're changing)

- `TimelineItem.Kind.askUser(eventID, AskUserEvent)` — buttons piggyback on
  `m.room.message` (`mapButtonsMessage`); `ask_user` custom events map here too.
- `TimelineItemView` (iOS) / `MacTimelineItemView` (Mac): `.askUser` → a centered
  capsule **pill** (indicator only).
- `ChatView` / `MacChatView`: present `AskUserSheet` / `MacAskUserSheet` via
  `pendingAsk()` + a `pendingAskPrompt` `@State` + `.sheet(item:)`, with
  same-prompt guards and `isPromptAnswered` / `markPromptAnswered` bookkeeping.
- `AskUserSheetViewModel` (MatronViewModels): owns the answer state (text /
  choice / multi-choice / boolean), `send()`, expiry, idempotency.
- `AskUserSheetBody` (MatronDesignSystem): renders prompt + the four input kinds
  + expiry notice + error + Send. Parameterised on plain state + bindings (no
  sheet chrome — no title bar, Close button, or detents). **Directly reusable
  inline.**
- `.askUserAnswer(promptEventID, selectedValues)`: hidden bookkeeping item
  carrying the wire `value`s of a buttons answer.

## Design

### 1. `AskUserCard` (new, shared — `MatronDesignSystem`)

A bot-aligned card (same framing as `ToolCallCard`: left-aligned, capped width,
card background) with three states:

- **Unanswered:** embeds `AskUserSheetBody` (interactive). Inline + non-blocking.
- **Answered:** a compact resolved row — the prompt plus **"✓ You chose:
  <answerSummary>"** (non-interactive). No input controls.
- **Expired (unanswered):** `AskUserSheetBody` already disables its inputs and
  shows "This question has expired." — rendered inline.

`AskUserCard` is parameterised on plain values (event, `isAnswered`,
`answerSummary`, the `AskUserSheetBody` bindings + `isSending`/`isExpired`/`error`
+ `onSend`) so MatronDesignSystem stays decoupled from app/service types and the
card is snapshot-testable directly — same contract style as `AskUserSheetBody`.

### 2. `ChatViewModel` changes (MatronViewModels)

- **Per-prompt VM cache.** Add a `[promptEventID: AskUserSheetViewModel]` cache
  and an accessor `askViewModel(for eventID: String, event: AskUserEvent) ->
  AskUserSheetViewModel` that returns a stable instance (creating on first use
  via the existing `makeAskUserSheetViewModel`). Stability matters: in a
  scrolling `ForEach`, a fresh VM per render would reset typing / selection on
  every timeline snapshot. The cached VM's `onClose` calls
  `markPromptAnswered(eventID)` so a successful send flips the card to resolved.
- **Answer summary.** Add `answerSummary(forPrompt eventID: String) -> String?`:
  - buttons (`.askUserAnswer` present for this prompt): map its `selectedValues`
    (wire values) back to option **labels** via the prompt's `AskUserEvent.options`,
    joined with ", ". Falls back to the raw values if a label can't be resolved.
  - text channel: the body of the reply message whose `inReplyToEventID ==
    eventID`.
  - returns `nil` if no answer is found yet (card stays interactive).
- Keep `isPromptAnswered` / `markPromptAnswered`. Remove `pendingAsk()` **iff**
  nothing else references it after the sheet is gone (verify during
  implementation; it exists only to feed the sheet).

### 3. Remove the sheet path (both platforms)

- Delete `Matron/Features/Chat/Rendering/AskUserSheet.swift` and
  `MatronMac/Features/Chat/MacAskUserSheet.swift`.
- In `ChatView` + `MacChatView`: remove the `pendingAskPrompt` `@State`, the
  `.sheet(item: askUserSheetBinding)`, the `askUserSheetBinding`/`closeAskUserSheet`
  helpers, and the `.onChange(of: viewModel.items)` block that drives
  `pendingAsk()`. (The per-prompt answered re-query is no longer needed — each
  card reads `isPromptAnswered` directly.)

### 4. Timeline rendering (both platforms)

- `TimelineItemView` + `MacTimelineItemView`: replace the `.askUser` pill with
  `AskUserCard`, wired to `viewModel.askViewModel(for:event:)`,
  `viewModel.isPromptAnswered(eventID)`, and
  `viewModel.answerSummary(forPrompt: eventID)`. Bot-aligned like the
  `.toolCall` card. The card needs the view-model (for the cached ask VM +
  answered state); the timeline item views already receive closures from the
  parent chat view, so the ask VM + answered/summary lookups are threaded the
  same way (a small accessor closure or the `ChatViewModel` passed through).

### 5. Tests

- `AskUserCardSnapshotTests` (DesignSystem, gated by `MATRON_SKIP_SNAPSHOT_TESTS`
  like the others): unanswered / answered / expired across the input kinds.
  Replaces the `AskUserSheetSnapshotTests` coverage.
- `ChatViewModel` unit tests: VM-cache returns a stable instance per prompt;
  `answerSummary` maps buttons values→labels and reads text-reply bodies;
  send-success marks answered.
- Remove / repoint tests tied to the deleted sheet wrappers. `AskUserSheetBody`
  + `AskUserSheetViewModel` tests stay (both are reused).

## Data flow (answer, inline)

1. Bot prompt arrives → `.askUser` item → `AskUserCard` (unanswered) renders
   `AskUserSheetBody` via the cached `AskUserSheetViewModel`.
2. User selects an option / types, taps Send → `AskUserSheetViewModel.send()`
   writes the answer (text reply or `button_response`) and calls `onClose` →
   `markPromptAnswered(eventID)`.
3. The answer item syncs (hidden `.askUserAnswer`, or a reply message) →
   `isPromptAnswered` true + `answerSummary` resolves → card flips to the
   **Answered** state echoing the choice. Same on the user's other devices.

## Risks

- **VM-cache lifecycle.** The cache must key on `promptEventID` and survive
  timeline re-renders; it should not leak unboundedly. Rooms have few open
  prompts at a time, so an unbounded dict is acceptable, but it's cleared on
  `ChatViewModel` teardown (per-room VM). Verify no retain cycle via `onClose`.
- **Threading the VM into the timeline row.** `TimelineItemView` is currently
  value-state + closures. Passing the `ChatViewModel` (or focused accessor
  closures) into the `.askUser` branch must not regress the existing snapshot
  baselines for other kinds — scope the change to the `.askUser` case.
- **Snapshot churn.** New card baselines replace sheet baselines; pixel tests are
  CI-skipped, so this is local-only review.
