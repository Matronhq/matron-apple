# Matron — Phase 2.5 (Live Chat-List + Room Metadata) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phases 1+2 merged (PR #1) and CI green; Phase 3 (PR #3, `phase-3-e2ee-verification`) either merged or in flight.

## Why this phase exists

When Phase 2 shipped, `ChatServiceLive.chatSummaries()` was left as a **one-shot snapshot** rather than a long-lived subscription. The code-comment explicitly defers the real subscription:

```swift
// Phase 1 uses a simple polling snapshot via client.rooms()
// rather than RoomList.entriesWithDynamicAdapters. The
// dynamic-adapters API in v26 crashes inside its internal
// VectorDiff::map / BaseStateStore pipeline against tuwunel,
// and we don't need real-time diffing for the Phase 1 chat
// list. Phase 2 (timeline view) can revisit this with a
// real subscription once the SDK path is stable.
```

But Phase 2 (timeline view) didn't revisit it, and no subsequent phase plan picks it up. As a result:

1. **New rooms created on another device don't appear** until sign-out + sign-in.
2. **Mute / leave / room-rename events from other devices don't propagate** to the chat list.
3. **Pull-to-refresh** on iOS and `⌘R` on Mac call `ChatService.refresh()` which only does `sync.waitUntilReady()` — a no-op once sliding sync is running. The gesture is purely cosmetic.
4. `ChatListViewModel.start()` ships with a 30-attempt × 1-second retry loop solely to mask the empty-first-snapshot race. With a long-lived subscription this becomes unnecessary.

These gaps were never user-facing because **this app has never been released**, but they're foundational and need to land before any UX polish (Phase 7) is meaningful. They also block honest exit criteria for "Phase 1+2 actually delivered".

**Goal:** Replace the one-shot pattern with a continuously-updating `chatSummaries()` stream backed by matrix-rust-sdk's `RoomListService` + per-room state subscriptions. New rooms, mutes, leaves, name changes, and `latestEvent` updates from other devices appear in the iOS + Mac chat list within a few hundred milliseconds.

## Architecture

The shared `ChatService` protocol stays unchanged (`chatSummaries()` returns `AsyncThrowingStream<[ChatSummary], Error>`). Implementation flips from one-shot to long-lived:

- **`RoomListService.allRooms().entriesWithDynamicAdapters(pageSize:listener:)`** drives the room set. The listener receives `RoomListEntriesUpdate` diffs (Append, PushBack, Insert, Remove, Reset, …) which we apply to a continuously-evolving `[ChatSummary]` snapshot and yield to the AsyncStream consumer.
- **Per-room `Room.subscribeToUpdates()`** drives latestEvent / displayName / notificationMode / member-count changes for rooms in the current window. State changes for individual rooms re-yield the snapshot (with that one row updated) without a full RoomList re-walk.
- **Defensive fallback:** if `entriesWithDynamicAdapters` throws or the listener never fires within 5s on first subscribe, fall back to polling `client.rooms()` every 30s. Tracks whether the dynamic-adapters path actually works against tuwunel today (the historical blocker the original code blamed) without breaking sign-in for users on a homeserver where it doesn't.

The `.refreshable` gesture stops being a no-op: it forces a manual re-fetch of the current room list (a `client.rooms()` snapshot, fed back into the same yield path), useful as an escape hatch if the live subscription stalls or for users wanting an explicit "I just changed something on another device" affirmation. iOS HIG warns against pure-cosmetic refresh; the gesture earns its keep.

## File structure (Phase 2.5 deliverables)

```
matron-iOS-app/
├── MatronShared/Sources/Chat/
│   ├── ChatService.swift                      MODIFIED — doc-comment now says long-lived
│   ├── ChatServiceLive.swift                  MODIFIED — RoomList subscription + per-room state
│   └── RoomListSubscription.swift             NEW — encapsulates the dynamic-adapters wiring
├── MatronShared/Sources/ViewModels/
│   └── ChatListViewModel.swift                MODIFIED — drop retry loop; consume diffs
├── MatronShared/Sources/Sync/
│   └── SyncServiceLive.swift                  POSSIBLY-MODIFIED — expose RoomListService access
├── MatronShared/Tests/ChatTests/
│   ├── ChatServiceLiveTests.swift             MODIFIED — multi-yield + diff-application coverage
│   └── RoomListSubscriptionTests.swift        NEW — diff-application unit tests with a fake listener
├── tests/integration/scenarios/
│   └── chat-list-live-updates-sdk.sh          NEW — partner.mjs creates a room post-mount, assert it appears
└── tests/integration/run-all-ui.mjs           MODIFIED — add chat-list-live-updates-sdk to the batch
```

