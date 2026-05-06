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

The shared `ChatService` protocol stays unchanged (`chatSummaries()` returns `AsyncThrowingStream<[ChatSummary], Error>`). Implementation flips from one-shot to long-lived, with one subscription owned by the service and a fan-out broadcaster sitting between it and the (potentially multiple) `chatSummaries()` consumers:

- **One owned `RoomListSubscription` per `ChatServiceLive` instance.** `RoomListService.allRooms().entriesWithDynamicAdapters(pageSize:listener:)` drives the room set. The listener receives `RoomListEntriesUpdate` diffs (Append, PushBack, Insert, Remove, Reset, …) which we apply to a continuously-evolving `[ChatSummary]` snapshot held inside the service. **`ChatServiceLive` is already a per-session singleton in DI, so one subscription = one per signed-in user.**
- **Fan-out `Broadcast<[ChatSummary]>` actor.** Every call to `chatSummaries()` registers a continuation with the broadcaster, immediately receives the latest snapshot, then receives every subsequent broadcast until cancelled. Two known callers today — `ChatListViewModel.start()` and `NewChatSheet.loadBots()` — share the upstream listener instead of each spawning its own. Cancelling one consumer (sheet dismiss, view-model deinit) removes only that continuation; the other keeps receiving.
- **Per-room `Room.subscribeToUpdates()`** drives latestEvent / displayName / notificationMode / member-count changes for rooms in the current window. State changes for individual rooms re-yield the snapshot (with that one row updated) without a full RoomList re-walk. Subscription handles are tracked alongside the room map and torn down on Remove diffs.
- **Defensive fallback (narrow).** Fall back to polling `client.rooms()` every 30s **only if `entriesWithDynamicAdapters` THROWS at construction time** — that's the historical-blocker signature. Don't gate the live path on a "first-yield within 5s" race: Task 1's spike confirmed `.reset` arrives immediately on subscribe, so any always-true 5s check would mask a genuinely broken listener that fires `.reset` then dies. If we want a stronger health signal post-launch, ship a debug-only periodic divergence heartbeat (compares the live snapshot's room IDs against `client.rooms()` once every N minutes; logs at `.notice` if they diverge). No fallback action — divergence detection only.

The `.refreshable` gesture stops being a no-op: it forces a one-shot `client.rooms()` snapshot fed back through the broadcaster (same pipe consumers are already iterating), **without** tearing down the live listener. Cheap, intuitive, doesn't lose accumulated diff state. iOS HIG warns against pure-cosmetic refresh; the gesture earns its keep.

## File structure (Phase 2.5 deliverables)

```
matron-iOS-app/
├── MatronShared/Sources/Chat/
│   ├── ChatService.swift                      MODIFIED — doc-comment now says long-lived
│   ├── ChatServiceLive.swift                  MODIFIED — owns one RoomListSubscription + broadcaster
│   ├── RoomListSubscription.swift             NEW — encapsulates dynamic-adapters + per-room state
│   └── ChatSummaryBroadcaster.swift           NEW — fan-out actor; multi-consumer registration
├── MatronShared/Sources/ViewModels/
│   └── ChatListViewModel.swift                MODIFIED — drop retry loop; consume multi-yield
├── MatronShared/Sources/Sync/
│   └── SyncServiceLive.swift                  POSSIBLY-MODIFIED — expose RoomListService access
├── Matron/Features/ChatList/
│   └── NewChatSheet.swift                     MODIFIED — drop retry loop; first-non-empty-then-break
├── MatronShared/Tests/ChatTests/
│   ├── ChatServiceLiveTests.swift             MODIFIED — multi-yield via broadcaster
│   ├── ChatSummaryBroadcasterTests.swift      NEW — multi-consumer fan-out, cancellation, fail
│   └── RoomListSubscriptionTests.swift        NEW — diff-application unit tests, one per variant
├── tests/integration/scenarios/
│   └── chat-list-live-updates-sdk.sh          NEW — partner.mjs creates room post-mount; live-update asserted
└── tests/integration/run-all-ui.mjs           MODIFIED — add chat-list-live-updates-sdk to the batch
```

No view-layer changes: `ChatListView.swift` (iOS) and `MacChatListView.swift` (Mac) already consume the same `ChatListViewModel.groups` snapshot. They re-render automatically when the snapshot updates.

---

## Tasks

### Task 1: SDK spike — does `entriesWithDynamicAdapters` work against tuwunel today?

