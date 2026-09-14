# Cross-message selection and transcript copy (Mac)

**Date:** 2026-09-05
**Platform:** macOS only (MatronMac)
**Status:** implemented (branch `feat/cross-message-copy`); this document tracks the shipped code

## Goal

Let the user click inside one message, drag into another, and copy the
selected span as a transcript with names and timestamps — the way Slack
selects across messages and WhatsApp formats copied messages. The
selection is character-precise at both ends: part of the first message,
every message in between, part of the last message.

## Non-goals

- iOS. The iOS timeline has no per-message `NSTextView` and no pointer.
- Selecting tool-call cards, diffs, consent cards, state notices or
  live indicators. They are neither highlighted nor copied.
- Rich-text (RTF) transcript. The transcript is plain text only.
- Keyboard-driven extension (shift-arrow) of a cross-message selection.
- Drag-and-drop of the selected text out of the window.

## Current state

- Every Mac message body (and every image/file caption) is a
  `SelectableMessageText`, an `NSViewRepresentable` hosting a
  `MessageCopyTextView` (a `MouseTrackingRescueTextView`, itself an
  `NSTextView`). `MarkdownAttributed` renders the source; `copy(_:)`
  writes the verbatim markdown source for a whole-storage selection and
  `MarkdownReconstruction.markdown(from:in:)` for a partial one.
- A press on a body runs AppKit's private nested tracking loop inside
  `super.mouseDown`. Selection therefore stops at the message boundary.
  `MouseTrackingRescueTextView` arms a `.eventTracking` timer that posts
  a synthetic `mouseUp` if the loop outlives the physical press, and
  re-dispatches link clicks that AppKit swallows.
- `MacTimelineListContent` renders `viewModel.windowedRows` in an eager
  `VStack`; `MacTimelineRowView` is `Equatable`-gated per row. The
  right-click menu on text rows offers a single-message Copy.
- `Pasteboard.copy(_:)` in `DesignSystem` is the shared string writer.

## Design

### 1. Selection controller

`MessageSelectionController` — `@MainActor @Observable final class`, macOS
only, in `MatronShared/Sources/DesignSystem`. One instance per
`MacChatView` (and per `MacSubChatPane`), injected through the SwiftUI
environment as an optional, so previews and tests without one keep the
feature inert.

State:

- `orderedIDs: [String]` — message item ids in row order, written by
  `MacTimelineListContent` each time it renders (`@ObservationIgnored`,
  a plain assignment; never read from a SwiftUI body).
- Registry of live message text views keyed by item id (an item has
  either a body or a caption view, never both), populated by
  `MessageCopyTextView` on `viewDidMoveToWindow` (window non-nil
  registers, nil unregisters), weak references.
- `anchor: (id, charIndex)?` and `head: (id, charIndex)?` — the two ends
  of the current cross-message selection. `nil` when there is none. The
  per-message ranges are derived from them on every change and pushed
  straight to the views; no `spans` dictionary is kept, only the set of
  ids currently carrying a range, so a shrink can clear exactly those.
- `hasSelection: Bool` (observed) — drives the context-menu item and
  ⌘C validation. The controller's ONLY observed property.
- `transcriptProvider: (() -> SelectionTranscript)?` — installed by
  `MacChatView`; maps `selectedSpans()` + the live `windowedRows` to the
  pasteboard text and the message count. Weak in both captures, so
  neither the controller nor the room's view model is retained by it.
- `finishedTranscript: SelectionTranscript?` (`@ObservationIgnored`) —
  the provider's result snapshotted at `finish()`, nil while there is no
  selection. Both MENU paths render and copy this snapshot, so a menu
  title and its payload always agree and neither is re-derived under the
  click that clears the selection. ⌘C keeps using the live provider, so
  it copies a still-streaming message as it stands now.

Operations:

- `beginCrossMessage(anchorID:charIndex:) -> Bool` — called by the
  anchor text view when a drag escapes it vertically. Returns `false`
  (and starts nothing) when the anchor id is not in `orderedIDs`; the
  caller then stays un-escalated and keeps selecting within its own
  message.
- `extend(toWindowPoint:in window:)` — resolves the message under the
  pointer (§3), converts the point into that text view and takes its
  `characterIndexForInsertion`, recomputes the per-message ranges and
  applies them: the anchor gets `press…end` (dragging down) or
  `start…press` (dragging up); the head gets `start…pointer` or
  `pointer…end`; every id between them in `orderedIDs` gets its full
  storage range. Ranges are pushed with `setCrossSelection(_:)` (§4),
  not `setSelectedRange`; unregistered ids (no text body) are skipped.
  When either end has left `orderedIDs` the whole selection is cleared
  rather than left half-lit.
