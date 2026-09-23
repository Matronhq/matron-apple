# Mac navigation history: always-on Back and Forward — design

**Date:** 2026-09-23 · **Requested by:** Dan (2026-09-23: "can we make it
so there is always a back button so if you are in one place and go
somewhere else you can press back to go where you were before … separate
from back on mobile which would always go back to the conversation list";
tracker #2536: "yes forward too. I think item pane pushes should be in
history too … you don't have a concept of whether it's a global or local
back, you just want to go back")

Mac app only. No journal, bridge or iOS change.

## Problem

The Mac app has several ways to move between places — the nav column
(Coordinator / Missions / Decisions / Conversations), sidebar rows,
⌘1/2/3, notification taps, search hits, `matron://item/N` links, milestone
jumps, a mission's title tap, "Open conversation" from an item — and a few
scattered, local ways back: the items pane's push stack, the narrow pane's
close chevron, the mission page's "Back to the conversation". None of them
is "go back to where I just was". Land on an item from a chat, follow a
link to a conversation, and the only way back to the item is to find it
again.

## Goal

A browser-style history for the whole window:

- **Back and Forward buttons, always present** at the window's top-left,
  greyed when there is nothing to go to.
- **⌘[ and ⌘]**, and a **Go** menu carrying the same two commands.
- **Every place change counts**, whichever way it was reached, including
  the items pane's own pushes and pops and opening or closing a sub-chat.
  The user has no concept of a global versus a local back; Back just goes
  to the previous place.
- The existing local affordances stay exactly as they are. They are
  ordinary place changes and so are recorded like any other.

## Non-goals

- iOS: its Back stays hierarchical (a conversation's Back always returns
  to the list). Nothing in this spec touches the iOS target.
- Persisting the history across launches or windows. It is per window,
  per run.
- Trackpad swipe-back gestures. ⌘[ / ⌘] and the buttons are enough for v1.
- Recording transient state that is not a place: the search results panel
  (a non-empty query), scroll positions, the composer draft, a milestone
  jump's scroll target, sheets.

## Design

### 1. What a place is

Where the user is in a window is fully described by shell state in
`MacChatListView` plus the pane state of the mounted chat. `MacPlace` is a
value snapshot of exactly that, normalised so fields that do not apply to
the selected nav entry are `nil` (an auto-open changing the Conversations
selection while the user reads a mission must not mint a new place):

```swift
struct MacPlace: Equatable {
    enum Detail: Equatable {
        case coordinator(pane: MacChatPaneRoute?)
        case conversation(id: String?, pane: MacChatPaneRoute?)   // nil id = "Select a chat"
        case mission(id: String?)
        case decision(id: String?)
    }
    var detail: Detail
    var nav: MacNav { … }   // derived from `detail`
}

/// What the chat detail is showing beside (or instead of) the timeline.
enum MacChatPaneRoute: Equatable {
    case items(path: [String])   // the pane is open; `path` is its push stack (empty = the list)
    case subChat(id: String)     // a subagent child open in the split pane
}
```

`MacChatPaneRoute` is the one thing that does not live in the shell
today. Section 3 hoists it.

### 2. The history model

`MatronMac/Features/Nav/MacNavigationHistory.swift`, `@MainActor
@Observable`, pure — no SwiftUI, no AppKit:

```swift
final class MacNavigationHistory {
    private(set) var current: MacPlace?
    private(set) var back: [MacPlace] = []
    private(set) var forward: [MacPlace] = []
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    static let capacity = 50

    /// The shell reports every place it lands on. No-op when `place` is the
    /// current one; otherwise the current place moves onto `back`, `forward`
    /// is dropped (a new branch, as in a browser), and `back` is capped.
    func visit(_ place: MacPlace)
    /// Returns the place to restore, or nil. Moves `current` onto `forward`.
    func goBack() -> MacPlace?
    func goForward() -> MacPlace?
}
```

Both `goBack` and `goForward` set `current` to the returned place *before*
the shell restores it. The restore then lands in `visit` as "already the
current place" and is a no-op, so restoring never records and no
"restoring" flag is needed. Only `canGoBack`/`canGoForward` are read from
SwiftUI bodies (the two buttons); the arrays are written from `onChange`.

### 3. Hoisting the chat pane route

`MacChatView` is `.id(id)`-keyed per conversation and holds `openSubChatID`
and `itemsPaneState.path` as its own state, reset on every conversation
switch. `itemsPaneOpen` was already hoisted to the shell as a per-window
`Binding<Bool>` (I5). This replaces that Bool with a per-window route:

- `MacChatListView` owns `@State private var paneRoute: MacChatPaneRoute?`
  and passes `paneRoute: $paneRoute` to `MacChatView` (the old
  `itemsPaneOpen` binding goes; its `.constant(false)` default becomes
  `.constant(nil)` so previews and tests compile unchanged).
- `MacChatView` keeps `openSubChatID` and `itemsPaneState` as its own
  state — every existing read/write site is unchanged — and adds a
  two-way sync:
  - **On mount, before observing:** `itemsPaneState` and `openSubChatID`
    are initialised from the binding (`init` seeds them via
    `State(initialValue:)` from `paneRoute.wrappedValue`), so a freshly
    mounted chat never reports a transient `.items(path: [])` over a
    route the shell is restoring.
  - **Local → shell:** `.onChange(of: localRoute)` writes the binding,
    where `localRoute` is `MacChatPaneRoute.from(itemsPaneOpen:
    showItemsPane, path: itemsPaneState.path, subChatID: openSubChatID)`
    (a pure static helper, tested).
  - **Shell → local:** `.onChange(of: paneRoute.wrappedValue)` applies a
    route that differs from `localRoute` (a Back/Forward restore on the
    same conversation) to the three local states.
- `showItemsPane` stays a computed proxy, now over the route: `true`
  when the route is `.items`. Setting it `true` on a non-items route sets
  `.items(path: [])`; setting it `false` clears the route.
- **Switching conversations with the pane open** must keep today's
  behaviour: the pane stays open but shows the new conversation's list.
  The shell does this in `handleSelectionChange` (the `onChange` of
  `selectedSummaryID`, which every selection path already funnels
  through): when the conversation changes and the route is
  `.items(path)` with a non-empty path, it becomes `.items(path: [])`; a
  `.subChat` route is cleared (a child belongs to its parent). A
  Back/Forward restore also changes the selection and so also reaches
  this `onChange` — with the restored route already in place, which the
  reset must not wipe. The guard needs no flag: `goBack`/`goForward`
  set `history.current` to the restored place before `restore` writes
  any state, so `handleSelectionChange` skips the reset exactly when
  the place it now sees equals `history.current` (a plain click lands
  on a place the history has not seen yet). Pinned by a test (§8).

### 4. Observing and restoring in the shell

In `MacChatListView`:

```swift
@State private var history = MacNavigationHistory()

/// Pure: the current place from the shell's state, normalised (tested).
static func place(nav: MacNav, selectedSummaryID: String?, selectedMissionID: String?,
                  selectedDecisionID: String?, paneRoute: MacChatPaneRoute?) -> MacPlace

private var currentPlace: MacPlace { Self.place(…) }

.onChange(of: currentPlace, initial: true) { _, place in history.visit(place) }

private func restore(_ place: MacPlace) {
    switch place.detail {
    case .coordinator(let pane):          nav = .coordinator; paneRoute = pane
    case .conversation(let id, let pane): nav = .conversations; selectedSummaryID = id; paneRoute = pane
    case .mission(let id):                pickMission-like assignment; nav = .missions
    case .decision(let id):               showDecisionsItem(id, switchingNav: true)
    }
}
```

`restore` writes state directly rather than through `showConversation`
(which clears search and would route the coordinator's own conversation
to the Coordinator entry — the recorded place already says which entry it
was under). It does keep the two side effects that protect other state:
`decisionsPaneState.cancelRecordingIfNavigating(to:)` for a decision,
and the search-query clear when landing on a conversation (the results
panel must not stay over a restored chat).

Nav-entry side effects that today run in `navChanged` (`focusSearch`
reset, `missionBackConvoID` clear, Decisions slot release) keep running:
`restore` changes `nav` through the same `@State`, so `.onChange(of:
nav)` fires as it does for a click.

`missionBackConvoID` (the mission page's "Back to the conversation") is
not part of the place: it is an affordance, and a restored mission page
simply does not offer it. The global Back covers that case now.

### 5. Buttons, shortcuts, menu

- **Buttons:** in the sidebar column's `.toolbar`, placement
  `.navigation`, before the New Chat item: `chevron.backward` and
  `chevron.forward`, `.disabled(!history.canGoBack)` /
  `.disabled(!history.canGoForward)`, `.help("Back")` / `.help("Forward")`.
  The sidebar toolbar is the window's top-left and is outside the chat
  header accessory, which must not gain toolbar items (PR #228). With
  the sidebar collapsed (`.detailOnly`) its toolbar section is hidden
  and the buttons go with it; accepted for v1, since ⌘[ / ⌘] and the Go
  menu still work and the sidebar is shown by default.
- **Commands:** `MatronCommand.goBack` / `.goForward` on the existing
  bus, listened to in `withCommandListeners` next to ⌘1/2/3. `⌘[` and
  `⌘]` are the macOS-standard Back/Forward keys (Finder, Safari, Xcode);
  no existing Matron command uses either.
- **Menu:** a new `CommandMenu("Go")` in `Commands.swift` with *Back*
  and *Forward*. Menu items validate through the same
  `canGoBack`/`canGoForward` state, published to the command bus's
  listener side by the shell: `Commands` cannot read view state, so the
  two items stay enabled and a press with nothing to go to is a no-op.
  (Same shape as ⌘1/2/3 today.)

### 6. Places that no longer exist

A restored conversation that has since been left or hidden, an item that
was deleted, a mission that is gone: `restore` still assigns the ids.
The detail column then shows what it shows today for a stale selection
("Select a chat", the item pane's not-found state, "Select a mission").
No pruning of the history on data changes; the entry is still a truthful
"you were here".

### 7. Error handling

There are no failure paths: the model is pure, and restoring is a set of
`@State` writes. The one hazard is a spurious history entry from a
transient place during a restore; §3's mount-time seeding and §4's
single-transaction `restore` are the guards, and §8 pins them.

### 8. Testing

- `MacNavigationHistoryTests` (new): visit records and clears forward;
  visiting the current place is a no-op; back/forward round trip;
  forward is dropped by a new visit; the returned place equals `current`
  so a follow-up `visit` of it does not record; capacity 50 drops the
  oldest.
- `MacMissionsNavTests` (extend, same pure-helper style): `place(…)`
  normalises (a Conversations selection is dropped under Missions; a
  route is dropped under Decisions/Missions); coordinator carries its
  pane route; `MacChatPaneRoute.from(…)` maps the three local states and
  back.
- `MacCommandsTests`: `.goBack` / `.goForward` exist and post distinct
  notification names.
- `MacChatViewTests` (extend): a `MacChatView` built with a `.items(path:
  ["it_9"])` route mounts with that path on its pane state (the seeding
  in §3), and a local push writes the binding.
- `MacChatListView` route reset (pure helper, `MacMissionsNavTests`
  style): `resetRoute(onSwitchTo:from:current:)` returns `.items(path:
  [])` for a click onto a new conversation with a pushed pane, `nil`
  for a `.subChat`, and leaves the route untouched when the resulting
  place equals the history's current place (a restore).
- Snapshot: none new. The two toolbar buttons are system chrome.

## Rollout

One PR, Mac target only, no migration. Both apps' behaviour elsewhere is
unchanged; iOS is untouched. The pane-route hoist is the one refactor
with reach (every `showItemsPane` / `openSubChatID` site in `MacChatView`
keeps its local semantics), and the plan runs the full `MatronMacTests`
suite with `MATRON_APP_SUPPORT_OVERRIDE` set after it.