**Status: DONE in session 8 (commit `393faa1`).** Empirically confirmed against `matrix-rust-components-swift 26.4.1` + local tuwunel: the dynamic-adapters listener fires `.reset` immediately on subscribe and `.pushBack` / `.pushFront` / `.set` for subsequent room mutations. No crash. The historical "v26 crashes inside `VectorDiff::map / BaseStateStore`" blocker is gone.

**Spike artefacts to delete at the end of Phase 2.5** (after the production implementation + integration scenario lands and is green):
- `MatronShared/Tests/ChatTests/RoomListSubscriptionSpikeTests.swift`
- `tests/integration/scenarios/roomlist-spike-sdk.sh`

The spike test deliberately did NOT cover per-room `Room.subscribeToUpdates()` overhead at scale; that's gated behind Task 3 Step 0 below.

### Task 2: Replace one-shot `chatSummaries()` with one shared long-lived subscription + fan-out

**Files:**
- New: `MatronShared/Sources/Chat/RoomListSubscription.swift`
- New: `MatronShared/Sources/Chat/ChatSummaryBroadcaster.swift` (or a `private actor` nested in `ChatServiceLive` if the surface stays small)
- Modified: `MatronShared/Sources/Chat/ChatServiceLive.swift`

- [ ] **Step 1: Extract subscription into a dedicated type.**

  `RoomListSubscription` owns the listener handle + the evolving `[String: ChatSummary]` map (keyed by room ID for diff application). Internal `apply(_ diff: RoomListEntriesUpdate)` method handles each variant (Append / PushBack / Insert / Remove / Reset / Clear / Truncate / PopBack / PopFront / Set / PushFront). Exposes a delegate-style callback `onSnapshot: ([ChatSummary]) -> Void` rather than vending an `AsyncThrowingStream` directly — the broadcaster (Step 2) is the consumer-facing surface, this type is its source.

- [ ] **Step 2: Add a fan-out broadcaster.**

  `ChatSummaryBroadcaster` (an `actor`, or a `Sendable` class with internal locking) holds the latest `[ChatSummary]` snapshot + a list of registered `AsyncThrowingStream.Continuation<[ChatSummary], Error>`. Methods:
  - `register(_ continuation:)` — adds the continuation, immediately yields the latest snapshot if non-nil, returns a cancellation token.
  - `unregister(token:)` — removes that continuation.
  - `broadcast(_ snapshot:)` — stores latest, yields to all registered continuations.
  - `fail(with: Error)` — terminates all continuations with the error.

  Thread-safety: any actor or lock is fine; consumer-side cancellation must NOT block other consumers' delivery.

- [ ] **Step 3: Re-implement `ChatServiceLive.chatSummaries()`.**

  - On the FIRST call (lazy init), construct one `RoomListSubscription`, wire its `onSnapshot` callback to `broadcaster.broadcast(_:)`, and store both as service-level state.
  - On every call (first or not): build an `AsyncThrowingStream`, register the continuation with the broadcaster inside `AsyncThrowingStream { … }`, set `onTermination` to call `broadcaster.unregister(token:)`. Return the stream.
  - The owned `RoomListSubscription` lives for the lifetime of the service; never torn down on individual consumer cancellation.

- [ ] **Step 4: Narrow defensive fallback (construction-throw only).**

  Wrap the `roomListService.allRooms().entriesWithDynamicAdapters(...)` call in a `do/catch`. On throw: log at `.error` level, fall back to a poll loop (`client.rooms()` every 30s, fed through `broadcaster.broadcast(_:)` the same way). Document inline at the top of `RoomListSubscription.swift` that Task 1 confirmed the live path works against tuwunel as of 2026-05-05; this fallback is only for future SDK or homeserver regressions.

  **Do NOT add a "first-yield within 5s" race** — `.reset` arrives immediately on subscribe, so the race always wins even if the listener is silently broken. If post-launch divergence shows up, ship a debug-only heartbeat (Task 5 Step 4) to detect it; don't add fallback logic that won't actually fire.

### Task 3: Per-room state subscription

**Files:**
- Modified: `MatronShared/Sources/Chat/RoomListSubscription.swift`
- Spike (temporary): extend `MatronShared/Tests/ChatTests/RoomListSubscriptionSpikeTests.swift`

