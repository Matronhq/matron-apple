# App shell: tabs, Decisions, tasks page, Mac nav — design

**Date:** 2026-09-09 · **Requested by:** Dan (voice notes, 2026-09-09: "swipe
right when you're looking at a conversation to have the whole screen
replaced by the task system like it does in Instagram or X … a bottom menu
… a decisions page … Mac should get a big icon nav to the left of the
conversations list like the workspace switcher in Slack")

Sub-project 1 of 3 in the move away from conversation-as-the-main-interface
(2 = Projects & milestones, 3 = Coordinator). Apps only: no journal or
bridge change. One repo, one implementation plan.

## Problem

The items tracker shipped (spec `2026-09-08-task-decision-tracker-design.md`)
as a right-edge drawer over the iOS chat and a pane inside the Mac detail
column. Dan's intent was different in two ways:

1. On iOS the tracker should be a *page*, not a drawer: the whole screen
   swaps to it, the way Instagram and X page between screens.
2. Things needing his decision should be visible in one place across every
   conversation, without opening each chat. Today the per-row needs-you
   badge on the chat list is the only cross-conversation signal.

Both apps also need somewhere for the Projects and Coordinator surfaces to
land later, and the app has no top-level navigation to hang them on.

## Goal

- **iOS:** a bottom tab bar with *Conversations* and *Decisions*. Later
  sub-projects add *Projects* and *Coordinator* to the same bar.
- **Decisions** (both apps): every open item awaiting Dan, across all
  conversations, newest first, with its origin conversation. Nothing else.
  A badge with that count on the tab (iOS) and the nav entry (Mac).
- **Tasks page** (iOS): the chat screen pages horizontally between the chat
  and this chat's tracker. Swipe left to reveal, swipe right to return; the
  checklist toolbar button jumps to it. The drawer goes away.
- **Mac:** a vertical big-icon navigation column, icons with labels, to the
  left of the conversations list. *Conversations* and *Decisions* now; the
  later tabs join it. The per-chat tracker pane in the detail column stays.

## Non-goals

- Projects, milestones, Coordinator, and any journal/bridge work (sub-projects
  2 and 3).
- Replacing the summaries TOC (sub-project 2 supersedes it).
- Android (separate repo; ported afterwards from this spec).
- Changing what the tracker lists in *All* mode, item detail, comments, the
  tracker's `+` create sheet, or the queued-card *Make task* action.

## Design

### 1. Tracker view model: an all-conversations mode

`ItemsPanelViewModel` (`MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift`)
today requires a `convoID`, defaults `scope` to `.convo(convoID)`, and
derives `needsYouCount` for that conversation only (line ~187, by design).
Decisions needs neither a home conversation nor a per-chat count.

- `init(convoID: String?, …)`. `nil` ⇒ `scope` starts at `.all` and the
  picker's "This chat" option is unavailable (`ItemsListView` hides the
  picker when `convoID == nil`). `pendingCreates` filtering and Make task
  are unchanged; both already key off a non-nil `convoID` and are simply
  absent for a `nil` one.
- New derived, observable `awaitingYou: [TrackerItem]` — `sections.needsYou`
  (already `needsUser`, i.e. `state == .open && awaiting == .user`) sorted
  by `updatedAt` descending, across every conversation regardless of
  `scope`. New `awaitingYouCount = awaitingYou.count`. `needsYouCount`
  keeps its per-conversation meaning for the chat toolbar badge and the
  chat-list rows.
- `AppDependencies.makeItemsPanelViewModel(for:convoID:)` accepts the
  optional; a new `makeDecisionsViewModel(for:)` returns the `nil`-convo
  instance. One instance per session, held by the shell (below), so the
  badge is live app-wide; it starts with the shell and stops on sign-out.

### 2. Decisions list (shared)

New `DecisionsListView` in `MatronShared/Sources/DesignSystem/Items/`.
Input is a `Model { rows: [Row], isSupported: Bool?, isRefreshing: Bool }`
where `Row = (item: TrackerItem, originTitle: String?)`, so it is
snapshot-testable without a view model. Rows reuse `ItemRow` with the
origin subtitle always on (the same rendering `ItemsListView` uses in
`.all` mode). Empty state: "Nothing needs you" with the checkmark seal.
`isSupported == false` shows the same unsupported-journal message as the
tracker. Pull to refresh (iOS) and a refresh button (Mac) call the view
model's existing refresh.

Callbacks: `onSelect(itemID)`, `onOpenConversation(convoID)`.

