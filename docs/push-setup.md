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
`PushConfig.appID` (`MatronShared/Sources/Push/PushConfig.swift`):

```yaml
apps:
  chat.matron.ios:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.app          # iOS host bundle ID
    use_sandbox: false              # production iOS (TestFlight + App Store)
    push_type: alert
  chat.matron.ios.dev:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.app
    use_sandbox: true               # iOS Debug builds (Xcode Run, simulator, ad-hoc)
    push_type: alert
  chat.matron.mac:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.mac          # Mac host bundle ID
    use_sandbox: false              # production Mac (Mac App Store + notarized)
    push_type: alert
  chat.matron.mac.dev:
    type: apns
    keyfile: /etc/sygnal/AuthKey_XXX.p8
    key_id: XXXXXXXXXX
    team_id: YYYYYYYYYY
    topic: chat.matron.mac
    use_sandbox: true               # Mac Debug builds (Xcode Run, locally signed)
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
`use_sandbox` (Debug → APNs sandbox, Release → APNs production).

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
double-check that `use_sandbox` on the matching Sygnal entry is
`false` — a stray `true` here is the single most common cause of
"push works on my dev build but not in TestFlight".

## Entitlements (client-side cross-check)

The app-side `aps-environment` entitlement value must match the
Sygnal `use_sandbox` flag for the same `app_id`:

| Build              | App-side entitlement                                | Sygnal `use_sandbox` |
|--------------------|-----------------------------------------------------|----------------------|
| iOS Debug          | `aps-environment = development`                     | `true`               |
| iOS Release        | `aps-environment = production`                      | `false`              |
| Mac Debug          | `com.apple.developer.aps-environment = development` | `true`               |
| Mac Release        | `com.apple.developer.aps-environment = production`  | `false`              |

**iOS uses `aps-environment`; macOS uses `com.apple.developer.aps-environment`**
— this is a longstanding macOS-only quirk per Apple's
[entitlements docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment).
Both Mac entitlement files (`MatronMac/App/MatronMac.entitlements`
for Release and `MatronMac/App/MatronMac.Debug.entitlements` for
Debug) use the namespaced form; the iOS entitlements (regenerated by
xcodegen from `project.yml`'s target-level entitlements block on the
`Matron` target) use the bare form.

## Cloudflare Tunnel

Add a route mapping `https://push.<domain>` → `http://127.0.0.1:5000`.
The pusher URL passed to `Client.setPusher(...)` from the iOS / Mac
host (currently a placeholder `https://sygnal.matron.example/_matrix/push/v1/notify`
— see `MatronApp.swift` and `MatronMacApp.swift` `pusherBaseURL`)
should be replaced with the real tunnel hostname when this lands.

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
`use_sandbox` matches the build type you're testing against.**

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
docker exec sygnal awk -v id="$APP_ID:" '$0 ~ id {found=1} found && /use_sandbox/ {print; exit}' /etc/sygnal.yaml
# Expect: use_sandbox: true   for a Debug/dev build of either platform
# Expect: use_sandbox: false  for a TestFlight / App Store / Mac App Store build

# 3a. iOS: cross-check by reading the embedded.mobileprovision from
#     the .ipa. The aps-environment value must pair with use_sandbox:
unzip -p Matron.ipa "Payload/Matron.app/embedded.mobileprovision" \
  | security cms -D \
  | plutil -extract aps-environment xml1 -o - -
# Expect: <string>development</string>  → must pair with use_sandbox: true
# Expect: <string>production</string>   → must pair with use_sandbox: false

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

**`pusherBaseURL` placeholder.** `MatronApp.swift` and
`MatronMacApp.swift` both hardcode
`https://sygnal.matron.example/_matrix/push/v1/notify`. Replace with
the real Cloudflare Tunnel hostname when the server-side infra
above lands.

**Phase 7 production entitlement split for iOS.** Today the iOS
host's entitlements are regenerated by xcodegen with a single
`aps-environment: development` value (suitable for Debug and TestFlight
dev provisioning). App Store releases will need the production form,
which is cleanest as a Debug/Release entitlement-files split mirroring
Mac's `MatronMac.Debug.entitlements` / `MatronMac.entitlements`
arrangement. Defer until Phase 7 wires App Store distribution.
