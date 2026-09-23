# Mac Navigation History (Back / Forward) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Mac window a browser-style Back/Forward history over every place the user can land on, including the items pane's own pushes and sub-chat opens, with always-present toolbar buttons, ⌘[ / ⌘], and a Go menu.

**Architecture:** A pure `MacNavigationHistory` model records a normalised `MacPlace` snapshot every time the shell's derived "current place" changes (one `onChange` in `MacChatListView`), and restores a popped place by writing the same `@State`s back. The only refactor is hoisting the chat's pane route (items-pane push stack or open sub-chat) out of the per-conversation `MacChatView` into a per-window binding on the shell, replacing today's `itemsPaneOpen: Binding<Bool>`.

**Tech Stack:** Swift 5.10 language mode, SwiftUI + AppKit, `@Observable`, XCTest in `MatronMacTests` (xcodegen-generated `Matron.xcodeproj`, scheme `MatronMac`).

**Spec:** `docs/superpowers/specs/2026-09-23-mac-navigation-history-design.md`

## Global Constraints

- Mac target only (`MatronMac/`, `MatronMacTests/`). No change under `Matron/` (iOS) or `MatronShared/`.
- Commit author must be `Dan Barker <dan@yearbookmachine.com>` (CLA): commit with `git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit …`. Never `git config user.*` inside the worktree.
- Every commit message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Keyboard shortcuts: `⌘[` Back, `⌘]` Forward (macOS standard). No other Matron command uses them.
- History capacity: 50 entries.
- The sidebar toolbar keeps `.toolbar(removing: .sidebarToggle)` BEFORE `.navigationSplitViewColumnWidth(...)` (macOS 26 masks the width otherwise). New toolbar items go inside the existing `.toolbar { }` block that follows both.
- Nothing under the chat header accessory may add toolbar items (PR #228). The Back/Forward buttons live in the SIDEBAR column's toolbar.
- Running `MatronMacTests` MUST set `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE` as an environment variable of the `xcodebuild` process (`env KEY=value xcodebuild …`, never a trailing `KEY=value` argument), or the test host writes into the live journal store.
- Work happens in the worktree `/Users/danbarker/Dev/matron-apple-navhistory` on branch `feat/mac-nav-history` (spec already committed there). Run `xcodegen generate` once before the first `xcodebuild`.

## Review Focus

Inputs the spec implies that no task's tests fully exercise; each gets a pinned test in the owning task where a pure helper allows it, and a manual check in Task 5 otherwise.

1. **Two quick Back presses** before the first restore has re-rendered: the history must move two steps and the window must land on the second place, not the first (Task 1 test `test_goBackTwice_returnsSuccessivePlaces`).
2. **A notification tap or auto-open while the user reads a mission**: Conversations comes forward with the room selected; Back must return to the mission (Task 3 test `test_place_missionsDropsConversationSelection` proves the mission place carried no selection, so the two places differ).
3. **Switching conversations with a sub-chat open**: today the sub-chat closes with the old `MacChatView`; with the route hoisted it must still close (Task 3 test `test_paneRouteAfter_switchClearsASubChat`).
4. **Back onto a conversation while search results cover the detail column**: the results panel must not stay over the restored chat (Task 5 manual check; `restore` clears the query exactly as `showConversation` does).
5. **Back onto a conversation that has since left the list**: the detail shows "Select a chat"; the history entry is kept and Forward still works (Task 5 manual check).

---

### Task 1: Pane route, place and history model

**Files:**
- Create: `MatronMac/Features/Nav/MacNavigationHistory.swift`
- Test: `MatronMacTests/MacNavigationHistoryTests.swift`

**Interfaces:**
- Consumes: `MacNav` (`MatronMac/Features/Nav/MacNavColumn.swift`).
- Produces (used by Tasks 2–4):
  - `enum MacChatPaneRoute: Equatable { case items(path: [String]); case subChat(id: String) }` with `var isItems: Bool`, `var itemsPath: [String]?`, `var subChatID: String?`, `static func from(itemsOpen: Bool, path: [String], subChatID: String?) -> MacChatPaneRoute?`.
  - `struct MacPlace: Equatable { enum Detail: Equatable { case coordinator(pane: MacChatPaneRoute?); case conversation(id: String?, pane: MacChatPaneRoute?); case mission(id: String?); case decision(id: String?) }; var detail: Detail; var nav: MacNav; var pane: MacChatPaneRoute?; func displayedConversationID(coordinatorConvoID: String?) -> String? }`.
  - `@MainActor @Observable final class MacNavigationHistory { static let capacity = 50; private(set) var current: MacPlace?; private(set) var back: [MacPlace]; private(set) var forward: [MacPlace]; var canGoBack: Bool; var canGoForward: Bool; func visit(_ place: MacPlace); func goBack() -> MacPlace?; func goForward() -> MacPlace? }`.

- [ ] **Step 1: Write the failing tests**

Create `MatronMacTests/MacNavigationHistoryTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import MatronMac

/// The pure history model behind the window's Back/Forward (spec §2) and
/// the pane-route helper the chat view syncs through (spec §3).
@MainActor
final class MacNavigationHistoryTests: XCTestCase {
    private let a = MacPlace(detail: .conversation(id: "c1", pane: nil))
    private let b = MacPlace(detail: .mission(id: "m1"))
    private let c = MacPlace(detail: .decision(id: "it_9"))

    func test_empty_hasNothingToGoTo() {
        let history = MacNavigationHistory()
        XCTAssertNil(history.current)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())
    }

    func test_visit_recordsThePreviousPlaceAndClearsForward() {
        let history = MacNavigationHistory()
        history.visit(a)
        XCTAssertEqual(history.current, a)
        XCTAssertFalse(history.canGoBack, "the first place has nothing before it")
        history.visit(b)
        XCTAssertEqual(history.back, [a])
        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.goBack(), a)
        XCTAssertEqual(history.forward, [b])
        // A new branch drops forward, as in a browser.
        history.visit(c)
        XCTAssertEqual(history.forward, [])
        XCTAssertEqual(history.back, [a])
        XCTAssertEqual(history.current, c)
    }

    func test_visitingTheCurrentPlace_isANoOp() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        history.visit(b)
        XCTAssertEqual(history.back, [a])
        XCTAssertEqual(history.current, b)
    }

    /// The contract the shell relies on: `goBack` sets `current` to the
    /// returned place BEFORE the shell restores it, so the restore's own
    /// `visit` of that place records nothing.
    func test_goBack_setsCurrent_soRestoringDoesNotRecord() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        let restored = history.goBack()
        XCTAssertEqual(restored, a)
        XCTAssertEqual(history.current, a)
        history.visit(a)   // the shell's onChange after restoring
        XCTAssertEqual(history.back, [], "restoring must not push")
        XCTAssertEqual(history.forward, [b], "restoring must not drop forward")
    }

    func test_goForward_roundTrips() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        _ = history.goBack()
        XCTAssertEqual(history.goForward(), b)
        XCTAssertEqual(history.current, b)
        XCTAssertEqual(history.back, [a])
        XCTAssertFalse(history.canGoForward)
    }

    /// Review focus 1: two presses before any re-render walk two steps.
    func test_goBackTwice_returnsSuccessivePlaces() {
        let history = MacNavigationHistory()
        history.visit(a)
        history.visit(b)
        history.visit(c)
        XCTAssertEqual(history.goBack(), b)
        XCTAssertEqual(history.goBack(), a)
        XCTAssertEqual(history.forward, [c, b])
        XCTAssertNil(history.goBack())
    }

    func test_capacity_dropsTheOldest() {
        let history = MacNavigationHistory()
        for i in 0...(MacNavigationHistory.capacity + 5) {
            history.visit(MacPlace(detail: .conversation(id: "c\(i)", pane: nil)))
        }
        XCTAssertEqual(history.back.count, MacNavigationHistory.capacity)
        XCTAssertEqual(history.back.first, MacPlace(detail: .conversation(id: "c5", pane: nil)))
    }

    // MARK: Pane route helper

    func test_paneRouteFrom_subChatWins_thenItems_thenNil() {
        XCTAssertEqual(MacChatPaneRoute.from(itemsOpen: true, path: ["it_1"], subChatID: "s1"), .subChat(id: "s1"))
        XCTAssertEqual(MacChatPaneRoute.from(itemsOpen: true, path: ["it_1"], subChatID: nil), .items(path: ["it_1"]))
        XCTAssertEqual(MacChatPaneRoute.from(itemsOpen: false, path: ["it_1"], subChatID: nil), nil)
    }

    func test_place_navAndPaneAccessors() {
        let route = MacChatPaneRoute.items(path: ["it_1"])
        XCTAssertEqual(MacPlace(detail: .coordinator(pane: route)).nav, .coordinator)
        XCTAssertEqual(MacPlace(detail: .coordinator(pane: route)).pane, route)
        XCTAssertEqual(MacPlace(detail: .conversation(id: "c1", pane: route)).nav, .conversations)
        XCTAssertEqual(MacPlace(detail: .mission(id: nil)).nav, .missions)
        XCTAssertNil(MacPlace(detail: .mission(id: nil)).pane)
        XCTAssertEqual(MacPlace(detail: .decision(id: "d")).nav, .decisions)
    }

    func test_place_displayedConversation() {
        XCTAssertEqual(MacPlace(detail: .conversation(id: "c1", pane: nil)).displayedConversationID(coordinatorConvoID: "k"), "c1")
        XCTAssertEqual(MacPlace(detail: .coordinator(pane: nil)).displayedConversationID(coordinatorConvoID: "k"), "k")
        XCTAssertNil(MacPlace(detail: .coordinator(pane: nil)).displayedConversationID(coordinatorConvoID: nil))
        XCTAssertNil(MacPlace(detail: .mission(id: "m")).displayedConversationID(coordinatorConvoID: "k"))
        XCTAssertNil(MacPlace(detail: .conversation(id: nil, pane: nil)).displayedConversationID(coordinatorConvoID: "k"))
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run (from the worktree root):

```bash
xcodegen generate
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
  xcodebuild test -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:MatronMacTests/MacNavigationHistoryTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -8
```

Expected: compile errors `cannot find 'MacNavigationHistory' in scope`, `cannot find 'MacPlace' in scope`.

- [ ] **Step 3: Write the model**

Create `MatronMac/Features/Nav/MacNavigationHistory.swift`:

```swift
import Foundation
import Observation

/// What the chat detail shows beside (or instead of) the timeline (spec
/// §1). Hoisted to the shell per window so it is part of a place and
/// survives the per-conversation `MacChatView` being torn down.
enum MacChatPaneRoute: Equatable {
    /// The tasks-and-decisions pane is open; `path` is its push stack
    /// (empty = the list).
    case items(path: [String])
    /// A subagent child open in the split pane.
    case subChat(id: String)

    var isItems: Bool {
        if case .items = self { return true }
        return false
    }

    var itemsPath: [String]? {
        if case .items(let path) = self { return path }
        return nil
    }

    var subChatID: String? {
        if case .subChat(let id) = self { return id }
        return nil
    }

    /// The route the chat view's three local states describe. The two
    /// panes share one slot — opening either closes the other — so a
    /// sub-chat wins when both are set mid-transaction.
    static func from(itemsOpen: Bool, path: [String], subChatID: String?) -> MacChatPaneRoute? {
        if let subChatID { return .subChat(id: subChatID) }
        return itemsOpen ? .items(path: path) : nil
    }
}

/// Where the user is in a window (spec §1): the shell's selection state,
/// normalised so fields that do not apply to the selected nav entry are
/// absent and cannot mint a spurious history entry.
struct MacPlace: Equatable {
    enum Detail: Equatable {
        case coordinator(pane: MacChatPaneRoute?)
        /// `nil` id is the "Select a chat" empty state.
        case conversation(id: String?, pane: MacChatPaneRoute?)
        case mission(id: String?)
        case decision(id: String?)
    }

    var detail: Detail

    var nav: MacNav {
        switch detail {
        case .coordinator: return .coordinator
        case .conversation: return .conversations
        case .mission: return .missions
        case .decision: return .decisions
        }
    }

    var pane: MacChatPaneRoute? {
        switch detail {
        case .coordinator(let pane): return pane
        case .conversation(_, let pane): return pane
        case .mission, .decision: return nil
        }
    }

    /// The conversation the chat detail is showing at this place, if any:
    /// the coordinator's own conversation under the Coordinator entry.
    func displayedConversationID(coordinatorConvoID: String?) -> String? {
        switch detail {
        case .coordinator:
            guard let coordinatorConvoID, !coordinatorConvoID.isEmpty else { return nil }
            return coordinatorConvoID
        case .conversation(let id, _): return id
        case .mission, .decision: return nil
        }
    }
}

/// The window's Back/Forward history (spec §2). Pure: the shell reports
/// every place it lands on through `visit`, and restores what `goBack` /
/// `goForward` return. Both set `current` to the returned place BEFORE
/// the shell restores it, so the restore's own `visit` is a no-op and no
/// "restoring" flag is needed. Only `canGoBack` / `canGoForward` are read
/// from SwiftUI bodies (the two buttons); everything else is written from
/// `onChange` handlers.
@MainActor
@Observable
final class MacNavigationHistory {
    static let capacity = 50

    private(set) var current: MacPlace?
    private(set) var back: [MacPlace] = []
    private(set) var forward: [MacPlace] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// No-op when `place` is already current. Otherwise the current place
    /// moves onto `back`, `forward` is dropped (a new branch, as in a
    /// browser) and `back` is capped at `capacity`.
    func visit(_ place: MacPlace) {
        guard place != current else { return }
        if let current {
            back.append(current)
            if back.count > Self.capacity { back.removeFirst(back.count - Self.capacity) }
        }
        forward.removeAll()
        current = place
    }

    /// The place to restore, or `nil` with nothing to go back to.
    func goBack() -> MacPlace? {
        guard let previous = back.popLast() else { return nil }
        if let current { forward.append(current) }
        current = previous
        return previous
    }

    /// The place to restore, or `nil` with nothing to go forward to.
    func goForward() -> MacPlace? {
        guard let next = forward.popLast() else { return nil }
        if let current { back.append(current) }
        current = next
        return next
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same command as Step 2. Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Nav/MacNavigationHistory.swift MatronMacTests/MacNavigationHistoryTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "nav(mac): pane route, place and history model for Back/Forward (spec 2026-09-23)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Hoist the chat pane route to a binding

**Files:**
- Modify: `MatronMac/Features/Chat/MacChatView.swift` (the `itemsPaneOpen` binding at lines 46–62; the outer view's modifier chain next to `.trackerItemLinks(…)` around line 548)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift:61` (`itemsPaneOpen` state), `:855-885` (`chatDetail`), `:1112-1125` (`MacChatDetailGate.Key`)
- Modify: `MatronMacTests/MacPaneSplitMeasureTests.swift:101`, `MatronMacTests/MacItemsPaneLayoutTests.swift:145,191`
- Test: `MatronMacTests/MacChatViewTests.swift` (add two tests)

**Deviation from spec §8, on purpose:** the spec lists a `MacChatViewTests` mount test ("a `.items(path: ["it_9"])` route mounts with that path on its pane state"). Mounting a pushed item needs `AppDependencies.makeItemDetailViewModel` against a real session, which the existing layout suites avoid by mounting with an EMPTY path. So the shell → local mapping is pinned as a pure helper (`localState(applying:…)`) and the mount itself by the two existing layout suites, which keep mounting `MacChatView` with `.items(path: [])` and would fail if the proxy stopped opening the pane. The local → shell write is covered by the manual pass (Task 5, check 2).

**Interfaces:**
- Consumes: `MacChatPaneRoute` (Task 1).
- Produces: `MacChatView.paneRoute: Binding<MacChatPaneRoute?>` (default `.constant(nil)`), `static func MacChatView.localState(applying route: MacChatPaneRoute?, path: [String], subChatID: String?) -> (path: [String], subChatID: String?)`, `MacChatDetailGate.Key.paneRoute: MacChatPaneRoute?`. Task 3 passes `$paneRoute` from the shell.

- [ ] **Step 1: Write the failing tests**

Append inside `final class MacChatViewTests` in `MatronMacTests/MacChatViewTests.swift` (before its closing brace, after `test_view_compiles_withChatViewModel_andComposerViewModel`):

```swift
    /// Spec §3, shell → local: a restored route lands on the chat view's
    /// local states; a route the local states already describe changes
    /// nothing (so the local → shell echo cannot loop).
    func test_localState_appliesARouteFromTheShell() {
        let pushed = MacChatView.localState(applying: .items(path: ["it_9"]), path: [], subChatID: "s1")
        XCTAssertEqual(pushed.path, ["it_9"])
        XCTAssertNil(pushed.subChatID, "the items pane and a sub-chat share one slot")

        let child = MacChatView.localState(applying: .subChat(id: "s2"), path: ["it_9"], subChatID: nil)
        XCTAssertEqual(child.subChatID, "s2")
        XCTAssertEqual(child.path, ["it_9"], "closing the pane keeps its stack for a later reopen, as today")

        let closed = MacChatView.localState(applying: nil, path: ["it_9"], subChatID: "s2")
        XCTAssertNil(closed.subChatID)
        XCTAssertEqual(closed.path, ["it_9"])

        let same = MacChatView.localState(applying: .items(path: ["it_9"]), path: ["it_9"], subChatID: nil)
        XCTAssertEqual(same.path, ["it_9"])
        XCTAssertNil(same.subChatID)
    }

    /// The binding replaces the old `itemsPaneOpen` Bool and defaults to
    /// "no pane", so previews and tests build without a route.
    func test_view_defaultsToNoPaneRoute() {
        let timeline = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(roomID: "!test:s", timeline: timeline, commands: [])
        let stripVM = SubChatStripViewModel(chat: FakeChatForSubStrip(), parentConvoID: "!r:s")
        let view = MacChatView(
            viewModel: chatVM, composerVM: composerVM, stripViewModel: stripVM,
            subChatProvider: { _ in (chatVM, stripVM) }, chatTitle: "Hello")
        XCTAssertNil(view.paneRoute.wrappedValue)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
  xcodebuild test -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:MatronMacTests/MacChatViewTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -8
```

Expected: compile errors `type 'MacChatView' has no member 'localState'` and `value of type 'MacChatView' has no member 'paneRoute'`.

- [ ] **Step 3: Replace the Bool binding in `MacChatView`**

In `MatronMac/Features/Chat/MacChatView.swift`, replace lines 47–62 (from the `/// Whether the tasks-and-decisions pane (Task 10) is open.` doc comment through the `showItemsPane` computed property) with:

```swift
    /// The pane route — the tasks-and-decisions pane with its push stack,
    /// or an open sub-chat — hoisted to `MacChatListView` per WINDOW (spec
    /// 2026-09-23 §3): `MacChatView` is torn down and rebuilt per
    /// conversation (`.id(id)` in `MacChatListView.chatDetail`), so state
    /// held here would reset on every switch, and the window's Back/Forward
    /// history records and restores this route as part of a place. The
    /// caller's binding; default `.constant(nil)` keeps every other call
    /// site (tests, previews) compiling unchanged. `openSubChatID` and
    /// `itemsPaneState` stay the LOCAL source of truth every existing
    /// read/write site uses; the two `onChange`s on the outer view keep
    /// them and this binding in step both ways.
    var paneRoute: Binding<MacChatPaneRoute?> = .constant(nil)
    /// Whether the tasks-and-decisions pane is open — a proxy over the
    /// route, so every read/write site below is unchanged. Setting `true`
    /// opens the pane on its current local stack; setting `false` closes
    /// it and leaves a `.subChat` route alone (the sub-chat sites clear
    /// `openSubChatID` themselves).
    private var showItemsPane: Bool {
        get { paneRoute.wrappedValue?.isItems ?? false }
        nonmutating set {
            let isItems = paneRoute.wrappedValue?.isItems ?? false
            if newValue, !isItems {
                paneRoute.wrappedValue = .items(path: itemsPaneState.path)
            } else if !newValue, isItems {
                paneRoute.wrappedValue = nil
            }
        }
    }
    /// The route this view's local states describe (`MacChatPaneRoute.from`).
    /// Observed by the local → shell `onChange`.
    private var localRoute: MacChatPaneRoute? {
        MacChatPaneRoute.from(itemsOpen: showItemsPane, path: itemsPaneState.path, subChatID: openSubChatID)
    }
```

Then add, just above `@MainActor private func openTrackerItem(num: Int)` (around line 395):

```swift
    /// Shell → local (spec §3): the local states a route from the shell
    /// should produce. Pure so the mapping is testable without a window.
    /// A `.items` route clears an open sub-chat (shared slot) and sets the
    /// pane's stack; a `.subChat` route opens that child and keeps the
    /// pane's stack for a later reopen, as closing the pane does today;
    /// `nil` closes the sub-chat. Unchanged values are returned as-is so
    /// applying the route a local change just reported is a no-op.
    static func localState(applying route: MacChatPaneRoute?, path: [String], subChatID: String?)
        -> (path: [String], subChatID: String?) {
        switch route {
        case .items(let newPath): return (newPath, nil)
        case .subChat(let id): return (path, id)
        case nil: return (path, nil)
        }
    }

    private func applyPaneRoute(_ route: MacChatPaneRoute?) {
        let next = Self.localState(applying: route, path: itemsPaneState.path, subChatID: openSubChatID)
        if openSubChatID != next.subChatID { openSubChatID = next.subChatID }
        if itemsPaneState.path != next.path { itemsPaneState.path = next.path }
    }
```

Then, on the stable OUTER view, directly after the `.trackerItemLinks(itemLinkRelay, resolve: …, open: { showItem($0) })` modifier (around line 548), add:

```swift
        // Pane route sync (spec 2026-09-23 §3). Local → shell: a push, a
        // pop, a sub-chat open/close, or the ⇧⌘I toggle re-derives
        // `localRoute` and writes the window's binding, which the history
        // records. Shell → local: a Back/Forward restore onto THIS
        // conversation writes the binding and lands here; `initial: true`
        // seeds a freshly mounted chat from a restored route before any
        // local change can report a transient empty stack. Each direction
        // only writes what differs, so the echo of its own write is a no-op.
        .onChange(of: localRoute) { _, route in
            if paneRoute.wrappedValue != route { paneRoute.wrappedValue = route }
        }
        .onChange(of: paneRoute.wrappedValue, initial: true) { _, route in
            applyPaneRoute(route)
        }
```

- [ ] **Step 4: Update the shell's binding, the gate key and the three test call sites**

In `MatronMac/Features/ChatList/MacChatListView.swift`:

Replace lines 54–61 (the `itemsPaneOpen` doc comment and declaration) with:

```swift
    /// The chat detail's pane route — the tasks-and-decisions pane with
    /// its push stack, or an open sub-chat — per WINDOW (spec 2026-09-23
    /// §3). Lives HERE, not in `MacChatView` (which is `.id(id)`-keyed per
    /// selection and torn down on every conversation switch), so it
    /// survives a switch and is part of the place the Back/Forward
    /// history records. `MacChatView` keeps its local states in step
    /// through the binding. (Replaces the I5-era `itemsPaneOpen` Bool.)
    @State private var paneRoute: MacChatPaneRoute?
```

In `chatDetail(for:)`, change the gate key argument `itemsPaneOpen: itemsPaneOpen` to `paneRoute: paneRoute`, and the `MacChatView(` argument

```swift
                itemsPaneOpen: $itemsPaneOpen,
```

to

```swift
                // Spec 2026-09-23 §3: hoisted here so the pane's route
                // survives a conversation switch and the history can
                // restore it — see `paneRoute`'s declaration above.
                paneRoute: $paneRoute,
```

In `MacChatDetailGate.Key`, replace the `itemsPaneOpen` field and its comment with:

```swift
        /// The pane route reaches `MacChatView` as a `Binding`, which
        /// tracks its source on its own; carried here as well so the gate
        /// never depends on that.
        let paneRoute: MacChatPaneRoute?
```

In the tests, replace every `itemsPaneOpen: .constant(true)` with `paneRoute: .constant(.items(path: []))`:

- `MatronMacTests/MacItemsPaneLayoutTests.swift:145` and `:191`.

And in `MatronMacTests/MacPaneSplitMeasureTests.swift:101` replace `itemsPaneOpen: .constant(paneOpen)` with `paneRoute: .constant(paneOpen ? .items(path: []) : nil)`.

- [ ] **Step 5: Build and run the tests to verify they pass**

```bash
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
  xcodebuild test -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:MatronMacTests/MacChatViewTests -only-testing:MatronMacTests/MacItemsPaneLayoutTests \
  -only-testing:MatronMacTests/MacPaneSplitMeasureTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -8
```

Expected: `BUILD SUCCEEDED` and the three suites report `0 failures` (the layout suites are the ones that mount `MacChatView` with the pane open; they prove the proxy still opens it).

- [ ] **Step 6: Commit**

```bash
git add MatronMac/Features/Chat/MacChatView.swift MatronMac/Features/ChatList/MacChatListView.swift \
  MatronMacTests/MacChatViewTests.swift MatronMacTests/MacItemsPaneLayoutTests.swift MatronMacTests/MacPaneSplitMeasureTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "nav(mac): hoist the chat pane route (items stack / sub-chat) to a per-window binding (spec §3)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: The shell records places, restores them, and shows the buttons

**Files:**
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (state near line 61; `splitView` toolbar around lines 270–305; `withCommandListeners` around line 330–420; helpers near `showDecisionsItem` at line 682)
- Test: `MatronMacTests/MacNavigationShellTests.swift` (new)

**Interfaces:**
- Consumes: `MacNavigationHistory`, `MacPlace`, `MacChatPaneRoute` (Task 1); `paneRoute` state (Task 2).
- Produces: `static func MacChatListView.place(nav:selectedSummaryID:selectedMissionID:selectedDecisionID:paneRoute:) -> MacPlace`; `static func MacChatListView.paneRoute(after:previous:current:coordinatorConvoID:) -> MacChatPaneRoute?`; private `goBack()` / `goForward()` used by Task 4's listeners.

- [ ] **Step 1: Write the failing tests**

Create `MatronMacTests/MacNavigationShellTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import MatronMac

/// The shell's side of the history (spec §1, §3, §4): the normalised
/// place it derives from its state, and the pane-route reset that keeps
/// today's "switching conversations shows the new chat's list" behaviour
/// without wiping a restored route. Pure helpers, `MacMissionsNavTests`
/// style — `MacChatListView`'s state is private.
final class MacNavigationShellTests: XCTestCase {
    private let route = MacChatPaneRoute.items(path: ["it_9"])

    func test_place_conversationsCarriesSelectionAndRoute() {
        let place = MacChatListView.place(nav: .conversations, selectedSummaryID: "c1", selectedMissionID: "m1",
                                          selectedDecisionID: "d1", paneRoute: route)
        XCTAssertEqual(place, MacPlace(detail: .conversation(id: "c1", pane: route)))
    }

    /// Review focus 2: an auto-open changes the Conversations selection
    /// while the user reads a mission; the mission place must not carry it,
    /// so the two places differ and Back returns to the mission.
    func test_place_missionsDropsConversationSelection() {
        let before = MacChatListView.place(nav: .missions, selectedSummaryID: "c1", selectedMissionID: "m1",
                                           selectedDecisionID: nil, paneRoute: route)
        let after = MacChatListView.place(nav: .missions, selectedSummaryID: "c2", selectedMissionID: "m1",
                                          selectedDecisionID: nil, paneRoute: route)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before, MacPlace(detail: .mission(id: "m1")))
    }

    func test_place_decisionsAndCoordinator() {
        XCTAssertEqual(MacChatListView.place(nav: .decisions, selectedSummaryID: "c1", selectedMissionID: nil,
                                             selectedDecisionID: "d1", paneRoute: route),
                       MacPlace(detail: .decision(id: "d1")))
        XCTAssertEqual(MacChatListView.place(nav: .coordinator, selectedSummaryID: "c1", selectedMissionID: nil,
                                             selectedDecisionID: nil, paneRoute: route),
                       MacPlace(detail: .coordinator(pane: route)))
    }

    /// "Select a chat" has no pane on screen, so the per-window route is
    /// not part of that place.
    func test_place_emptyConversationSelectionDropsTheRoute() {
        XCTAssertEqual(MacChatListView.place(nav: .conversations, selectedSummaryID: nil, selectedMissionID: nil,
                                             selectedDecisionID: nil, paneRoute: route),
                       MacPlace(detail: .conversation(id: nil, pane: nil)))
    }

    // MARK: Route reset on a conversation switch (spec §3)

    func test_paneRouteAfter_switchResetsAPushedPaneToTheList() {
        let from = MacPlace(detail: .conversation(id: "c1", pane: route))
        let to = MacPlace(detail: .conversation(id: "c2", pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: to, previous: from, current: route, coordinatorConvoID: nil),
                       .items(path: []))
    }

    /// Review focus 3.
    func test_paneRouteAfter_switchClearsASubChat() {
        let child = MacChatPaneRoute.subChat(id: "s1")
        let from = MacPlace(detail: .conversation(id: "c1", pane: child))
        let to = MacPlace(detail: .conversation(id: "c2", pane: child))
        XCTAssertNil(MacChatListView.paneRoute(after: to, previous: from, current: child, coordinatorConvoID: nil))
    }

    func test_paneRouteAfter_switchKeepsAnOpenListAndAClosedPane() {
        let from = MacPlace(detail: .conversation(id: "c1", pane: .items(path: [])))
        let to = MacPlace(detail: .conversation(id: "c2", pane: .items(path: [])))
        XCTAssertEqual(MacChatListView.paneRoute(after: to, previous: from, current: .items(path: []), coordinatorConvoID: nil),
                       .items(path: []))
        let closedFrom = MacPlace(detail: .conversation(id: "c1", pane: nil))
        let closedTo = MacPlace(detail: .conversation(id: "c2", pane: nil))
        XCTAssertNil(MacChatListView.paneRoute(after: closedTo, previous: closedFrom, current: nil, coordinatorConvoID: nil))
    }

    /// A restore: the history's current place already IS the place being
    /// landed on, so the route it carries is kept.
    func test_paneRouteAfter_restoreKeepsTheRestoredRoute() {
        let restored = MacPlace(detail: .conversation(id: "c2", pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: restored, previous: restored, current: route, coordinatorConvoID: nil),
                       route)
    }

    /// Leaving the chat for Missions and coming back is a conversation
    /// change (nil → c1) and resets like a click; a nav-only move away
    /// leaves the per-window route untouched.
    func test_paneRouteAfter_nonChatPlacesLeaveTheRouteAlone() {
        let chat = MacPlace(detail: .conversation(id: "c1", pane: route))
        let mission = MacPlace(detail: .mission(id: "m1"))
        XCTAssertEqual(MacChatListView.paneRoute(after: mission, previous: chat, current: route, coordinatorConvoID: nil), route)
        XCTAssertEqual(MacChatListView.paneRoute(after: chat, previous: mission, current: route, coordinatorConvoID: nil),
                       .items(path: []))
    }

    /// The coordinator's own conversation is a displayed conversation too:
    /// moving between it and another chat resets exactly like a click.
    func test_paneRouteAfter_coordinatorCountsAsAConversation() {
        let coord = MacPlace(detail: .coordinator(pane: route))
        let chat = MacPlace(detail: .conversation(id: "c1", pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: chat, previous: coord, current: route, coordinatorConvoID: "k"),
                       .items(path: []))
        let coordAgain = MacPlace(detail: .coordinator(pane: route))
        XCTAssertEqual(MacChatListView.paneRoute(after: coordAgain, previous: coord, current: route, coordinatorConvoID: "k"),
                       route, "same place, no change")
    }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
  xcodebuild test -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:MatronMacTests/MacNavigationShellTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -8
```

Expected: compile errors `type 'MacChatListView' has no member 'place'` / `'paneRoute'`.

- [ ] **Step 3: Add the history state and the pure helpers**

In `MatronMac/Features/ChatList/MacChatListView.swift`, directly after the `@State private var paneRoute: MacChatPaneRoute?` declaration (Task 2), add:

```swift
    /// The window's Back/Forward history (spec 2026-09-23 §2, §4). Fed by
    /// `recordPlace` from the `onChange` on `currentPlace`; read from the
    /// body only through `canGoBack` / `canGoForward` (the two buttons).
    @State private var history = MacNavigationHistory()
```

Directly after `static func sidebarWidths(for nav: MacNav)` (around line 196), add:

```swift
    /// The place the shell's state describes (spec §1), normalised: only
    /// the fields the selected nav entry shows are carried, so a change
    /// to something off-screen (an auto-open moving the Conversations
    /// selection while a mission is read) is not a new place. "Select a
    /// chat" (`nil` selection) shows no pane, so it carries no route.
    static func place(nav: MacNav, selectedSummaryID: String?, selectedMissionID: String?,
                      selectedDecisionID: String?, paneRoute: MacChatPaneRoute?) -> MacPlace {
        switch nav {
        case .coordinator:
            return MacPlace(detail: .coordinator(pane: paneRoute))
        case .conversations:
            return MacPlace(detail: .conversation(id: selectedSummaryID, pane: selectedSummaryID == nil ? nil : paneRoute))
        case .missions:
            return MacPlace(detail: .mission(id: selectedMissionID))
        case .decisions:
            return MacPlace(detail: .decision(id: selectedDecisionID))
        }
    }

    /// The pane route the window should carry after landing on `place`
    /// from `previous` — the history's current place before this change
    /// (spec §3). Today switching conversations with the pane open shows
    /// the NEW chat's list (the old `MacChatView` took its stack with it),
    /// and closes a sub-chat (a child belongs to its parent); with the
    /// route hoisted, this is where that happens. A restore must NOT be
    /// reset: `goBack`/`goForward` set the history's current place before
    /// the shell restores it, so `place == previous` is exactly "this is
    /// a restore (or nothing changed)" and the route is kept. Places that
    /// show no chat leave the per-window route alone.
    static func paneRoute(after place: MacPlace, previous: MacPlace?, current: MacChatPaneRoute?,
                          coordinatorConvoID: String?) -> MacChatPaneRoute? {
        guard place != previous else { return current }
        guard let shown = place.displayedConversationID(coordinatorConvoID: coordinatorConvoID) else { return current }
        let before = previous?.displayedConversationID(coordinatorConvoID: coordinatorConvoID)
        guard shown != before else { return current }
        switch current {
        case .items(let path) where !path.isEmpty: return .items(path: [])
        case .subChat: return nil
        default: return current
        }
    }

    private var currentPlace: MacPlace {
        Self.place(nav: nav, selectedSummaryID: selectedSummaryID, selectedMissionID: selectedMissionID,
                   selectedDecisionID: selectedDecisionID, paneRoute: paneRoute)
    }
```

Directly after `private func showDecisionsItem(_ id: String, switchingNav: Bool = false)` (around line 686), add:

```swift
    /// Every place change lands here (the `onChange` on `currentPlace`).
    /// First the conversation-switch route reset (spec §3): if it changes
    /// the route, the place changes with it and the NEXT `onChange` is the
    /// one that records — so a click onto a new chat with a pushed pane
    /// records the list, never the transient pushed state. Otherwise the
    /// place is recorded; a restore's own landing is a no-op inside
    /// `visit`.
    private func recordPlace(_ place: MacPlace) {
        let route = Self.paneRoute(after: place, previous: history.current, current: paneRoute,
                                   coordinatorConvoID: coordinatorConvoID)
        if route != paneRoute {
            paneRoute = route
            return
        }
        history.visit(place)
    }

    /// Writes a popped place back into the shell's state (spec §4). Direct
    /// assignments, not `showConversation` — the place already says which
    /// entry it was under — keeping the two side effects that protect other
    /// state: a decision's recording guard, and the search-query clear so
    /// the results panel cannot stay over a restored chat.
    private func restore(_ place: MacPlace) {
        switch place.detail {
        case .coordinator(let pane):
            nav = .coordinator
            paneRoute = pane
        case .conversation(let id, let pane):
            nav = .conversations
            if searchQueryIsEmpty == false { searchModel?.query = "" }
            selectedSummaryID = id
            paneRoute = pane
        case .mission(let id):
            // A restored page offers no "back to the conversation": the
            // global Back covers that now (spec §4).
            missionBackConvoID = nil
            selectedMissionID = id
            nav = .missions
        case .decision(let id):
            if let id { decisionsPaneState.cancelRecordingIfNavigating(to: id) }
            selectedDecisionID = id
            nav = .decisions
        }
    }

    private func goBack() {
        guard let place = history.goBack() else { return }
        restore(place)
    }

    private func goForward() {
        guard let place = history.goForward() else { return }
        restore(place)
    }
```

- [ ] **Step 4: Observe the place and add the toolbar buttons**

In `withCommandListeners`, directly after the `.onChange(of: nav, navChanged)` line, add:

```swift
            // Spec 2026-09-23 §4: every way of moving between places ends in
            // one of the states `currentPlace` derives from, so this single
            // observer records them all — clicks, ⌘1/2/3, notification taps,
            // search hits, item links, milestone jumps, pane pushes and pops.
            // `initial: true` seeds the history with the first place so the
            // first move away has somewhere to go back to.
            .onChange(of: currentPlace, initial: true) { _, place in recordPlace(place) }
```

In `splitView`, inside the sidebar's `.toolbar { … }` block, directly BEFORE the `#if compiler(>=6.2)` spacer block, add:

```swift
                    // Spec 2026-09-23 §5: the window's Back/Forward, at the
                    // top-left where Finder and Safari keep theirs, in the
                    // SIDEBAR section — the chat header accessory must not
                    // gain toolbar items (PR #228). Always present; greyed
                    // when there is nothing to go to.
                    ToolbarItemGroup(placement: .navigation) {
                        Button { goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!history.canGoBack)
                            .help("Back")
                            .accessibilityLabel("Back")
                        Button { goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!history.canGoForward)
                            .help("Forward")
                            .accessibilityLabel("Forward")
                    }
```

- [ ] **Step 5: Build and run the tests to verify they pass**

```bash
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
  xcodebuild test -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:MatronMacTests/MacNavigationShellTests -only-testing:MatronMacTests/MacSidebarWidthTests \
  -only-testing:MatronMacTests/MacMissionsNavTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -8
```

Expected: `BUILD SUCCEEDED`; `MacNavigationShellTests` executes 10 tests with 0 failures; the sidebar-width and missions-nav suites still pass (the new toolbar group must not disturb the width modifier order).

If `body` fails to type-check in reasonable time (CI runs Xcode 16.4 with a smaller budget than local): move the `ToolbarItemGroup` into a `private var historyToolbarItems: some ToolbarContent` computed property and reference it from the block.

- [ ] **Step 6: Commit**

```bash
git add MatronMac/Features/ChatList/MacChatListView.swift MatronMacTests/MacNavigationShellTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "nav(mac): record every place, restore on Back/Forward, toolbar buttons (spec §4, §5)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: ⌘[ / ⌘] and the Go menu

**Files:**
- Modify: `MatronMac/App/Commands.swift` (the `MatronCommand` enum at lines 12–26; the `ChatCommands` body at lines 60–105; the listener-wiring doc comment at lines 43–52)
- Modify: `MatronMac/Features/ChatList/MacChatListView.swift` (`withCommandListeners`, next to the ⌘1/⌘2/⌘3 listeners)
- Test: `MatronMacTests/MacCommandsTests.swift`

**Interfaces:**
- Consumes: `goBack()` / `goForward()` (Task 3).
- Produces: `MatronCommand.goBack`, `MatronCommand.goForward`.

- [ ] **Step 1: Write the failing tests**

In `MatronMacTests/MacCommandsTests.swift`, add `.goBack, .goForward,` to the `triggers` array in `test_allCases_includes_phase2_set` (after `.showDecisions,`), and add after `test_post_showDecisions_notifiesObserver`:

```swift
    /// Spec 2026-09-23 §5: ⌘[ / ⌘] and the Go menu post the window's
    /// Back/Forward over the same bus as ⌘1/⌘2/⌘3.
    func test_post_goBackAndGoForward_notifyObservers() {
        for command in [MatronCommand.goBack, .goForward] {
            let exp = expectation(description: "\(command) observed")
            let observer = NotificationCenter.default.addObserver(
                forName: .matronCommand(command), object: nil, queue: nil
            ) { _ in exp.fulfill() }
            NotificationCenter.default.post(name: .matronCommand(command), object: nil)
            wait(for: [exp], timeout: 1)
            NotificationCenter.default.removeObserver(observer)
        }
        XCTAssertNotEqual(Notification.Name.matronCommand(.goBack), .matronCommand(.goForward))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
  xcodebuild test -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:MatronMacTests/MacCommandsTests 2>&1 | grep -E "error:|Executed|BUILD" | tail -8
```

Expected: compile error `type 'MatronCommand' has no member 'goBack'`.

- [ ] **Step 3: Add the commands, the menu and the listeners**

In `MatronMac/App/Commands.swift`, after `case showDecisions` in the enum add:

```swift
    /// Navigation history (spec 2026-09-23 §5): the Go menu's Back / Forward,
    /// ⌘[ / ⌘].
    case goBack
    case goForward
```

In the listener-wiring doc comment, after the `.showCoordinator/...` line add:

```swift
///   - `.goBack/.goForward`  — `MacChatListView` (window navigation history)
```

In `ChatCommands.body`, after the `CommandGroup(after: .sidebar) { … }` block add:

```swift
        // Go menu — the window's navigation history (spec 2026-09-23 §5).
        // Both items stay enabled: `Commands` cannot read view state, and a
        // press with nothing to go to is a no-op in the listener, the same
        // shape as ⌘1/⌘2/⌘3 above.
        CommandMenu("Go") {
            Button("Back") { post(.goBack) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { post(.goForward) }
                .keyboardShortcut("]", modifiers: .command)
        }
```

In `MatronMac/Features/ChatList/MacChatListView.swift`, in `withCommandListeners` directly after the `.showDecisions` listener line, add:

```swift
            // Go ▸ Back / Forward, ⌘[ / ⌘] (spec 2026-09-23 §5) — same bus
            // shape as ⌘1/⌘2/⌘3; a press with nothing to go to is a no-op.
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.goBack))) { _ in goBack() }
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.goForward))) { _ in goForward() }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: `MacCommandsTests` executes 5 tests with 0 failures (the distinct-names test covers the two new cases through `allCases`).

