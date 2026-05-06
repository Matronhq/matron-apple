# Matron Mac silent-push body construction — design

**Status:** Design only. Implementation deferred to a `phase-4-mac-silent-push` follow-up branch (does not block PR #5 merge).

**Problem.** When Sygnal forwards a Matrix push notification to Mac, APNs delivers a silent payload (`content-available: 1` with `room_id` + `event_id` in `userInfo`). Today MatronMac's `MacNotificationHandler.willPresent` cannot rewrite the displayed body — Apple's `userNotificationCenter(_:willPresent:withCompletionHandler:)` completion takes presentation OPTIONS only, not modified content. The user sees the encrypted placeholder body (or nothing, depending on what Sygnal supplies). On iOS this is solved by a Notification Service Extension (`MatronNSE`); macOS doesn't have NSE, so the equivalent has to live in the host process via `NSApplicationDelegate.application(_:didReceiveRemoteNotification:)`.

**Goal.** Match iOS Phase 4 parity: a notification arriving on a signed-in Mac displays the decrypted sender + body.

**Out of scope for this design:**
- iOS NSE behaviour (already shipped in PR #5; this design only touches Mac).
- Mac App Store distribution `aps-environment` split (Phase 7).
- Cross-platform push retry / delivery-receipt logic (no Phase 4 task wants this).

---

## Design decisions

### D1. Where the decoder lives

**Decision: Singleton `MacPushPipeline` actor on the Mac app target, parallel to `PushTokenStore.shared` and `MacNotificationHandler.shared`.**

Rejected alternatives:
- *Property on `MatronMacAppDelegate`*: AppDelegate is built before sign-in (no session yet). Storing a nil-able decoder on the delegate works but spreads lifecycle logic across two places (AppDelegate for token + decoder, MatronMacApp for bootstrap).
- *Lazy-init in `application(_:didReceiveRemoteNotification:)`*: each silent push pays the SDK init cost. Notification Client construction is cheap relative to network fetch but still wasteful on a busy account.

Singleton wins because: (a) the lifecycle (install on bootstrap, tear down on sign-out) maps cleanly to one object, (b) tests can construct fresh instances via the public init while production reads `.shared`, (c) it mirrors the existing `MacNotificationHandler.shared` shape so the AppDelegate's "set up the push surface" code stays in one location.

### D2. Decoder lifecycle vs sign-in / sign-out

**Decision: `MacPushPipeline.install(session:provider:syncService:)` from `MatronMacApp.bootstrapPush(for:)`; `MacPushPipeline.tearDown()` from `MatronMacApp.signOut(activeSession:)`.**

The pipeline holds:
- `session: UserSession` — needed by `PushDecoder.live(provider:session:processSetup:)`.
- `provider: ClientProvider` — same.
- `syncService: SyncService` — needed for `.singleProcess(syncService:)`.
- A lazily-built `PushDecoder` derived from the above when the first notification arrives.

`tearDown()` clears the three references. A subsequent `application(_:didReceiveRemoteNotification:)` call before the next sign-in installs the pipeline finds no session and no-ops (with a debug log).

**The race we DON'T solve here:** APNs can deliver a silent push during the gap between AppDelegate launch and first sign-in / bootstrap. That push is dropped. Buffering it is not worth the complexity — the homeserver retains the message; sliding-sync will surface it once the user signs in. The notification was just the wakeup signal.

### D3. Process setup

**Decision: `.singleProcess(syncService:)`.**

The Mac path runs in-process. The host's existing `SyncService` (built in `AppDependencies.syncService(for:)`) is the one running for the active session; the SDK's `notificationClient(processSetup: .singleProcess(syncService:))` factory specifically needs that instance to coordinate. The PushDecoder factory already takes `processSetup` as a parameter (it was made injectable in `9455e9e` exactly to support this).

iOS NSE uses `.multipleProcesses` because the NSE is a separate process; Mac uses `.singleProcess(syncService:)`. The `PushDecoder.live` factory's doc-comment already captures this split.

### D4. Where the decode + display happens

**Decision: A new `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` method on `MatronMacAppDelegate` that:**

1. Pulls `room_id` + `event_id` out of `userInfo`. If missing, call completion handler with `.noData` and return.
2. Fast-paths to `MacPushPipeline.shared.handle(roomID:eventID:userInfo:completion:)`.
3. Inside `handle`, the pipeline:
   - Fetches the lazily-built `PushDecoder` (or returns early if not installed).
   - Runs `decoder.decode(roomID:eventID:)`.
   - On success: schedules a fresh `UNNotificationRequest` with the decoded title + body + `userInfo` (preserving `room_id` + `event_id` for tap routing) via `UNUserNotificationCenter.current().add(_:withCompletionHandler:)`.
   - On failure: schedules a fallback request with title "Matron" / body "New message" so the user knows something happened, OR drops silently (see D5 for rationale).
   - Calls the system completion handler with `.newData` (or `.failed`).

The original silent-push payload has no displayable body, so we're not deduping with anything — we just add the new local notification.

### D5. Error fallback

**Decision: Silent drop on decode failure; do NOT schedule a fallback "New message" notification on Mac.**

Rationale: iOS NSE has a 30-second budget after which it MUST display something or the user gets nothing — the fallback there is a "Matron / New message" banner so the user knows to open the app. Mac doesn't have that constraint: silent push is `content-available: 1` with no displayable content; if we don't add a local notification, the user sees nothing and that's fine. They'll see the message next time they open the app.

This differs from iOS, but the asymmetry is correct — the iOS NSE budget forces a fallback that Mac doesn't need. A "New message" banner on Mac when decode failed (network blip, key not yet shared) would be more confusing than helpful.

Log the decode failure via os.Logger so the operator can see it in unified log; surface persistent failure via the future Settings UI.

### D6. Tap routing for the local notification

**Decision: Reuse the existing `MacNotificationHandler.didReceive` path. No new code.**

The local notification we schedule carries `room_id` in its `userInfo`. When the user taps it, `MacNotificationHandler.didReceive` fires (it's the system-wide UN delegate); `handleTap(userInfo:)` extracts the room ID; `NotificationCenter.matronOpenRoom` is posted; `MacChatListView.onReceive` flips `selectedSummaryID`. Same path that already works for the encrypted-placeholder case.

The cold-start tap buffer (`pendingRoomID` / `consumePendingRoomID()` added in cursor pass 3) also works unchanged — `handleTap` still buffers, `MacChatListView.task` still drains.

### D7. Foreground vs background

**Decision: `application(_:didReceiveRemoteNotification:)` runs in both foreground and background. Schedule the local notification unconditionally; let `MacNotificationHandler.willPresent` decide whether to surface it as a banner.**

`willPresent` already returns `[.banner, .sound, .list]` — that means foreground notifications surface as banners (matching iOS). Suppressing in-app banners would require comparing the room ID against `MacChatListView.selectedSummaryID`, which the AppDelegate doesn't have a clean accessor to (the host scope owns it). Skipping the suppression is fine — Element X iOS does the same; users expect a banner for off-screen rooms, and the chat-list highlight cues "this is the active room" so duplicate UI isn't confusing.

### D8. Sygnal config

**No Sygnal-side change.** The existing four-`app_id` config (Smoke test step 1 in `docs/push-setup.md`) already sends silent payloads to Mac (`content-available: 1` is the default for `event_id_only` payloads — Sygnal doesn't pre-render the body). The `chat.matron.mac.dev` / `chat.matron.mac` `app_id`s and the Sygnal `use_sandbox` flag continue to work unchanged.

---

## File structure

**New files:**
- `MatronMac/Push/MacPushPipeline.swift` — the singleton actor + lifecycle + decode-and-display logic.
- `MatronMacTests/MacPushPipelineTests.swift` — unit tests for install / tear-down / handle-when-uninstalled / userInfo-preserved.

**Modified files:**
- `MatronMac/App/MatronMacAppDelegate.swift` — add `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` that delegates to `MacPushPipeline.shared`.
- `MatronMac/App/MatronMacApp.swift` — `bootstrapPush(for:)` calls `MacPushPipeline.shared.install(...)` after the existing register-token step; `signOut(activeSession:)` calls `MacPushPipeline.shared.tearDown()` alongside the existing pusher unregister.
- `docs/push-setup.md` — update §"What's deferred" to mark Mac silent-push body construction as DONE; update §"Manual test walkthroughs" Walkthrough 5 to drop the "body shows encrypted placeholder" caveat.
- `manual-tests.md` — update §"Mac — push delivery" to drop the "body construction DEFERRED" caveat and require the decrypted-text acceptance criterion.
- `docs/HANDOVER.md` — note the Mac silent-push deferral as resolved.

**Sygnal-side:** None.

---

## Tasks

### Task 1: `MacPushPipeline` skeleton + tests

- [ ] Create `MatronMac/Push/MacPushPipeline.swift` with `static let shared = MacPushPipeline()`, public init for tests, and `@MainActor`-isolated `install(session:provider:syncService:)` / `tearDown()` methods. The decoder is lazily built on first `handle` call (using stored references).
- [ ] Add `MacPushPipelineTests`: install → state populated; tearDown → state cleared; handle-when-uninstalled returns no-op (assert via spy on a mock UNUserNotificationCenter).
- [ ] Run swift test — passes.

### Task 2: Wire AppDelegate `didReceiveRemoteNotification`

- [ ] Add `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` to `MatronMacAppDelegate`. Pulls `room_id` + `event_id` from `userInfo`; calls `MacPushPipeline.shared.handle(...)`. Calls system completion with `.newData` on success, `.failed` on error, `.noData` on missing IDs.
- [ ] Run-on-real-Mac sanity check: send a silent push via Smoke test step 4, observe local notification appears with title/body. (Defer to operator hardware availability if not running locally; the implementer's local testing flag is sufficient for the PR.)

### Task 3: `handle` decode + scheduling

- [ ] Implement `MacPushPipeline.handle(roomID:eventID:userInfo:completion:)`:
  - If pipeline uninstalled → call completion with `.noData`, return.
  - Build decoder via `PushDecoder.live(provider:session:processSetup: .singleProcess(syncService:))` (cached after first call).
  - Run `try await decoder.decode(roomID:eventID:)`. On success, schedule a `UNMutableNotificationContent` with `title = decoded.title`, `body = decoded.body`, `userInfo = ["room_id": roomID, "event_id": eventID]`, threadIdentifier from decoded if available else `roomID`. Trigger immediate (`UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)`).
  - On failure: log to os.Logger, call completion with `.failed`, do NOT schedule a fallback.
- [ ] Add MacPushPipelineTests: success path schedules with right userInfo + body; decode-failure path doesn't schedule + calls completion with `.failed`.

### Task 4: Bootstrap + sign-out wiring

- [ ] Update `MatronMacApp.bootstrapPush(for:)`: after the existing `bootstrap.register(token:)` call, build the syncService (`dependencies.syncService(for:)`) and call `MacPushPipeline.shared.install(session:, provider:, syncService:)`. Order matters — `install` AFTER register so a tap arriving mid-bootstrap routes to the existing handler before the pipeline is ready.
- [ ] Update `MatronMacApp.signOut(activeSession:)`: call `MacPushPipeline.shared.tearDown()` alongside the pusher unregister. Ordering: `MacNotificationHandler.shared.clearPendingRoomID()` first (drops any buffered tap), then `MacPushPipeline.shared.tearDown()` (drops decoder).

### Task 5: Doc updates

- [ ] `docs/push-setup.md` §"What's deferred": delete the "Mac silent-push body construction" paragraph.
- [ ] `docs/push-setup.md` §"Manual test walkthroughs" Walkthrough 5: drop the "body shows encrypted placeholder" caveat; add an explicit acceptance criterion for the decrypted-text body.
- [ ] `manual-tests.md` §"Mac — push delivery": drop the DEFERRED caveat at the section header; require decrypted text + sender name in the body.
- [ ] `docs/HANDOVER.md`: front-matter "What's deferred" list — strike through the Mac silent-push line; record completion in a new session log entry.

### Task 6: End-to-end manual test (operator-side)

> Requires Sygnal up + a real Mac signed in to a working homeserver.

- [ ] Operator runs Walkthrough 5 from `push-setup.md`. Body is the decrypted text + sender display name.
- [ ] Operator runs Walkthrough 6 (tap to open). Tap routes correctly.
- [ ] Operator runs Walkthrough 7 (cold-start tap on Mac). Tap-launch lands in the room.

---

## Risks + things to watch

- **Lifecycle race during a fast user switch.** AppDelegate.didReceiveRemoteNotification can fire while `tearDown()` is running on MainActor (both are MainActor-isolated, so they're serialized — but if `handle` has suspended on `decoder.decode`, a sign-out can land tearDown that nilifies `session` while `decode` is in flight). The captured local references inside `handle` should be fine (decoder holds its own SDK state via the captured ClientProvider). If the SDK call throws because the underlying session was torn down, the `failed` path takes over silently. Verify against a real device.

- **Sandbox + entitlements.** Release builds run sandboxed. `application(_:didReceiveRemoteNotification:)` works in sandbox per Apple's docs; the App Group entitlement for shared store access isn't needed because the Mac path reads from the host's own SDK store (no extension process). No new entitlements to add.

- **Decoder cache invalidation.** The pipeline caches the `PushDecoder` after first build. If the user switches accounts (sign-out → sign-in to a different account), `tearDown()` + `install()` rebuild the decoder. But: what if a notification fires AFTER `install` but BEFORE the previous sign-out's `tearDown` has fully nilified the cached decoder? The MainActor isolation makes this serializable — `install` always runs after `tearDown` completes. Pin this contract with a unit test.

- **Test surface for the SDK call.** `decoder.decode(roomID:eventID:)` requires a real `NotificationItem` from the SDK FFI. Unit tests can't fabricate one (same constraint that made Phase 4 Task 7 fixture tests SKIPPED). Coverage strategy: unit tests pin the orchestration (uninstalled → no-op, missing userInfo → completion with `.noData`, scheduled notification has the right `userInfo`); end-to-end coverage lives in the operator manual-test walkthroughs.