No view-layer changes: `ChatListView.swift` (iOS) and `MacChatListView.swift` (Mac) already consume the same `ChatListViewModel.groups` snapshot. They re-render automatically when the snapshot updates.

---

## Tasks

### Task 1: SDK spike — does `entriesWithDynamicAdapters` work against tuwunel today?

**Why first:** the original code blamed a tuwunel-side crash on this exact API. SDK is now 26.4.1 (was earlier in v26 series); tuwunel has had updates too. We need an empirical answer before committing the rest of the implementation, otherwise we either spend two days writing code for a path that doesn't work, or we under-build with a polling-only fallback that we'll throw away.

**Files:**
- New: `MatronShared/Tests/ChatTests/RoomListSpikeTests.swift` (temporary — deleted at end of phase)

- [ ] **Step 1: Write a 30-second SDK spike test.**

  In a new test, sign in `@matron1` against the local Docker homeserver, call `syncService.start()`, then `roomListService.allRooms().entriesWithDynamicAdapters(pageSize: 100, listener: …)`. The listener appends every `RoomListEntriesUpdate` it receives into an actor-protected `[String]`. Wait 30s. Assert no crash, listener fired at least once with the initial snapshot. Drop test.

- [ ] **Step 2: Drive an external mutation.**

  In the same test process, after the 30s observation window, create a new room via the SDK directly (a stand-in for "another device created a room"). Assert the listener fires another diff containing that room within 5 seconds.

- [ ] **Step 3: Decide path.**

  - If both steps pass → proceed to Task 2 with the dynamic-adapters implementation (fallback included but expected unused).
  - If Step 1 passes but Step 2 doesn't → tuwunel doesn't push updates over sliding sync for fresh rooms; document and proceed with polling fallback as primary path. (Unlikely; sliding sync supports this.)
  - If Step 1 crashes → the historical blocker is still there. Document the crash signature, file a tuwunel issue, ship the polling fallback as primary path. Revisit when SDK or homeserver is updated.

  Document the outcome inline at the top of `RoomListSubscription.swift` (created in Task 2) so future agents don't re-litigate.

### Task 2: Replace one-shot `chatSummaries()` with long-lived RoomList subscription

**Files:**
- New: `MatronShared/Sources/Chat/RoomListSubscription.swift`
- Modified: `MatronShared/Sources/Chat/ChatServiceLive.swift`

- [ ] **Step 1: Extract subscription into a dedicated type.**

  `RoomListSubscription` owns the listener handle + the evolving `[String: ChatSummary]` map (keyed by room ID for diff application). Exposes an `AsyncThrowingStream<[ChatSummary], Error>` consumer interface. Internal `apply(_ diff: RoomListEntriesUpdate)` method handles each variant (Append / PushBack / Insert / Remove / Reset / Clear / Truncate / PopBack / PopFront / Set / PushFront).

- [ ] **Step 2: Re-implement `ChatServiceLive.chatSummaries()` to delegate.**

  Construct a `RoomListSubscription` per call, return its stream. Cancellation tears down the listener handle.

- [ ] **Step 3: Polling fallback.**

  Wrap the subscription in a "first yield within 5s" race. If the listener never fires (or throws), shut it down and yield from a `client.rooms()` poll loop on 30s intervals instead. Log the fallback at `.notice` level so it shows up in `os.Logger`.

### Task 3: Per-room state subscription

**Files:**
- Modified: `MatronShared/Sources/Chat/RoomListSubscription.swift`

- [ ] **Step 1: For each room added to the window, attach `room.subscribeToUpdates()`.**

  The subscription's callback fires when the room's name, latestEvent, notificationMode, or member count changes. On each fire, re-build that one `ChatSummary` and re-yield the full snapshot with the updated row.

- [ ] **Step 2: Tear down per-room subscriptions on Remove diffs.**

  Track the subscription handles in the `[String: ChatSummary]` map's values (or a sidecar dict). On Remove / Reset / Clear / Truncate, drop the relevant handles.

### Task 4: ChatListViewModel cleanup

**Files:**
- Modified: `MatronShared/Sources/ViewModels/ChatListViewModel.swift`

- [ ] **Step 1: Drop the 30-attempt retry loop.**

  The loop was masking the one-shot empty-first-snapshot race. With a long-lived stream the empty case is just an initial `[]` yield followed by real data when sliding sync warms up.

- [ ] **Step 2: Update `start()` to consume multi-yield.**

  `for try await snapshot in chat.chatSummaries() { groups = group(snapshot) }`. No `break` after first non-empty.