- [ ] **Step 0: Quick scaling spike — does 100× `Room.subscribeToUpdates()` work?**

  Task 1's spike covered the room-list listener. The per-room layer was deliberately deferred. Before we attach 100 subscriptions on first `.reset` in production, extend the existing spike test (or add a sibling `test_perRoomSubscriptionScale`) that:
  - Subscribes to 100 rooms via `room.subscribeToUpdates()` immediately after `.reset` lands.
  - Waits 30s.
  - Asserts no crash, no apparent event flood (count callbacks; should match user-driven mutations only, not exceed N×rooms-per-second).
  - Drops all subscription handles cleanly (no leaks per `os_signpost` or `Instruments`-equivalent).

  If the spike passes (expected, given matrix-rust-sdk's design): proceed to Step 1. If it crashes or floods: scope the per-room layer down to a sliding window of the top ~20 rooms in the chat list (others fall back to RoomList-driven `latestEvent` updates only). Document outcome inline at `RoomListSubscription.swift`.

- [ ] **Step 1: For each room added to the window, attach `room.subscribeToUpdates()`.**

  The subscription's callback fires when the room's name, latestEvent, notificationMode, or member count changes. On each fire, re-build that one `ChatSummary` and re-broadcast the full snapshot with the updated row (via the broadcaster from Task 2 Step 2). Use `pageSize: 100` from `entriesWithDynamicAdapters` as the window default; revisit if Step 0's spike reveals overhead.

- [ ] **Step 2: Tear down per-room subscriptions on Remove diffs.**

  Track the subscription handles in a sidecar `[String: TaskHandle]` (or whatever `room.subscribeToUpdates()` returns). On Remove / Reset / Clear / Truncate, drop the relevant handles. On `Reset`, drop ALL prior handles before installing the new ones — `.reset` is a full state replacement.

### Task 4: View-model + sheet cleanup

**Files:**
- Modified: `MatronShared/Sources/ViewModels/ChatListViewModel.swift`
- Modified: `Matron/Features/ChatList/NewChatSheet.swift`

- [ ] **Step 1: Drop the 30-attempt retry loop in `ChatListViewModel.start()`.**

  The loop was masking the one-shot empty-first-snapshot race. With the long-lived broadcaster a registered consumer immediately gets the latest snapshot (which may be `[]` or fully populated depending on sliding-sync warmth), then receives every subsequent broadcast as the listener reports diffs. The retry-and-poll workaround becomes pure dead code.

- [ ] **Step 2: Update `ChatListViewModel.start()` to consume multi-yield.**

  `for try await snapshot in chat.chatSummaries() { groups = group(snapshot) }`. No `break` after first non-empty. Existing `error` field still used for upstream stream failures (QA finding #10).

- [ ] **Step 3: Drop the 30-attempt retry loop in `NewChatSheet.loadBots()` too.**

  Same justification as Step 1. The session-8 commit `c2e238a` (per-attempt error catch) and `168a878` (load-bearing `break` restored) hardened the existing loop against transient errors and the doc-comment-vs-impl mismatch — both fixes go away cleanly with the long-lived stream. Replace the inner `for/while` retry loop with a single `for try await snapshot in chat.chatSummaries() { if !snapshot.isEmpty { extract bots; break } }`. Errors propagate naturally; if the upstream broadcaster fails, the sheet surfaces that to the user via the existing error path.

- [ ] **Step 4: `ChatListViewModel.refresh()` — one-shot poll-and-broadcast, leave listener alive.**

  Bound to iOS `.refreshable` and Mac `⌘R` closures (replaces the no-op `chat.refresh()` call). Implementation: call a NEW `ChatService.forceSnapshot()` method which does a one-shot `client.rooms()` snapshot and feeds it through the broadcaster — exactly the same pipe live diffs use. **Don't tear down the live `RoomListSubscription` and re-create it** — that throws away accumulated diff state and per-room subscription handles for no benefit. The user-visible expectation is "I just changed something on another device, refresh now"; a one-shot snapshot satisfies that without disturbing the live path.

### Task 5: Tests

**Files:**
- New: `MatronShared/Tests/ChatTests/RoomListSubscriptionTests.swift`
- New: `MatronShared/Tests/ChatTests/ChatSummaryBroadcasterTests.swift`
- Modified: `MatronShared/Tests/ChatTests/ChatServiceLiveTests.swift`
- New: `tests/integration/scenarios/chat-list-live-updates-sdk.sh`
- Modified: `tests/integration/run-all-ui.mjs`

- [ ] **Step 1: Unit-test diff application (one test per `RoomListEntriesUpdate` variant).**

  `RoomListSubscriptionTests` feeds synthetic `RoomListEntriesUpdate` sequences into `RoomListSubscription.apply(_:)` and asserts the resulting snapshot matches expected. Cover Append / PushBack / PushFront / PopBack / PopFront / Insert / Remove / Set / Reset / Clear / Truncate. Each test is ~10-20 LOC.

- [ ] **Step 2: Unit-test the fan-out broadcaster.**

  `ChatSummaryBroadcasterTests` covers:
  - Single consumer: register → receive immediate latest → receive each broadcast in order → cancel cleanly.
  - Two consumers concurrently: both register → both receive the same broadcast sequence → cancelling one does NOT affect the other.
  - `fail(with:)` terminates all consumers with the same error.
  - Rapid register-unregister doesn't leak continuations or block delivery to others.

- [ ] **Step 3: Update `ChatServiceLiveTests.swift`.**

  Existing tests assert on the one-shot semantic. Update to assert: `chatSummaries()` yields the broadcaster's current snapshot immediately, and a subsequent test-driven `forceSnapshot()` produces a second yield. Update existing fakes (`ScriptedChatService` etc.) to support multi-yield.

- [ ] **Step 4 (optional, debug-only): Heartbeat divergence logger.**

  If we want post-launch visibility into the live path's correctness, add a `#if DEBUG` periodic task in `ChatServiceLive` that compares `broadcaster.latestSnapshot` IDs against a one-shot `client.rooms()` snapshot every ~5 minutes. Log at `.notice` if they diverge. **No fallback action; pure observability.** Skip if Task 1 + Task 3 Step 0 spikes are convincing enough.

- [ ] **Step 5: Integration scenario.**

  `chat-list-live-updates-sdk.sh`: matron app subscribes to `chatSummaries()`, partner.mjs creates a room as the same `@matron` user from a second device, scenario asserts the new room appears in matron's stream within 10 seconds. Also assert: a second consumer (simulating `NewChatSheet.loadBots()` running concurrently) gets the same diff. Log `os.Logger` markers for diagnosis.

- [ ] **Step 6: Add to `run-all-ui.mjs` batch.**

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
| `entriesWithDynamicAdapters` still crashes against tuwunel | Resolved (Task 1 spike) | Empirically confirmed working as of `393faa1` against `matrix-rust-components-swift 26.4.1`. Construction-throw fallback retained for future SDK regressions. |
| 100× `Room.subscribeToUpdates()` floods or leaks | Medium | Task 3 Step 0 spike validates before all-up implementation. Fallback: scope per-room subscriptions to a sliding window of the top 20 rooms. |
| Per-room subscriptions leak when rooms scroll out of the page-100 window | Medium-Low | Task 3 Step 2 explicitly tears down on Remove + Reset. Page-size 100 is generous for this app's expected room counts. |
| Two consumers (view-model + new-chat sheet) race on broadcaster registration | Low | Task 5 Step 2 covers concurrent register/unregister. `actor` semantics serialize. |
| Diff application bugs corrupt the snapshot | High (without tests) → Low (with) | Task 5 Step 1 covers each variant. Diff sequences from real homeservers are extremely predictable; the unit tests cover the surface. |
| Performance regression on large room lists | Low | Snapshot is yielded as a fresh `Array`; SwiftUI diffs by stable IDs. Not a hotspot. |
| Live updates expose a new race in `ChatListViewModel` (which has been polling-only) | Low | Task 4 Step 1+2 explicitly drops the retry loop; just iterates the broadcaster's stream. Existing snapshot tests of view models stay green. |
| `NewChatSheet.loadBots()` regression after dropping its retry loop | Low | Task 4 Step 3 replaces the loop with a single non-empty-snapshot break. Long-lived stream eliminates the empty-first-snapshot race the loop existed to mask. |
| Production code under-detects a silently-broken live path | Low | Task 5 Step 4 optional debug heartbeat catches divergence post-launch without a fragile 5s-yield race that would always succeed. |

## Success criteria

1. `tests/integration/scenarios/chat-list-live-updates-sdk.sh` passes end-to-end via `node tests/integration/run-all-ui.mjs`.
2. `ChatListViewModel.start()` AND `NewChatSheet.loadBots()` no longer contain a 30×1s retry loop.
3. `ChatServiceLive.swift` no longer has the "Phase 2 will revisit" comment.
4. `ChatSummaryBroadcaster` test asserts two concurrent consumers receive the same diff sequence and cancellation of one doesn't affect the other.
5. All existing tests still pass (`swift test` for SPM; `xcodebuild test -scheme MatronMac` and `-scheme Matron` for host-app tests; `node tests/integration/run-all-ui.mjs` for the UI scenario batch).
6. Manual smoke: sign in on Mac, create a room from a second device (CLI partner.mjs or another logged-in app), confirm the room appears in the Mac chat list within ~5s without sign-out + back-in.
7. Manual smoke 2: open `New Chat` sheet on iOS or Mac while another device renames a bot's display name; reopen the sheet — the new name shows without sign-out.