- `finish()` — re-applies the ranges, and, unless that cleared the
  selection, snapshots `finishedTranscript` and installs a local
  `leftMouseDown` event monitor that calls `clear()` on the next press
  anywhere (the monitor returns the event unchanged). A finish that
  cleared arms no monitor.
- `clear()` — drops every applied range, removes the monitor, nils
  `anchor`/`head`/`finishedTranscript`.
- `selectedSpans() -> [SelectedSpan]` in row order, for the transcript
  provider. Each span is `(id, text: String?)`: `nil` when that id has no
  text view at all (an uncaptioned image, a card), `""` when it has one
  with nothing selected.

### 2. The press and drag

`MessageCopyTextView.mouseDown` takes over a press only when all hold:
a controller is present, `event.clickCount == 1`, no
shift/command/option/control modifier, and the view is selectable and
not editable. Otherwise it defers to the existing rescue-timer path
(double/triple-click word/paragraph selection, shift-extend and
modifier clicks stay AppKit's).

Takeover path:

1. `controller.clear()` — any press ends the previous selection.
2. `armLinkPress(for:)` as today, `window.makeFirstResponder(self)`.
3. Record `anchorIndex = characterIndexForInsertion(at: press)` and set
   a zero-length selection there.
4. Tracking loop: `window.nextEvent(matching: [.leftMouseDragged,
   .leftMouseUp], until: now + 0.25s, inMode: .eventTracking,
   dequeue: true)`.
   - Timeout (nil event): if `NSEvent.pressedMouseButtons & 1 == 0` or
     `window == nil` or `superview == nil`, the press is over — exit.
     This is the built-in replacement for the rescue watchdog on this
     path (the lost-mouseUp and mid-press-remount cases both resolve
     within 0.25s). Otherwise the pointer is parked with the button held
     (usually against a viewport edge): autoscroll from the last drag
     event and then handle its position through the SAME per-point
     routine the drag branch uses, re-derived after the scroll. Sharing
     the routine is load-bearing — a parked branch that only grew the
     running selection scrolled a tall message to its end and froze,
     because it never re-ran the escalation test after the content moved.
   - `.leftMouseUp`: exit.
   - `.leftMouseDragged`, not yet escalated: convert the point into the
     view. If its y is within `[bounds.minY - slop, bounds.maxY + slop]`
     (`slop = 4pt`), set the selection from `anchorIndex` to
     `characterIndexForInsertion(at: point)` with `stillSelecting: true`
     — the within-message selection, now driven by us. Horizontal
     overshoot is allowed and clamps to the line ends as before. If y is
     outside the band, escalate: `controller.beginCrossMessage(anchorID:
     itemID, charIndex: anchorIndex)`. The press only counts as escalated
     if that returns `true`; a refusal (this message has left the row
     window mid-press) keeps the drag selecting within the message, so
     the selection sequence is still closed on mouse-up.
   - `.leftMouseDragged`, escalated: `controller.extend(toWindowPoint:
     event.locationInWindow, in: window)` then `autoscroll(with:
     event)` so the enclosing scroll view scrolls at the edges. Dragging
     back inside the anchor's band un-escalates: `controller.clear()`
     and the loop resumes within-message selection from `anchorIndex`.
5. After the loop: if escalated, `controller.finish()`. Otherwise set
   the final selection with `stillSelecting: false`; if the pointer
   never moved beyond `linkClickSlop` and no selection was made,
   `resolveLinkPressIfNeeded()` dispatches a link click as today.

The pure decision "does this pointer y escape the band" is a static
function `shouldEscalate(pointY:bounds:slop:)` so it is unit-testable.

### 3. Resolving the message under the pointer

`controller.extend` finds the target text view as follows:

1. `window.contentView?.hitTest(point)`, walking `superview` until a
   `MessageCopyTextView` is found — the direct hit. It is accepted only
   when it is THIS controller's live registration for its own id;
   otherwise it is discarded and rule 2 applies. (The hit test walks the
   whole window, so with a sub-chat pane beside the parent it can return
   the other timeline's view — trusting it froze the drag, because the
   foreign id is absent from `orderedIDs`.)
2. Otherwise (pointer over a card, a date separator, bubble padding, or
   the composer/toolbar), the registered view whose window-space frame
   is vertically nearest the pointer, ties broken by row order.

The character index inside the target is `characterIndexForInsertion`
of the pointer converted into that view; AppKit clamps it to `0` above
the text and `storage.length` below, which yields the natural "gap
above a message selects none of it, below selects all of it".

Only views registered to this controller are candidates, so a second
timeline in the same window (a sub-chat pane beside the parent) never
receives the parent's selection.

### 4. Highlight

The highlight is the text views' own selection drawing, so a
cross-message selection looks like a within-message one continued
downwards. `MessageCopyTextView` draws its selected range in the
active selection colour whether or not it is first responder, so every
span matches. Implementation: TextKit 2 rendering attributes
(`NSTextLayoutManager.addRenderingAttribute(.backgroundColor…)`) and
TextKit 1 temporary attributes for tabled messages, in
`NSColor.selectedTextBackgroundColor`. The anchor's own `selectedRange`
is emptied on escalation so AppKit never paints its focused/unfocused
variants underneath.

Rows without a text body show nothing. The selection lives until the
next `leftMouseDown` anywhere (controller monitor), until the chat
changes (`MacChatView` clears on `viewModel.roomID` change), or until
the pane disappears.

### 5. Copy

Three entry points, one path:

- ⌘C / Edit ▸ Copy: `MessageCopyTextView.copy(_:)` — if
  `controller.hasSelection`, call `controller.copyTranscript()` (the
  LIVE provider) and return; else today's behaviour.
  `validateUserInterfaceItem` returns `true` for `copy(_:)` while
  `hasSelection`, since the text view's own selection may be empty (e.g.
  the anchor sits in a gap), and answers for `copyCrossSelection(_:)`
  itself rather than relying on `NSTextView`'s non-contractual answer
  for an action it does not know.
