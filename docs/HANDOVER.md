# Handover — Matron iOS+Mac, Phase 3 + integration harness

**As of 2026-05-04**, end of a long debug + build session. This document
catches a fresh session up so it can keep going without re-deriving
everything.

---

## TL;DR

- **PR #3** (`phase-3-e2ee-verification` → `main`) carries Phase 3 (E2EE +
  verification UX) **plus** seven post-Phase-3 fix-up waves built around
  expert-QA + bugbot findings + live debugging against a real homeserver.
  Latest SHA: `b0e3f4f`. CI on main was last green at PR #3 wave 6.
- **SAS verification works end-to-end** for the requester path against a
  real partner client (live-validated: emojis appeared on both sides,
  user pressed Yes on Mac, partner pressed Yes, both sides got
  `verificationStateListener: fired with verified`). This was the final
  bug in Wave 7's Element-X-aligned rewrite.
- **Two real, unrelated regressions are open**:
  1. **Empty chat list after fresh sign-in on Mac** — sync seems to not
     deliver rooms. Existed pre-Wave-7 too. Not yet diagnosed.
  2. **No visible feedback on the "Verify with another device" tap** —
     minor UX (button doesn't show pressed state). Post-Wave-7.
- **Integration harness scaffolded** under `tests/integration/`:
  Docker matron-server + Node `matrix-js-sdk` partner with full
  cross-signing + recovery key bootstrap + auto-SAS-confirm. Foundation
  proven (homeserver boots, partner becomes a real trust anchor in
  ~10s). UI driver layer is the open piece — XCUITest blocked on Mac
  App Sandbox + runner-connection issue, AppleScript fallback works
  interactively but not headless from a non-GUI shell.

---

## Current state of PR #3

Branch: `phase-3-e2ee-verification`. Open at https://github.com/Matronhq/matron-iOS-app/pull/3.

### Wave history (newest first)

```
b0e3f4f test: harness scenario v1 (AppleScript-driven) + XCUITest scaffolding   ← in-flight
94f3666 test: rewrite partner client in matrix-js-sdk (mirrors add-bot.mjs)
f911f57 test: integration harness scaffolding (homeserver + partner + scenario)
76b8bd4 fix(wave-7): rewrite verification per Element X iOS pattern
fcf2afa fix(wave-5): bugbot PR-#3 — 5 findings (2 critical)
315ae26 fix(wave-6): Mac chrome + UX fixes (post-Wave-5 backlog)
2d315ab fix(wave-3): pin Keychain access group + iOS bootstrap probe (B3+M1)
9c3725a fix(wave-2): hoist VerificationCenter, drain replaced continuations, tri-state isUserVerified
60e65ee fix(B1): wire SDK delegate so SAS verification works end-to-end
d98c660 fix(M4): accept both env-var names for snapshot-skip on Mac CI
… plus 17 prior implementation commits for Phase 3 itself
```

### Test counts (last green)

- **SPM:** 224 (4 skipped — those need iCloud Keychain entitlement the
  SPM host doesn't have)
- **iOS scheme:** 53
- **Mac scheme:** 66

Run with:
```bash
cd MatronShared && swift test
cd /Users/danbarker/Dev/matron-iOS-app && xcodebuild test -scheme Matron \
    -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
cd /Users/danbarker/Dev/matron-iOS-app && xcodebuild test -scheme MatronMac \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1
```

### Per-wave summary (what each wave fixed)

- **Phase 3 itself** (17 tasks across 26 commits): plumbed verification +
  recovery + onboarding gate + per-bot banner + Mac menu wiring +
  Keychain probe. See `docs/phase-3-progress.md` for per-task notes.
- **Wave 1**: B1 SDK delegate wiring (then incomplete) + M4 snapshot CI
  env-var dual-naming.
- **Wave 2**: B2/M5 hoist VerificationCenter + per-bot SasViewModel to
  `@State`, M3 drain replaced FlowStore continuations, M2 tri-state
  `isUserVerified`.
- **Wave 3**: B3+M1 Keychain access group (later partly reverted in
  Wave 5) + iOS Keychain probe.
- **Wave 4**: 8 minor expert-QA findings cleanup pass.
- **Wave 5**: 5 critical bugbot findings — including the
  `$(AppIdentifierPrefix)` literal that broke signed builds, and the
  side-effectful `service.startSAS(...)` in 7 wrapper view inits that
  cancelled the live SAS flow on every parent re-render.
- **Wave 6**: Mac UX live-test feedback — File→Sign Out / Help menu
  listeners moved into active-branch view (the WindowGroup-root Group
  type-switch was eating Combine subscriptions); new
  `MacUnverifiedDeviceBanner` + `UnverifiedDeviceBanner` for
  pre-Phase-3 users; removed duplicate sidebar toggle + "Matron" label.
- **Wave 7** (the big one): rewrote verification per Element X iOS
  patterns — lazy controller via `verificationStateListener`, single
  weak-wrapped delegate, `recoverAndFixBackup` instead of bare
  `recover`, requester-vs-responder role tracking on FlowStore.

---

## What we know works (live-validated)

- **Sign-in** against `http://localhost:6167` (test homeserver) and
  `https://matrix-dev2.yearbooks.be` (the user's dev box).
- **SAS "verify with another device"** end-to-end. Trace template:
  ```
  verificationStateListener: fired with unverified
  startSAS: enter
  SDK→didReceiveVerificationData (emojis count: 7)
  routeSasFinished: yielding .verified
  verificationStateListener: fired with verified
  ```
- **Partner-side bootstrap** (`tests/integration/partner/partner.mjs
  bootstrap-anchor`) yields a working recovery key in ~10s and uploads
  cross-signing keys + activates a backup.
- **Recovery key restore** API call succeeds (with Wave 7's
  `recoverAndFixBackup`) — but historical decryption hasn't been
  retested live since the user reported empty chats post-Wave-7.

## What's broken / unknown

1. **Empty chat list on fresh sign-in (Mac)**. Pre-existed Wave 7. The
   user signed in → list was empty → tapped Verify → SAS worked → list
   still empty. New messages decrypt fine elsewhere, suggesting sync
   delivers events but the chat-list query path is broken. NOT YET
   DIAGNOSED. Suspect: `ChatService.chatSummaries()` AsyncStream isn't
   getting initial-sync rooms, or the snapshot polling is broken on
   the new build. Add `os.Logger` to `SyncServiceLive` + `ChatServiceLive`
   to find out.

2. **No visual feedback on Mac "Verify with another device" tap**.
   Button doesn't appear pressed when clicked. Click is registered
   (verification flow starts), just no visual state. Minor.

3. **iOS sim flows** (last live-tested before Wave 7): "Use recovery
   key" bounced; "Verify with another device" crashed in
   `NavigationColumnState.boundPathChange`. Wave 7 + Wave 5 fixes very
   likely fixed both — they came from the same root causes (the
   `$(AppIdentifierPrefix)` literal and the side-effectful init).
   **Not retested live post-Wave-7.**

4. **XCUITest+Mac App Sandbox** — runner hangs 5+ minutes establishing
   connection. Wave 7+ adds per-config entitlements
   (`MatronMac.Debug.entitlements` drops sandbox) but that hasn't been
   end-to-end validated yet. Last attempted scenario fell back to
   AppleScript.

---

## Integration harness — what's there

```
tests/integration/
├── README.md                          ← prereqs + usage + caveats
├── docker/docker-compose.yml          ← matron-server (tuwunel) on :6167
├── partner/
│   ├── package.json                   ← matrix-js-sdk@41 + crypto-wasm@15
│   ├── partner.mjs                    ← Node CLI (mirrors add-bot.mjs)
│   └── package-lock.json
├── scenarios/
│   └── verify-mac-against-partner.sh  ← v1 AppleScript-driven
└── run-harness.sh                     ← orchestrator
```

### Harness components — verified working

- **Docker matron-server**: `ghcr.io/matronhq/matron-server:latest` boots
  on `127.0.0.1:6167` with `TUWUNEL_ALLOW_REGISTRATION=true` +
  `TUWUNEL_REGISTRATION_TOKEN=matron-test-only`. Federation off. Pull
  needs `gh auth token | docker login ghcr.io -u danbarker --password-stdin`.
- **Partner client** (`partner.mjs`): registers, logs in, bootstraps
  SSSS + cross-signing + recovery key, listens for incoming SAS,
  auto-confirms on `VerifierEvent.ShowSas`. Mirrors
  `claude-matrix-bridge/add-bot.mjs`.
- **`run-harness.sh`**: tears down + boots fresh homeserver, registers
  `matron` and `partner` users, bootstraps the partner trust anchor.
  Hands off to a scenario or stays up for ad-hoc testing.

### Open piece: UI driver

Two paths attempted, both with caveats:

- **XCUITest** (`MatronMacUITests/VerifyWithPartnerUITests.swift`):
  fully written, scheme wired (`project.yml` `scheme.testTargets`).
  Blocked on **App Sandbox + UI testing** — XCUITest runner can't
  establish XPC connection to the sandboxed host, hangs ~5min.
  **Latest fix attempt (committed in `b0e3f4f`)**: per-config
  `CODE_SIGN_ENTITLEMENTS` so Debug uses
  `MatronMac.Debug.entitlements` (drops `app-sandbox`). **Not yet
  re-tested.** Next step: `xcodegen && xcodebuild build-for-testing
  -scheme MatronMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`,
  then run the scenario again.
- **AppleScript** (`scenarios/verify-mac-against-partner.sh` v1):
  works in an interactive session if Terminal/Claude has Accessibility
  permission. Doesn't work from Claude Code's Bash tool — `open` runs
  but the Mac app doesn't actually launch the SwiftUI Scene in that
  context. Verifying that interactively requires a real terminal.

### Accessibility identifiers (already plumbed)

For when XCUITest works:

- `signin.server`, `signin.username`, `signin.password`, `signin.submit`
- `verifygate.verifyWithOtherDevice`, `verifygate.useRecoveryKey`,
  `verifygate.generateNew`
- `sas.match`, `sas.dontMatch`

---

## Where to pick up

In rough priority order:

### 1. Validate Wave 7's per-config entitlements (XCUITest unblock)

```bash
xcodegen
xcodebuild build-for-testing -scheme MatronMac \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Should succeed without the previous `app-sandbox` issues. Then:

```bash
docker info >/dev/null  # make sure Docker is up
gh auth token | docker login ghcr.io -u danbarker --password-stdin
tests/integration/run-harness.sh verify-mac-against-partner.sh
```

If XCUITest now works, swap `verify-mac-against-partner.sh` to the
XCUITest variant (`xcodebuild test-without-building -only-testing:
MatronMacUITests/...`) — the previous version of that script is in
git history at SHA `94f3666`.

### 2. Diagnose the empty-chats regression

Add `os.Logger` instrumentation to `SyncServiceLive` (and
`ChatServiceLive` if needed) — same pattern as
`VerificationServiceLive.start()`:

```swift
import os
private static let logger = os.Logger(subsystem: "chat.matron", category: "sync-live")
// then logger.notice("…") at: start enter/exit, sync.state changes, room snapshots
```

Then:

```bash
tests/integration/run-harness.sh   # leave homeserver up
# In another terminal:
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' \
    --style compact --level info
```

Sign in as `matron` / `matron-test-pw` against `http://localhost:6167`.
Watch the trace. Likely root cause: sync starts but the snapshot poll
misses initial-sync rooms, or the `chatSummaries()` AsyncStream isn't
re-firing on first sync settle.

### 3. Verify iOS flows post-Wave-7

iOS sim wasn't retested after Wave 7. With the matron-server harness
running:

```bash
xcodebuild -scheme Matron -configuration Debug \
    -destination 'platform=iOS Simulator,id=337C3A3A-4191-4A51-9513-93F5805276EC' \
    build CODE_SIGNING_ALLOWED=NO
xcrun simctl uninstall 337C3A3A-4191-4A51-9513-93F5805276EC chat.matron.app
xcrun simctl install 337C3A3A-4191-4A51-9513-93F5805276EC \
    "$HOME/Library/Developer/Xcode/DerivedData/Matron-bxmhcklltdsxiccbqjrvsvbdiubi/Build/Products/Debug-iphonesimulator/Matron.app"
xcrun simctl launch 337C3A3A-4191-4A51-9513-93F5805276EC chat.matron.app
```

Sign in as `matron` against the Docker homeserver. Try recovery key
flow + verify-with-another-device. If they no longer crash/bounce,
Wave 7 fully fixes the iOS bugs.

### 4. Decide on PR #3 disposition

PR #3 has accumulated 7 fix-up waves on top of the Phase 3 base. It's
substantial but coherent (each wave is self-contained). Two options:

- **Merge as-is** once the empty-chats bug is fixed. Phase 3 ships,
  open issues become Phase 4 work.
- **Split into stacked PRs** for cleaner review history. Phase 3
  base, then Wave 1-7 as separate stacked PRs. More work, more
  reviewable.

User's stated preference earlier was to merge stacked when possible
but they accepted squash for PR #1 (Phase 2). I'd vote merge-as-is.

### 5. Long-running: build a CI hook for the harness

After XCUITest works locally, wire it into a GitHub Actions workflow.
Will need a self-hosted Mac runner (the harness drives Mac UI), or a
GitHub-hosted macOS runner with Docker (which costs $$).

---

## Useful state / paths

- **Repo**: `/Users/danbarker/Dev/matron-iOS-app`
- **Element X iOS** (verification reference): `/Users/danbarker/Dev/yearbook-messages-ios/ElementX`
- **claude-matrix-bridge** (add-bot.mjs reference): `/Users/danbarker/Dev/claude-matrix-bridge`
- **matron-server source**: `/Users/danbarker/Dev/matron-server`
- **Matron Mac app** (after build): `~/Library/Developer/Xcode/DerivedData/Matron-bxmhcklltdsxiccbqjrvsvbdiubi/Build/Products/Debug/MatronMac.app`
- **Mac sim ID**: `337C3A3A-4191-4A51-9513-93F5805276EC` (iPhone 17)
- **Test homeserver**: `http://localhost:6167` (Docker)
- **Test users**: `matron` / `matron-test-pw`, `partner` / `partner-test-pw`
- **Real homeserver**: `https://matrix-dev2.yearbooks.be` (user has accounts there)
- **Crash report from iOS sim** (still in repo root): `ios-crash-report.txt`
  — pre-Wave-5; can probably be deleted now.

---

## Things to NOT do

1. **Don't push to main.** Use PR #3.
2. **Don't bump the SDK version** (currently `matrix-rust-components-swift v26.04.01`).
3. **Don't `gh pr merge --delete-branch` for stacked PRs**. We learned
   this the hard way — it auto-closes any child PRs.
4. **Don't try to fix XCUITest by tweaking signing alone** — the App
   Sandbox is the real blocker; per-config entitlements (Wave 7 fix
   in flight) is the right path.
5. **Don't revert to `recover()` from `recoverAndFixBackup()`** — the
   former skips the post-import side effects that fetch historical
   message keys.
6. **Don't add a parallel boot-time verification controller fetch** —
   we tried that and it caused multi-controller races. Single
   controller, lazy build via `verificationStateListener`.

---

## Signal that things are working

When you sign in to a fresh Mac install against the test homeserver
and tap "Verify with another device", the os.Logger trace under
`subsystem == "chat.matron"` should show this exact sequence (with
some interleaving of `verification-live` and `verification-delegate`
categories):

```
verificationStateListener: fired with unverified
startSAS: enter userID=@matron:localhost deviceID=nil
SDK→didReceiveVerificationRequest:
SDK→didAcceptVerificationRequest
routeAcceptedVerificationRequest: skip startSasVerification — not responder
SDK→didStartSasVerification
routeSasStarted: activeFlowID=@matron:localhost
SDK→didReceiveVerificationData: emojis(...)
routeSasData: yielding .readyForEmoji(count: 7)
[user clicks "They match"]
confirmEmojiMatch: enter
confirmEmojiMatch: approveVerification() returned OK
[partner also confirms via auto-confirm]
SDK→didFinish
routeSasFinished: yielding .verified
verificationStateListener: fired with verified
```

If the trace stops before `didReceiveVerificationData`, sync isn't
delivering to-device events (check `SyncServiceLive` is started). If
it gets to emojis but never gets `didFinish`, check that approve was
called on both sides.