- [ ] **Step 5: Commit**

```bash
git add MatronMac/App/Commands.swift MatronMac/Features/ChatList/MacChatListView.swift MatronMacTests/MacCommandsTests.swift
git -c user.email=dan@yearbookmachine.com -c user.name="Dan Barker" commit -m "nav(mac): Go menu with Back ⌘[ and Forward ⌘] on the command bus (spec §5)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Whole-target verification and the manual pass

**Files:**
- No source changes expected. Fixes found here go into the task that owns the code, as their own commits.

- [ ] **Step 1: Run the full Mac unit-test suite with the app-support override**

```bash
rm -rf /tmp/matron-test-appsupport
env TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-test-appsupport TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 \
  xcodebuild test -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd \
  -only-testing:MatronMacTests 2>&1 | tee /tmp/mac-tests.log | grep -E "error:|Test Case .* failed|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" | tail -6
ls /tmp/matron-test-appsupport
```

Expected: `TEST SUCCEEDED`, one `Executed N tests, with 0 failures` line where N ≥ the count before this branch plus 23 (10 + 2 + 10 + 1 new tests, none removed), and `/tmp/matron-test-appsupport` contains `journal-store/` (proof the override applied). If the directory is empty, STOP: the override was not forwarded and the live store may have been written — quit the app, move `~/Library/Application Support/chat.matron.app` aside, relaunch (memory `feedback_mac_test_host_real_home`).

Note: a known runner flake exists in the timeline-service gap test; re-run once before treating it as a regression.

- [ ] **Step 2: Build the Mac app and the shared package**

```bash
xcodebuild -scheme MatronMac -destination 'platform=macOS' -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -3
xcodebuild -scheme Matron -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -3
```

Expected: both `BUILD SUCCEEDED` (the iOS build proves nothing under `Matron/` was touched by mistake).

- [ ] **Step 3: Manual pass (record the outcome in the PR description)**

Run the Debug build from `build/dd/Build/Products/Debug/MatronMac.app` (NOT an install: Dan's installed app is a Release build in `/Applications`; leave it). Check, in order:

1. Fresh window: both chevrons greyed. Click a conversation, then another: Back enabled; Back returns to the first; Forward enabled and returns to the second.
2. Open the items pane (⇧⌘I), push an item, push a linked item from inside it: three Back presses walk the pane back one item at a time and then close nothing (the pane stays open on its list); the pane's own back chevron also records (press it, then Forward re-pushes).
3. From a chat, open a sub-chat from the strip; Back closes it; Forward reopens it.
4. ⌘2 to Conversations, ⌘3 to Decisions, pick an item, ⌘1 Coordinator: Back three times retraces to Conversations; Forward three times returns to the Coordinator.
5. Read a mission, tap a milestone (lands in the room): Back returns to the mission page (review focus 2).
6. Type a search query so results cover the detail, then ⌘[: the results panel is gone and the previous chat is shown (review focus 4).
7. Leave a conversation (context menu ▸ Leave) that is in the history, then Back onto it: "Select a chat", no crash; Forward still works (review focus 5).
8. Switch conversations with a pushed pane open: the new chat shows the pane's LIST (today's behaviour); Back returns to the previous chat WITH its pushed item (spec §3).
9. Collapse the sidebar (⌘⇧S): ⌘[ still works with the buttons hidden.
10. The Go menu shows Back ⌘[ and Forward ⌘].

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin feat/mac-nav-history
gh pr create --base main --title "nav(mac): always-on Back/Forward history (⌘[ ⌘], Go menu, pane pushes included)" --body-file - <<'EOF'
## Why
The Mac app had many ways to move between places and no "go back to where I just was" (tracker #2536). Dan: "you don't have a concept of whether it's a global or local back, you just want to go back."

## What
Spec: `docs/superpowers/specs/2026-09-23-mac-navigation-history-design.md`. Plan: `docs/superpowers/plans/2026-09-23-mac-navigation-history.md`.

- `MacNavigationHistory` (pure, 50 entries) records every place change the shell's state describes — nav entry, conversation, mission, decision item, and the chat's pane route (items pane push stack or open sub-chat) — through one `onChange`, and restores a popped place by writing the same state back.
- The chat's pane route is hoisted to a per-window binding (replacing `itemsPaneOpen: Binding<Bool>`), so a Back onto a conversation brings its pushed item back; a plain switch still shows the new chat's list.
- Back/Forward chevrons in the sidebar toolbar (top-left, greyed when empty), `⌘[` / `⌘]`, and a Go menu.
- iOS untouched.

## Tests
`MacNavigationHistoryTests`, `MacNavigationShellTests`, `MacChatViewTests` (+2), `MacCommandsTests` (+1); full `MatronMacTests` green with the app-support override; Mac + iOS builds succeed.

## Manual pass
(fill in from Task 5 Step 3)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```