- Right-click on a body: `menu(for:)` prepends "Copy N Messages" (N =
  `finishedTranscript.messageCount`) and a separator to whatever `super`
  returned, and carries the snapshot's text in the item's
  `representedObject`; `copyCrossSelection(_:)` copies that captured
  string. When there is nothing to add, `menu(for:)` returns exactly what
  `super` returned — including `nil`, so a right-click that AppKit would
  not answer is not swallowed by an empty menu.
- Right-click on the row outside the body: the existing SwiftUI
  `.contextMenu` on `.text` rows adds the same item, built from
  `finishedTranscript` and copying its captured text.

`MacChatView`'s transcript provider builds the transcript: `controller.selectedSpans()`
grouped by id in row order, each id resolved to its `windowedRows` item.
Implemented as `MacChatView.transcript(from:spans:locale:timeZone:)` —
pure and unit-tested (`MacChatViewTranscriptTests`). Rule table: `.text`
→ the selected text, skipped when empty; `.image` → `[Photo]` /
`[Photo] <selected caption>`; `.file` → `[File: name]` /
`[File: name] <selected caption>`; a captioned image/file whose caption
view has nothing selected contributes nothing; every other kind
omitted. The resulting entries feed `TranscriptFormatter.format(entries)`,
which is then written with `Pasteboard.copy(string)`.

Name: `"Me"` when `item.isOwn`, else
`MacTimelineItemView.displayName(for: item.sender)` (the timeline's own
label).

`TranscriptFormatter` (pure, in `MatronShared/Sources/Chat`, usable
from iOS later):

```
[<short date>, <short time>] <name>: <text>
```

- Date and time use `DateFormatter` with `dateStyle: .short`,
  `timeStyle: .short` in the supplied `Locale`/`TimeZone` (defaults:
  current). e.g. `[05/09/2026, 14:33]` in en_GB, `[9/5/26, 2:33 PM]` in
  en_US.
- Multi-line text continues on following lines unprefixed, as WhatsApp
  does. Entries are separated by a single newline; no trailing newline.
- Text is used as-is (no whitespace collapsing) except that leading and
  trailing newlines are trimmed per entry.

### 6. Timeline wiring

- `SelectableMessageText` gains `itemID: String?`, defaulting to nil so
  every existing call site and test compiles unchanged. There is no
  slot: an item has either a body or a caption view, never both, so the
  item id alone identifies the view. It reads the controller from
  `@Environment(MessageSelectionController.self)` as an optional and
  hands both to the text view in `makeNSView`/`updateNSView`.
- `MacTimelineItemView` passes `item.id` for bodies and captions.
- `MacTimelineListContent` assigns `controller.orderedIDs` from
  `windowedRows` (message rows only) in an `onChange`, never in `body`.