### 3. iOS shell: tabs

`Matron/App/MatronApp.swift` line ~52 roots the signed-in branch at
`NavigationStack(path: $chatPath) { ChatListView(…) }`. That becomes the
*Conversations* tab of a `TabView(selection: $tab)` with `enum AppTab {
conversations, decisions }`:

- **Conversations:** the existing stack, path, environment injection, and
  every deep-link path (notification tap, new-conversation stream, cold-start
  drain) unchanged; they append to `chatPath` and additionally set `tab =
  .conversations`.
- **Decisions:** its own `NavigationStack(path: $decisionsPath)` hosting
  `DecisionsListView` fed by the shared view model, title "Decisions".
  `onSelect` pushes `ItemDetailHost` on this stack. `onOpenConversation`
  (from the row's context menu or the detail's origin link) sets `tab =
  .conversations` then appends the convo id to `chatPath`, in that order
  and in the same transaction, so the push lands in the visible stack.
- Badge: `.badge(decisionsVM.awaitingYouCount)` on the Decisions tab, hidden
  at zero.
- The tab bar is hidden inside a pushed chat (Dan, 2026-09-09) and inside a
  pushed item detail: the chat destination and `ItemDetailHost` carry
  `.toolbar(.hidden, for: .tabBar)`, so the bar shows only at the root of
  each tab. Re-tapping the selected Decisions tab pops its stack to root
  (SwiftUI default for a `NavigationStack` tab).
- New `Matron/App/AppShellView.swift` owns `tab`, `decisionsPath`, and the
  decisions view model; `MatronApp` shrinks to bootstrap/sign-in gating.

### 4. iOS tasks page: the pager

`ChatView` currently presents `ItemsDrawer` in a clear `fullScreenCover`
(line ~1242) opened by the checklist button and a trailing-edge drag
(lines ~940–956). Both go, along with `ItemsDrawer.swift`.

- `ChatView`'s content becomes `ChatPager`: a horizontal `ScrollView` with
  `.scrollTargetBehavior(.paging)`, `.scrollIndicators(.hidden)`, and
  `.scrollPosition(id: $page)` over two full-width pages, `enum ChatPage {
  chat, tasks }`. Page 0 is the existing timeline + composer; page 1 is
  `ItemsListView` for this conversation (the existing `itemsVM`, scope
  defaulting to this chat, picker available). Native paging gives the
  Instagram/X feel and the interactive drag-back for free.
