# Cross-message selection and transcript copy (Mac)

**Date:** 2026-09-05
**Platform:** macOS only (MatronMac)
**Status:** approved design, awaiting implementation plan

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
- Registry of live message text views keyed by item id and slot
  (`.body` or `.caption`), populated by `MessageCopyTextView` on
  `viewDidMoveToWindow` (window non-nil registers, nil unregisters),
  weak references.
- `anchor: (id, charIndex)?` and `head: (id, charIndex)?` — the two ends
  of the current cross-message selection. `nil` when there is none.
- `spans: [String: NSRange]` — the resulting per-message selected
  ranges, derived from `anchor`/`head` and `orderedIDs`.
- `hasSelection: Bool` (observed) — drives the context-menu item and
  ⌘C validation.
- `copyHandler: (() -> Void)?` — installed by `MacChatView`; builds and
  writes the transcript.

Operations:

- `beginCrossMessage(anchorID:charIndex:)` — called by the anchor text
  view when a drag escapes it vertically.
- `extend(toWindowPoint:in window:)` — resolves the message under the
  pointer (§3), converts the point into that text view and takes its
  `characterIndexForInsertion`, recomputes `spans`, and applies them:
  the anchor gets `press…end` (dragging down) or `start…press` (dragging
  up); the head gets `start…pointer` or `pointer…end`; every id between
  them in `orderedIDs` gets its full storage range. Ranges are applied
  with `setSelectedRange(_:affinity:stillSelecting:)` on the registered
  views; unregistered ids (no text body) are skipped.
- `finish()` — re-applies the spans with `stillSelecting: false`,
  installs a local `leftMouseDown` event monitor that calls `clear()`
  on the next press anywhere (the monitor returns the event unchanged).
- `clear()` — zeroes the selected range on every registered view,
  removes the monitor, nils `anchor`/`head`/`spans`.
- `selectedSpans() -> [(id: String, slot: Slot, range: NSRange)]` in
  row order, for the copy handler.

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
     within 0.25s). Otherwise keep looping.
   - `.leftMouseUp`: exit.
   - `.leftMouseDragged`, not yet escalated: convert the point into the
     view. If its y is within `[bounds.minY - slop, bounds.maxY + slop]`
     (`slop = 4pt`), set the selection from `anchorIndex` to
     `characterIndexForInsertion(at: point)` with `stillSelecting: true`
     — the within-message selection, now driven by us. Horizontal
     overshoot is allowed and clamps to the line ends as before. If y is
     outside the band, escalate: `controller.beginCrossMessage(anchorID:
     itemID, charIndex: anchorIndex)`.
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
   registered `MessageCopyTextView` is found — the direct hit.
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
span matches. Implementation: override `drawBackground(in:)` (TextKit 2
path: `textLayoutManager.enumerateTextSegments(in:type: .selection)`;
TextKit 1 path for tabled messages: `layoutManager.enumerateEnclosingRects`)
filling `NSColor.selectedTextBackgroundColor`, and set
`selectedTextAttributes` to an empty background so AppKit does not
double-paint the focused view in a different tone. If the unemphasized
override proves unnecessary on the target OS, the plan may drop it,
but the acceptance criterion stands: all spans the same colour.

Rows without a text body show nothing. The selection lives until the
next `leftMouseDown` anywhere (controller monitor), until the chat
changes (`MacChatView` clears on `viewModel.roomID` change), or until
the pane disappears.

### 5. Copy

Three entry points, one path:

- ⌘C / Edit ▸ Copy: `MessageCopyTextView.copy(_:)` — if
  `controller.hasSelection`, call `controller.copyHandler` and return;
  else today's behaviour. `validateUserInterfaceItem` returns `true` for
  `copy(_:)` while `hasSelection`, since the text view's own selection
  may be empty (e.g. the anchor sits in a gap).
- Right-click on a body: `menu(for:)` prepends "Copy N Messages" (N =
  distinct ids in `spans`) and a separator when `hasSelection`.
- Right-click on the row outside the body: the existing SwiftUI
  `.contextMenu` adds the same item when `controller.hasSelection`.

`MacChatView.copyHandler` builds the transcript:

```
entries = controller.selectedSpans() grouped by id, in row order
for each id:
  item = viewModel item with that id (windowedRows lookup)
  switch item.kind
    .text(body, _):
       text = span covers whole storage ? body (verbatim source)
            : MarkdownReconstruction.markdown(from: storage, in: range)
    .image(_, caption, …): text = "[Photo]" + (selected caption part, if any, prefixed by a space)
    .file(_, name, caption, …): text = "[File: name]" + (selected caption part)
    default: skip
  if text is empty after trimming: skip   // e.g. head span of length 0
  entry = (timestamp, name, text)
TranscriptFormatter.format(entries) -> String
Pasteboard.copy(string)
```

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

- `SelectableMessageText` gains `itemID: String?` and
  `slot: SelectionSlot = .body` (`.body`/`.caption`), defaulting to nil
  so every existing call site and test compiles unchanged. It reads the
  controller from `@Environment(MessageSelectionController.self)` as an
  optional and hands both to the text view in `makeNSView`/`updateNSView`.
- `MacTimelineItemView` passes `item.id` for bodies and captions.
- `MacTimelineListContent.body` assigns `controller.orderedIDs` from
  `windowedRows` (message rows only).
- `MacChatView` owns the controller in `@State`, injects it with
  `.environment(controller)`, installs `copyHandler`, clears on room
  change and in the outer `onDisappear`. `MacSubChatPane` does the same
  with its own instance.
- Row `==` gates are untouched: no row reads controller state in its
  body, so no per-drag SwiftUI invalidation occurs. The only observed
  property, `hasSelection`, is read by context-menu builders (evaluated
  on open) and nowhere else.

### 7. Edge cases

- Streaming tail row: its storage is replaced by deltas while selected.
  `setAttributedString` resets the selection in that view; on the next
  drag event `extend` re-applies spans, clamping to the new length. On
  copy, ranges are clamped to `storage.length` before use.
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
  nearest-view fallback picks the vertically nearest; `clear()` zeroes
  every view; `selectedSpans()` order follows `orderedIDs`, not
  registration order; ids without a view are skipped.
- `MessageCopyTextViewTests`: `shouldEscalate` band math including slop;
  `copy(_:)` routes to `copyHandler` when the controller has a
  selection and to the markdown path otherwise;
  `validateUserInterfaceItem` for `copy(_:)`; `menu(for:)` prepends the
  item with the right count. The tracking loop itself is not driven
  headless (existing rule: AppKit press paths flip between shapes run
  to run).

Snapshot (`MatronMacTests`, respects `MATRON_SKIP_SNAPSHOT_TESTS`): one
timeline of three messages with spans applied via the controller —
verifies the uniform highlight colour across a focused and an
unfocused view.

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