- [ ] **Step 3: Add a `refresh()` method to ChatListViewModel.**

  Cancels and re-creates the underlying subscription. Bound to the iOS / Mac `.refreshable` closures (replaces the no-op `chat.refresh()` call). Useful when the live subscription stalls.

### Task 5: Tests

**Files:**
- New: `MatronShared/Tests/ChatTests/RoomListSubscriptionTests.swift`
- Modified: `MatronShared/Tests/ChatTests/ChatServiceLiveTests.swift`
- New: `tests/integration/scenarios/chat-list-live-updates-sdk.sh`
- Modified: `tests/integration/run-all-ui.mjs`

- [ ] **Step 1: Unit-test diff application.**

  `RoomListSubscriptionTests` feeds synthetic `RoomListEntriesUpdate` sequences into `RoomListSubscription.apply(_:)` and asserts the resulting snapshot matches expected. One test per diff variant.

- [ ] **Step 2: Integration scenario.**

  `chat-list-live-updates-sdk.sh`: matron app subscribes to `chatSummaries()`, partner.mjs creates a room as the same `@matron` user from a second device, scenario asserts the new room appears in matron's stream within 10 seconds. Log `os.Logger` markers for diagnosis.

- [ ] **Step 3: Add to `run-all-ui.mjs` batch.**

  Append to the orchestrator's `SCENARIOS` array with its own `matron3` user (or reuse `matron1` if isolation isn't critical for this scenario).

### Task 6: Plan housekeeping

- [ ] **Step 1: Update HANDOVER.md.**

  Add a session-N+1 close-out block describing the live chat-list landing. Note explicitly that Phase 2's "real-time room-info subscriptions" promise is now actually shipped, so the comment in `ChatServiceLive.swift` lines 73–86 can be replaced with a pointer to this plan instead of an aspirational TODO.

- [ ] **Step 2: Strike the deferral from any in-code comments.**

  Search for "Phase 2 (timeline view) can revisit", "Phase 2 wires real-time", and similar. Replace with "Phase 2.5 wired this; see plan at docs/superpowers/plans/2026-05-05-matron-ios-phase-2-5-live-chat-list.md".

---

## Out of scope for this phase

- **Real-time chat list ordering / scroll-to-top on new message:** the SDK's `RoomListInput.invitesAllowed`, sort filter, and viewport sliding are all UX layers above the diff stream. Phase 7 polish.
- **Push notifications:** Phase 4. The chat list updates are in-app, not in-background.
- **Read marker / unread count parity with the active room:** the `unreadCount` in `ChatSummary` already exists from Phase 1 but currently never updates because there's no room-info subscription. This phase WILL incidentally fix that, but if the SDK exposes a separate notification settings stream we may need to wire it explicitly — note any gap and defer to Phase 7.
- **Mac sidebar selection persistence across re-snapshots:** PR #1 cursor[bot] #21 was already addressed; nothing to do here.

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `entriesWithDynamicAdapters` still crashes against tuwunel | Medium | Task 1 spike answers empirically before any production code is written. Polling fallback already in plan. |
| Per-room subscriptions leak when many rooms scroll out of the page-100 window | Medium-Low | Task 3 Step 2 explicitly tears down on Remove. Page-size 100 is generous for this app's expected room counts. |
| Diff application bugs corrupt the snapshot | High (without tests) → Low (with) | Task 5 Step 1 covers each variant. Diff sequences from real homeservers are extremely predictable; the unit tests cover the surface. |
| Performance regression on large room lists | Low | Snapshot is yielded as a fresh `Array`; SwiftUI diffs by stable IDs. Not a hotspot. |
| Live updates expose a new race in `ChatListViewModel` (which has been polling-only) | Low | Task 4 Step 1 explicitly drops the retry loop; Task 4 Step 2 just iterates a stream. Existing snapshot tests of view models stay green. |

## Success criteria

1. `tests/integration/scenarios/chat-list-live-updates-sdk.sh` passes end-to-end via `node tests/integration/run-all-ui.mjs`.
2. `ChatListViewModel.start()` no longer contains the 30×1s retry loop.
3. `ChatServiceLive.swift` no longer has the "Phase 2 will revisit" comment.
4. All existing tests still pass (`swift test` for SPM; `xcodebuild test -scheme MatronMac` and `-scheme Matron` for host-app tests; `node tests/integration/run-all-ui.mjs` for the UI scenario batch).
5. Manual smoke: sign in on Mac, create a room from a second device (CLI partner.mjs or another logged-in app), confirm the room appears in the Mac chat list within ~5s without sign-out + back-in.