- The tracker page has **no** `NavigationStack` of its own (a nested stack
  inside a pushed destination pops the outer one on iOS 26 — PR #188).
  `onSelect` appends `ItemRoute(id:)` (a new `Hashable` value type) to the
  outer `chatNavigationPath`; `ChatListView` gains
  `.navigationDestination(for: ItemRoute.self) { ItemDetailHost(…) }` next
  to its chat destination. Back returns to the pager on the tasks page.
  `onOpenConversation` from that detail appends the convo id as today.
- Toolbar and title follow the page: on `.tasks` the principal title is
  "Tasks & decisions", the composer is off-screen, and the trailing items
  are the tracker's `+` (create) and ⓘ; on `.chat` everything is as now.
  The checklist button (with its `NeedsYouBadge`) sets `page = .tasks` with
  animation; on the tasks page the same slot shows a `bubble.left` button
  that returns to `.chat`.
- Paging to `.tasks` resigns the composer's first responder. Paging back
  does not re-focus it.
- Gesture rules: the pager only owns horizontal drags; vertical scrolling
  of the timeline and the tracker list is untouched. The system back
  swipe from the leading edge on page 0 takes precedence over the pager
  (UIKit's screen-edge recognizer already wins over a scroll view); this
  is the one thing to verify on the device, not the simulator. The
  create sheet, the item detail, and the composer's slash palette all
  behave as today.
- iPad: the same pager; no split behaviour in this sub-project.
- Existing `itemsVM` lifecycle (`start` in `.task`, `stop` on the outer
  disappear), the `isSupported == false` hide rule for the button, and the
  offline `pendingCreates` rendering are unchanged.

### 5. Mac: big-icon navigation column

`MacChatListView` (`MatronMac/Features/ChatList/MacChatListView.swift`
line ~126) is a two-column `NavigationSplitView`. The sidebar column gains a
leading `MacNavColumn`: a fixed-width (72pt) vertical column of large
icons with labels beneath, in the sidebar's material, separated from the
list by a hairline. Entries: *Conversations* (`bubble.left.and.bubble.right`)
and *Decisions* (`checkmark.circle` with a red count badge at its top
trailing corner, hidden at zero). Selection is `@State var nav: MacNav`
(`enum MacNav { conversations, decisions }`), also settable by ⌘1/⌘2
(added to `MatronMac/App/Commands.swift`).

- **Conversations selected:** the chat list and detail column exactly as
  today, including the per-chat `MacItemsPane` toggle.
- **Decisions selected:** the sidebar list is `DecisionsListView`; the
  detail column shows `MacItemDetailHost` (the detail view `MacItemsPane`
  already pushes) for the selected row, or a placeholder "Select an item".
  *Open conversation* sets `nav = .conversations` and selects that chat.
- The nav column is part of the sidebar column so
  `navigationSplitViewColumnWidth` and the existing sidebar-width tests
  keep their meaning; minimum sidebar width grows by the column's 72pt.
  The macOS 26 toolbar ordering rule in
  `mac_sidebar_width_toolbar_mask` still applies.
- The sidebar toggle stays removed; the nav column is never collapsible.

### 5a. Remove the Make task pill

The floating *Make task* pill above the composer (`MakeTaskPill`, both
platforms) is removed (Dan, 2026-09-09: tasks should mostly be made by
the agent). Filing from the app stays possible through the tracker's `+`
and the queued-message card's *Make task* action; the bang-prefix and
palette-yield rules that governed the pill go with it. Composer layout
reclaims the pill's row.

### 6. Data flow and lifetimes

- One `ItemsPanelViewModel(convoID: nil)` per signed-in session, created by
  the shell (`AppShellView` / `MacChatListView`) and started there; it feeds
  both the Decisions list and the badge. It subscribes to the same
  `JournalStore` items stream the per-chat instances use, so a change made
  from a chat's tracker page shows in Decisions on the next store emit
  without a fetch.
- Per-chat instances (`itemsVM` in `ChatView`, `MacItemsPane`) are
  unchanged.
- Deep links and push-notification taps into a chat: unchanged, plus
  `tab = .conversations` (iOS) / `nav = .conversations` (Mac) first.

### 7. Error handling

- Unsupported journal (404 on items): Decisions shows the unsupported
  message, badge hidden, tab still present. Tasks page button hidden as
  today; the pager still exists but has one page (no swipe target), so the
  swipe does nothing.
- Offline: Decisions renders the local cache; refresh failure surfaces via
  the view model's existing `error` → the same alert the tracker uses.
- An `ItemRoute` for an item that no longer exists renders the detail's
  existing "item not found" state.

### 8. Testing

- **ViewModel (SPM):** `convoID: nil` starts in `.all`; `awaitingYou` filters
  to `needsUser` across conversations, newest first; `awaitingYouCount`
  tracks store emits; `needsYouCount` still per-conversation when
  `convoID` is set.
- **DecisionsListView snapshots** (MatronShared snapshot harness, both
  appearances): populated, empty, unsupported.
- **iOS:** `AppShellView` binding tests — deep-link append switches to
  Conversations; Decisions `onOpenConversation` switches tab and pushes.
  `ChatPager` tests — checklist button sets `.tasks`, return button sets
  `.chat`, `onSelect` appends `ItemRoute` to the outer path (not a local
  stack), first responder resigned on page change (via the existing
  composer focus seam).
- **Mac:** `MacNavColumn` snapshot (badge / no badge); `MacChatListView`
  layout test that the nav column is present and the list still meets its
  minimum width; ⌘1/⌘2 command tests in `MacCommandsTests`.
- **iOS:** the chat destination hides the tab bar (`AppShellView` binding
  test asserting the destination's toolbar visibility for `.tabBar`).
- **Device (manual):** swipe to tasks and back; leading-edge back swipe on
  page 0 still pops; keyboard drops on page change; VoiceOver reads the
  page change; tab bar absent inside a chat and back at the list.

## Rollout

Five PRs on `main`, in this order, each green on its own (1–4 stacked):

0. `remove-make-task-pill` — §5a, independent of the rest; can merge first.
1. `items-vm-all-mode` — §1 view model + `DecisionsListView` (§2) + tests.
2. `ios-shell-tabs` — §3 + Decisions on iOS.
3. `ios-tasks-pager` — §4; deletes `ItemsDrawer`.
4. `mac-nav-column` — §5.

Android follows from the same spec in its own repo.
