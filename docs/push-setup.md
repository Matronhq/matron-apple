# Push setup runbook

Server-side configuration required for APNs push to reach Matron on
iOS and Mac. This is the operational counterpart to the client-side
Phase 4 work that landed on PR #5; **none** of the app code can be
exercised end-to-end until Sygnal is reachable + APNs auth keys are
in place + a real device is paired (the iOS Simulator and Mac unit-
test bundles can't receive APNs).

## Components

```
APNs ──▶ Sygnal (HTTP pusher) ──▶ Tuwunel (matron-server) ──▶ Matron iOS NSE / Mac in-process delegate
```

`PushService` (in `MatronShared/Sources/Push/PushService.swift`) writes
the pusher row on the user's homeserver via the SDK's
`Client.setPusher(...)`. The homeserver calls Sygnal's `/notify`
endpoint when a notify-action event lands; Sygnal forwards to APNs.

## Apple side

1. In the Apple Developer Portal, create a Key with **Apple Push
   Notifications service (APNs)** enabled.
2. Download the `.p8` keyfile. Note the Key ID and Team ID.
   - **One key covers both iOS and Mac** for the same team — Sygnal's
     four app entries below all reference the same `.p8`.
3. Confirm the App IDs are configured for push:
   - `chat.matron.app` (iOS host)
   - `chat.matron.app.nse` (iOS NSE — push delivery doesn't go here
     directly, but the NSE needs the same Team ID)
   - `chat.matron.mac` (Mac host)

## Sygnal

> **2026-06-12:** a live Sygnal already runs on dev-2, Chef-managed by
> the `dev_server::sygnal` recipe in `yearbook-infra` (apps list comes
> from the `dev_server.sygnal.apps` node attribute; APNs key
> `JKB3Z5DFZN` lives in the encrypted `development` data bag). It
> currently serves Matron X (`chat.matron.x.ios.{prod,dev}`); add this
> app's four entries there rather than standing up a second instance.

Run upstream Sygnal — Apache 2.0, no fork needed.

```bash
docker run -d --name sygnal \
  -p 5000:5000 \
  -v $(pwd)/sygnal.yaml:/etc/sygnal.yaml:ro \
  -v $(pwd)/auth_key.p8:/etc/sygnal/AuthKey_XXX.p8:ro \
  matrixdotorg/sygnal:latest
```

`sygnal.yaml` — **four app entries**, one per (platform × build-type).
The `app_id` keys MUST match the four-way switch in
`PushConfig.appID` (`MatronShared/Sources/Push/PushConfig.swift`).
The `http` block is required — without it Sygnal binds to localhost
inside the container and Docker's published port can't reach it:

```yaml
http:
  bind_addresses: ['0.0.0.0']
  port: 5000

apps:
  chat.matron.ios:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.app          # iOS host bundle ID
    platform: production            # production iOS (TestFlight + App Store)
    push_type: alert
  chat.matron.ios.dev:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.app
    platform: sandbox               # iOS Debug builds (Xcode Run, simulator, ad-hoc)
    push_type: alert
  chat.matron.mac:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.mac          # Mac host bundle ID
    platform: production            # production Mac (Mac App Store + notarized)
    push_type: alert
  chat.matron.mac.dev:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.mac
    platform: sandbox               # Mac Debug builds (Xcode Run, locally signed)
    push_type: alert
log:
  setup:
    version: 1
    formatters:
      precise: { format: '%(asctime)s [%(process)d] %(levelname)-5s %(name)s - %(message)s' }
    handlers:
      console: { class: logging.StreamHandler, formatter: precise, level: DEBUG }
    root: { handlers: [console], level: DEBUG }
```

All four entries reference the same `.p8` keyfile (one APNs auth key
covers the whole team) but split on `topic` (bundle ID) and
`platform` (Debug → `sandbox`, Release → `production`).

### APNs sandbox vs production

TestFlight, App Store, and notarized Mac App Store builds use the
production APNs endpoint. Debug builds on either platform (Xcode Run,
iOS simulator deploys, ad-hoc development provisioning profiles,
locally-signed Mac builds) use sandbox. Mismatched configs produce
silent push failures — Sygnal accepts the request, APNs returns
`BadDeviceToken` for the wrong endpoint, and the user simply never
sees a notification.

Each app build picks the right `app_id` at compile time via
`PushConfig.appID`'s `#if os(iOS)` / `#if os(macOS)` × `#if DEBUG`
switch. Whenever you cut a TestFlight or Mac App Store build,
double-check that `platform` on the matching Sygnal entry is
`false` — a stray `true` here is the single most common cause of
"push works on my dev build but not in TestFlight".

## Entitlements (client-side cross-check)

The app-side `aps-environment` entitlement value must match the
Sygnal `platform` value for the same `app_id`:

| Build              | App-side entitlement                                | Sygnal `platform` |
|--------------------|-----------------------------------------------------|----------------------|
| iOS Debug          | `aps-environment = development`                     | `sandbox`            |
| iOS Release        | `aps-environment = production`                      | `production`         |
| Mac Debug          | `com.apple.developer.aps-environment = development` | `sandbox`            |
| Mac Release        | `com.apple.developer.aps-environment = production`  | `production`         |

**iOS uses `aps-environment`; macOS uses `com.apple.developer.aps-environment`**
— this is a longstanding macOS-only quirk per Apple's
[entitlements docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment).
Both Mac entitlement files (`MatronMac/App/MatronMac.entitlements`
for Release and `MatronMac/App/MatronMac.Debug.entitlements` for
Debug) use the namespaced form; the iOS entitlements (regenerated by
xcodegen from `project.yml`'s target-level entitlements block on the
`Matron` target) use the bare form.

## Cloudflare Tunnel

Add a route mapping `https://sygnal.matron.chat` → `http://127.0.0.1:5000`
(Sygnal's default listen port). The pusher URL the client writes
into the homeserver's pusher record is hardcoded as
`https://sygnal.matron.chat/_matrix/push/v1/notify` in both
`Matron/App/MatronApp.swift` and `MatronMac/App/MatronMacApp.swift`
(`pusherBaseURL`); the hostname must resolve to the Cloudflare
Tunnel and the tunnel must terminate to the running Sygnal
container, otherwise the homeserver's outbound POSTs from
`tuwunel`/Synapse to Sygnal will surface as DNS or 5xx errors in
the homeserver logs.

## matron-server (Tuwunel)

No specific config required — pushers are per-user, written by the
client via `POST /_matrix/client/v3/pushers` (which the SDK
`Client.setPusher(...)` wraps). Confirm the server is publishing
push rules: a user's `_matrix/client/v3/pushrules` should include
`.m.rule.master` enabled by default; if a user explicitly disables
it, that's deliberate and PushBootstrap doesn't override (see
`PushBootstrap.swift`'s doc-comment for the full rationale).

## Smoke test

**Pre-flight: verify all four app entries are present, AND that
`platform` matches the build type you're testing against.**

```bash
# 1. All four app_ids must be present in the running config:
docker exec sygnal grep -E "^  chat\.matron\.(ios|mac)(\.dev)?:" /etc/sygnal.yaml
# Expect four matching lines:
#   chat.matron.ios:, chat.matron.ios.dev:,
#   chat.matron.mac:, chat.matron.mac.dev:
# A missing entry is a hard fail — Sygnal will respond 200 with
# {"rejected": ["<token>"]} and no APNs traffic ever leaves the host.

# 2. Sandbox flag for the specific app_id we're about to hit:
APP_ID=chat.matron.ios.dev    # or .ios, .mac, .mac.dev — pick one per smoke run
docker exec sygnal awk -v id="$APP_ID:" '$0 ~ id {found=1} found && /platform/ {print; exit}' /etc/sygnal.yaml
# Expect: platform: sandbox      for a Debug/dev build of either platform
# Expect: platform: production   for a TestFlight / App Store / Mac App Store build

# 3a. iOS: cross-check by reading the embedded.mobileprovision from
#     the .ipa. The aps-environment value must pair with platform:
unzip -p Matron.ipa "Payload/Matron.app/embedded.mobileprovision" \
  | security cms -D \
  | plutil -extract aps-environment xml1 -o - -
# Expect: <string>development</string>  → must pair with platform: sandbox
# Expect: <string>production</string>   → must pair with platform: production

# 3b. Mac: read com.apple.developer.aps-environment out of the signed
#     .app's entitlements (note the macOS-namespaced key — iOS uses
#     the bare aps-environment instead):
codesign -d --entitlements :- MatronMac.app 2>/dev/null \
  | plutil -extract com.apple.developer.aps-environment xml1 -o - -
# Expect the same development/production string with the same pairing.
```

Mismatched values are a hard fail — abort the smoke test and fix the
Sygnal config (or rebuild the IPA / `.app` with the correct
provisioning profile) before sending traffic.

```bash
# 4. Live cURL: send a push through the full pipeline. Run once per
#    platform you're testing (substitute app_id + pushkey).
curl -i -X POST https://push.example.com/_matrix/push/v1/notify \
  -H 'Content-Type: application/json' \
  -d '{
    "notification": {
      "event_id": "$test:example.com",
      "room_id": "!test:example.com",
      "type": "m.room.message",
      "sender": "@test:example.com",
      "counts": { "unread": 1 },
      "devices": [{
        "app_id": "chat.matron.ios.dev",
        "pushkey": "<APNS_TOKEN_HEX>",
        "data": { "format": "event_id_only" }
      }]
    }
  }'
```

A `200 OK` with `{"rejected":[]}` means Sygnal accepted the push and
forwarded to APNs. A `200` with `{"rejected": ["<pushkey>"]}` means
APNs rejected the token — most likely a sandbox/production mismatch.
A non-200 means Sygnal itself rejected the request shape (config
parse error, missing keyfile, etc.) — check the Sygnal container
logs.

## What's wired in the app today (PR #5)

- iOS NSE intercepts silent payloads, decrypts the event via
  `PushDecoder`, rewrites the notification body. Apple's
  `UNNotificationServiceExtension.withContentHandler` makes the
  rewrite take effect at display time.
- Mac handler: tap-to-open routing (notification tap → `.matronOpenRoom`
  → `MacChatListView` selects the room), foreground presentation
  options, APNs token capture, bootstrap, sign-out unregister. The
  `aps-environment` entitlement for both Debug and Release.
- Cross-platform: `PushConfig` (four-way `app_id`), `PushService` /
  `PushServiceLive` (writes pusher row via `Client.setPusher`),
  `PushBootstrap` (permission, per-room `.allMessages`, register-for-
  remote, register-token), `PushTokenStore` (token cache + serialised
  push-operation chain), `NotificationDelegate` (iOS) /
  `MacNotificationHandler` (Mac).

## What's deferred

**Mac silent-push body construction.** Apple's
`UNUserNotificationCenter.userNotificationCenter(_:willPresent:withCompletionHandler:)`
completion handler only takes presentation options, not modified
content — any mutation made there is dropped. Mac's equivalent of
iOS NSE rewrite is to handle the silent payload in
`NSApplicationDelegate.application(_:didReceiveRemoteNotification:)`,
decode the event via `PushDecoder.live(processSetup: .singleProcess(syncService:))`,
and schedule a fresh local `UNNotificationRequest` with the
cleartext body. That pipeline needs (a) the decoder lazy-installed
onto the app delegate (chicken-and-egg with session restore),
(b) end-to-end validation against a real Sygnal, and (c) a design
pass on lifecycle / error surfacing. Track in a
`phase-4-mac-silent-push` followup.

**Live Sygnal at `sygnal.matron.chat`.** `MatronApp.swift` and
`MatronMacApp.swift` both hardcode
`https://sygnal.matron.chat/_matrix/push/v1/notify` as the pusher
URL. The hostname is the production target served via Cloudflare
Tunnel from the box that runs `matron-server`; end-to-end push
delivery still depends on (a) the Sygnal container being up,
(b) APNs `.p8` auth credentials provisioned in Sygnal's config
for all four `app_id`s, (c) DNS resolving the hostname. Until
(a)–(c) are in place, `bootstrap.register(token:)` writes the
pusher row successfully — the homeserver accepts any URL — and
then logs DNS-resolution failures when it tries to deliver.

**Phase 7 production entitlement split for iOS.** Today the iOS
host's entitlements are regenerated by xcodegen with a single
`aps-environment: development` value (suitable for Debug and TestFlight
dev provisioning). App Store releases will need the production form,
which is cleanest as a Debug/Release entitlement-files split mirroring
Mac's `MatronMac.Debug.entitlements` / `MatronMac.entitlements`
arrangement. Defer until Phase 7 wires App Store distribution.

## Manual test walkthroughs

These walkthroughs are written for the operator standing up Sygnal
+ a real device for the first time. Each one names the expected
side-effect in the system unified log + the failure mode on the
opposite side. **The Smoke test cURL chain above is the
prerequisite** — if step 4 of that chain returns `{"rejected":
["<token>"]}` or the live device never sees a notification, none of
the below will pass either; fix Sygnal/APNs first.

The whole-pipeline state to inspect across a walkthrough:
- **Device unified log:** `log stream --predicate 'subsystem == "chat.matron"'` on the live host (Mac) or Console.app filtered by process for an iOS device. Surfaces every PushBootstrap / PushServiceLive / NotificationDelegate / MacNotificationHandler step the SDK tracing setup wires up.
- **Sygnal log:** journal output of the running container; surfaces "Notification delivered to APNs" / "Rejected by APNs (BadDeviceToken / InvalidProviderToken / TopicDisallowed)" lines.
- **matron-server pusher list:** `curl -H "Authorization: Bearer <admin>" https://<homeserver>/_synapse/admin/v1/users/<userID>/pushers | jq` (Tuwunel exposes the same shape as Synapse). One row per `(pushkey, app_id)` tuple.

### Walkthrough 1 — first-time iOS push wire-up (real device)

1. Install a Debug build of `Matron.app` on a real iOS device via
   Xcode. Cold-launch.
2. Sign in to a test account (`@manual-push-test:<homeserver>`) +
   complete verification. The post-verify `.task(id: session.userID)`
   fires `bootstrapPush(for:)`.
3. iOS surfaces the system notification permission prompt — accept.
   - **Failure mode:** prompt never appears → check the
     `aps-environment` entitlement is in the signed `.ipa`
     (`unzip -p Matron.ipa Payload/Matron.app/embedded.mobileprovision
     | security cms -D | plutil -p -` and look for
     `aps-environment: development`).
4. Within ~1s the device log shows
   `PushTokenStore.setToken(...)` followed by
   `PushServiceLive.registerToken` posting to the Sygnal URL.
5. Query matron-server's pusher list: a fresh row should appear with
   `app_id: chat.matron.ios.dev`, `pushkey: <hex device token>`,
   `kind: http`, `data.url:
   https://<sygnal-host>/_matrix/push/v1/notify`.
   - **Failure mode:** no row → Sygnal returned non-200 (check
     Sygnal logs); pushkey malformed (`PushTokenStore` uses lowercase
     hex with no separators — pin in `PushServiceLive.registerToken`).
6. From a second account on a second device, send `Hello push` to
   the test account's bot room.
7. The first device receives a silent-push payload. The NSE wakes:
   log shows `MatronSDKTracing.setup` (one-shot init), then
   `PushDecoder.live` fetching + decrypting the event, then
   `NotificationService.deliver(decoded:...)` rewriting the body.
8. Lock-screen banner shows the decrypted body (`Hello push`)
   + sender display name in the title.
   - **Failure mode (encrypted placeholder visible):** NSE didn't
     run or didn't decrypt. Filter the device log on
     `subsystem == "chat.matron" AND category == "PushDecoder"` to
     see the decrypt error. Common cause: NSE's App-Group
     entitlement (`group.chat.matron`) doesn't match the host's, so
     the NSE can't read the host's SDK store.

### Walkthrough 2 — tap-to-open deep link (iOS)

1. With the Matron.app backgrounded (home button / swipe up), send
   another test message.
2. Tap the notification banner from the lock screen / Notification
   Center.
3. App resumes; the chat-list NavigationStack pushes directly to
   the room.
   - Internals: `NotificationDelegate.didReceive` lands; the room ID
     is stashed in `pendingRoomID` AND published via
     `tappedRoomID`; the `.onReceive(tappedRoomID)` subscriber on
     the post-verify branch appends to `chatPath`.
   - **Failure mode (lands at chat list root):** `room_id` missing
     from `userInfo`. The NSE's `deliver(decoded:roomID:eventID:)`
     copies the IDs out of the decoded payload back into
     `content.userInfo` for exactly this reason — if it didn't,
     the tap fires but `tappedRoomID` never publishes.

### Walkthrough 3 — cold-start tap (iOS)

1. Force-quit Matron.app (multitasking switcher → swipe up).
2. Send a test message + tap the notification.
3. iOS launches Matron.app specifically because of the tap; first
   render lands directly in the room.
   - Internals: `NotificationDelegate.didReceive` runs BEFORE the
     SwiftUI tree mounts, so the `.onReceive(tappedRoomID)`
     subscriber isn't there to receive the publish. The
     `pendingRoomID` buffer survives that gap; the post-verify
     `.task(id: session.userID)` calls `consumePendingRoomID()` on
     mount and appends to `chatPath`.
   - **Failure mode:** lands at chat list root with no deep-link.
     The cold-start path was specifically the bug cursor PR #5
     pass-1 finding "cold-start taps get dropped" caught — verify
     `consumePendingRoomID` is being called by setting a breakpoint
     in `Matron/App/MatronApp.swift:177`.

### Walkthrough 4 — sign-out → sign-in cycle (iOS)

1. With account A signed in, confirm a pusher row exists in
   matron-server for `(pushkey, chat.matron.ios.dev)`.
2. Sign out via Settings (Phase 7 wires the Settings UI; Debug
   builds can use the menu hook).
3. Within ~5s the pusher row should disappear.
   - Internals: `signOut()` reads
     `PushTokenStore.shared.cachedToken` and enqueues an
     `unregister(...)` onto the shared serialised chain.
   - **Failure mode (row persists):** the unregister fired against
     the wrong pusherBaseURL or a stale ClientProvider. The
     `enqueuePushOperation` closure captures provider + session
     up-front (the host signOut path documents this); confirm the
     captured provider is alive when the chain runs.
4. Sign in to account B (different `@user:homeserver`). Within ~1s
   a fresh pusher row appears for B.
5. From a third account, send messages to BOTH A's and B's bot
   rooms. Only B's notification should arrive on the device — A's
   pusher is gone.
   - **Failure mode (A's notification arrives):** the unregister
     didn't actually land server-side (Sygnal returned non-200, or
     matron-server rejected it). Worse: the pusher row for A still
     exists AND a row for B exists; both will fire. Check the
     pusher list and force-delete A's via the homeserver admin API.

### Walkthrough 5 — first-time Mac push wire-up

Same shape as Walkthrough 1 but on macOS. Two important deltas:
- Run a Debug build of `MatronMac.app` (sandbox is disabled in
  Debug per the spec; Release builds re-enable sandbox + use the
  `production` `aps-environment`).
- The `app_id` written to the pusher row is `chat.matron.mac.dev`
  (Debug) or `chat.matron.mac` (Release), NOT the iOS variants.
  Sygnal must have all four `app_id`s configured (Smoke test step 1
  pins this).
- **Cleartext body in notification: NOT yet supported.** The Mac
  silent-push body construction path is deferred (see "What's
  deferred" above). Today the user sees the encrypted-placeholder
  body APNs delivers; the room ID + sender are still in `userInfo`
  for tap routing, but the visible body until Sygnal-side body
  injection or the deferred local-notification rewrite lands is the
  raw placeholder.

### Walkthrough 6 — notification tap on Mac (multi-app open)

1. With MatronMac backgrounded behind another app, send a test
   message.
2. Click the notification in Notification Center / banner.
3. MatronMac activates and the main window flips forward;
   `MacChatListView`'s sidebar selects the matching chat (detail
   column flips to render it).
   - Internals: `MacNotificationHandler.didReceive` →
     `handleTap(userInfo:)` → `NSApp.activate` +
     `window.makeKeyAndOrderFront` + `NotificationCenter` post
     (`.matronOpenRoom`); `MacChatListView.onReceive` flips
     `selectedSummaryID`.
   - **Failure mode (window comes forward but no chat selected):**
     `room_id` missing from userInfo (same iOS fix applies — the
     `userInfo` flows from APNs payload to the silent-push handler
     to the local notification, OR from the local-notification
     `userInfo` directly when the deferred Mac decoder lands).

### Walkthrough 7 — cold-start tap on Mac

1. Quit MatronMac (`⌘Q`).
2. Send a test message + click the notification.
3. macOS launches MatronMac specifically because of the click;
   first render of `MacChatListView` lands selected on the room.
   - Internals: `MacNotificationHandler.handleTap` runs BEFORE
     SwiftUI mounts, so `.onReceive(matronOpenRoom)` isn't there
     to receive the post. The new `pendingRoomID` buffer (added in
     `e4bf65a`) survives that gap; `MacChatListView.task` calls
     `consumePendingRoomID()` on first appearance and writes to
     `selectedSummaryID`.
   - **Failure mode:** lands at chat list root. Verify the
     `MacNotificationHandler.shared` singleton is actually wired
     as the UN delegate in `MatronMacAppDelegate.applicationDidFinishLaunching`
     — the delegate-stored-property shape (pre-`e4bf65a`) made the
     buffer unreachable from the view layer.

### Walkthrough 8 — permission denied path (both platforms)

1. Decline the system permission prompt on first run.
2. Confirm bootstrap returns `false` and no pusher row is written.
   - Internals: `PushBootstrap.bootstrap()` short-circuits on
     `!granted` BEFORE `setPerRoomNotificationMode` /
     `registerForRemoteNotifications`; `register(token:)` is
     never reached because the host's `bootstrapPush` guards on
     `granted`.
3. Send a test message — no notification arrives. Expected.
4. The next launch should NOT re-prompt (iOS / macOS cache the
   decision). To re-test, reset notification permission via
   `xcrun simctl privacy <UDID> reset all chat.matron.app` (sim)
   or System Settings → Notifications → Matron → toggle off → on
   (real device).
5. Once permission is granted in System Settings, the next launch's
   `.task(id: session.userID)` re-runs bootstrap and writes the
   pusher row.

### Walkthrough 9 — sandbox vs production cross-check (operator-side)

Before submitting a TestFlight or App Store build:
1. Confirm the `app_id` in `PushConfig.swift` matches the build
   configuration (Debug → `chat.matron.{ios,mac}.dev`; Release →
   `chat.matron.{ios,mac}`). Pinned by `PushConfigTests`.
2. Confirm the matching `app_id` in Sygnal's config has
   `platform: sandbox` (dev) or `production` per the
   Smoke test step 2 cross-check.
3. Confirm the signing profile's `aps-environment` value pairs
   correctly: `development` ↔ sandbox, `production` ↔ production
   (Smoke test steps 3a/3b pin this).
4. **Mismatch failure mode:** Sygnal forwards to production APNs
   but the device is signed with a development profile (or vice
   versa). APNs returns `BadDeviceToken`; the user sees no
   notification and Sygnal's logs show the error. The mismatch
   is silent on the client — there's no Swift-side check that
   would catch a sandbox/production mis-pairing. Phase 7's App
   Store-prep checklist should re-run this walkthrough against
   the production profile + production Sygnal config before
   first submission.