- `MacChatView` owns the controller in `@State`, injects it with
  `.environment(controller)`, installs the transcript provider in
  `onAppear`, and clears the selection + drops the provider in the outer
  `onDisappear`. There is no explicit room-change clear: `MacChatListView`
  keys the chat on `.id(roomID)`, so a room change rebuilds the whole
  view — the old instance's `onDisappear` runs the teardown and the new
  one gets a fresh controller. `MacSubChatPane` does the same with its
  own instance.
- Row `==` gates are untouched: no row reads controller state in its
  body. The only reads are in the leaf `MacSelectionCopyMenuItems`, which
  reads `hasSelection` (observed) and `finishedTranscript`
  (`@ObservationIgnored`) — never `transcriptProvider()`, which would
  pull the streaming `windowedRows` into the host row's observation.

### 7. Edge cases

- Streaming tail row: its storage is replaced by deltas while selected.
  The rendering attributes die with the old storage, so `updateNSView`
  re-applies the view's range with `setCrossSelection(_:force: true)`
  (the plain call early-outs on an unchanged range — a drag pushes the
  same range to every middle view on every mouse event). On copy, ranges
  are clamped to `storage.length` before use.
- An endpoint leaves the row window while the selection is FINISHED —
  most often the `eph:` streaming placeholder being replaced by its
  durable row. Reassigning `orderedIDs` revalidates both ends and clears
  the whole selection when either is gone; otherwise `hasSelection`
  would stay true over an empty `selectedIDs`, leaving highlights lit
  while every copy path silently no-ops.
- A body view is recycled onto a different message id mid-selection: the
  id change unregisters under the old id AND drops any range painted
  under it, which the controller could no longer reach to clear.
- The anchor view is remounted or scrolled out of the window mid-drag
  (it cannot leave the eager window, but a chat switch can unmount it):
  the loop's `superview == nil` check exits; `finish()` on an
  unregistered anchor leaves whatever spans were applied — the room
  change then clears everything.
- Dragging past the window into the sidebar or composer: nearest-view
  fallback keeps the head on the top or bottom message.
- A press that starts on a link and drags: `armLinkPress` recorded it;
  resolve is skipped because the pointer moved (existing slop rule).
- Sub-chat pane beside the parent: separate controllers and registries;
  a drag in one never selects in the other.
- Zero-length head span (pointer in the gap just above the head
  message): the head contributes nothing and "Copy N Messages" counts
  only ids with non-empty spans.

### 8. Testing

Unit (`MatronShared/Tests`, macOS-gated where AppKit is involved):

- `TranscriptFormatterTests`: single entry; own vs other names;
  multi-line body continuation; partial first/last text; pinned
  `en_GB` and `en_US` locales and a fixed time zone; empty list → empty
  string; no trailing newline.
- `MessageSelectionControllerTests` with a stub registry (frames and
  storages supplied by the test, no window): spans for down-drag and
  up-drag; anchor == head collapses to a within-message range;
  nearest-view fallback picks the vertically nearest, including when the
  direct hit belongs to another controller; `clear()` zeroes every view;
  `selectedSpans()` order follows `orderedIDs`, not registration order;
  ids without a view are skipped; a finished selection is dropped when an
  endpoint leaves a reassigned `orderedIDs`.
- `MessageCopyTextViewTests`: `shouldEscalate` band math including slop;
  `copy(_:)` routes to `copyTranscript()` when the controller has a
  selection and to the markdown path otherwise;
  `validateUserInterfaceItem` for both `copy(_:)` and
  `copyCrossSelection(_:)`; `menu(for:)` prepends the item with the right
  count and carries the finished transcript's text on it. The tracking loop itself is not driven
  headless (existing rule: AppKit press paths flip between shapes run
  to run).

Attribute readback (`MessageCopyTextViewSelectionTests`): applying and
clearing a span adds/removes the background rendering attribute — the
uniform-colour guarantee is then a property of using one attribute
value everywhere, checked visually in the manual pass.

Manual (`manual-tests.md`): drag from mid-message to mid-message
downwards and upwards; ⌘C, Edit ▸ Copy and both right-click paths yield
the same text; click clears; chat switch clears; autoscroll at the
bottom edge during a drag; links still open on click; double-click
still selects a word.

## Decisions log

- Own messages are labelled "Me": Matron has no reliable display name
  for the local user, and "Me" matches the existing accessibility label.
- Only spans with text are highlighted and non-text rows are omitted
  from the transcript, so the copied text equals what is visibly
  selected, with `[Photo]`/`[File:]` markers as the single exception
  because captions are selectable.
- Locale-formatted timestamps rather than a fixed pattern: matches
  WhatsApp and reads naturally to the user pasting it.
