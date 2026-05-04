# Handover — Matron iOS+Mac, Phase 3 + integration harness

**As of 2026-05-04 PM**, after two working sessions on
`phase-3-e2ee-verification`. This document catches a fresh session up so
it can keep going without re-deriving everything.

Latest tip: **`ba7f4fa`** (`docs: HANDOVER session-2 update`).
Branch sits 14 commits ahead of `cd57415` (the previous handover anchor).

---

## Wider context (read these first if you're cold)

**What Matron is.** Native Matrix client for iOS and macOS, bot-first,
App Store distributable on both platforms. Built on
[matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk) via
`matrix-rust-components-swift v26.04.01`. Part of the
[Matron ecosystem](https://github.com/matronhq) — sister projects:

| Repo | Role | Local path |
|------|------|------|
| `matronhq/matron-iOS-app` | iOS + macOS clients (this repo) | `/Users/danbarker/Dev/matron-iOS-app` |
| `matronhq/matron-server` | Matrix homeserver (Tuwunel/conduwuit fork) | `/Users/danbarker/Dev/matron-server` |
| `matronhq/matron-web` | Web client | `/Users/danbarker/Dev/matron-web` |
| `matronhq/matron-desktop` | Desktop (Electron) client | n/a locally |
| `matronhq/dev-boxer` | One-command Ubuntu VPS provisioner for the whole stack | `/Users/danbarker/Dev/dev-boxer` |
| `claude-matrix-bridge` | Bridges Claude Code agents to Matrix rooms; SDK reference | `/Users/danbarker/Dev/claude-matrix-bridge` |

**Roadmap.** Seven phases. Plans live at `docs/superpowers/plans/`. Each
phase gets its own plan with task-level checkboxes:

| Phase | Title | Output | Status |
|-------|-------|--------|--------|
| 1 | Foundation | App scaffolds, sign-in, sliding sync, room list | **Shipped** (PR #1, squashed into main) |
| 2 | Chat experience | Timeline, composer, attachments, slash commands | **Shipped** (PR #1, same merge) |
| 3 | E2EE & verification UX | Recovery key, SAS, per-bot trust banners | **In flight on PR #3** |
| 4 | Push & NSE | iOS push notifications, encrypted notif decryption | Plan only |
| 5 | Custom event types | `tool_call`, `ask_user`, `session_meta` rendering | Plan only |
| 6 | Search | Encrypted message search | Plan only |
| 7 | Polish | Settings UI, font sizing, App Store prep | Plan only |

**Authoritative design spec**:
[`docs/superpowers/specs/2026-05-02-matron-ios-design.md`](superpowers/specs/2026-05-02-matron-ios-design.md).
Read this before making architectural decisions — it covers
everything from target structure (4 Xcode targets,
`MatronShared` SPM package), through E2EE trust posture
(§7.5 "nothing auto-trusted"), through Mac chrome (§5.9
fixed-size sheets, ⌘ shortcuts).

**Per-task progress** for shipped phases:
- Phase 2: [`docs/phase-2-progress.md`](phase-2-progress.md)
- Phase 3: [`docs/phase-3-progress.md`](phase-3-progress.md) — see this
  for the full per-task account of Phase 3, including all the bugbot
  rounds + expert-QA waves recorded inline.

**Repo README**: [`README.md`](../README.md) — toolchain prereqs
(Xcode 16+, macOS 14+), `xcodegen generate`, license (AGPL-3.0 +
commercial dual).

**Architectural commitments** that apply across all phases (don't
re-litigate without reading the spec):
- SwiftUI + MVVM with `@Observable` view models in `MatronShared`
- Swift 6 strict concurrency (no `@MainActor deinit` reaching isolated
  state — expose `cancel()` / `stop()` and call from `.onDisappear`)
- Sliding sync only — `slidingSyncVersionBuilder(.native)` REQUIRED on
  every `ClientBuilder()`
- AGPL-3.0 + commercial dual license; CLA workflow on PRs
- App Store-submittable on both platforms; Mac uses App Sandbox in
  Release (Debug drops it for XCUITest)
- Per-user Keychain entries (`matron.recovery-key.<userID>`) so
  multi-account on the same device doesn't trample
- `xcodegen` is the source of truth; `Matron.xcodeproj` is gitignored

---

## TL;DR

- **PR #3** (`phase-3-e2ee-verification` → `main`) carries Phase 3
  (E2EE + verification UX) plus seven post-Phase-3 fix-up waves and
  the integration-harness work. Latest SHA: **`ba7f4fa`**.
- **3 SDK-level integration tests passing** end-to-end against
  partner.mjs (matron's second device): verify-with-other-device,
  chat list (post-sync), recovery-key restore. See "Integration
  harness" section.
- **Empty chat list on fresh sign-in: FIXED** (commits `e8c57b6` +
  `1fbdea8`). Was a single-shot AsyncStream race in `ChatListViewModel`
  / `NewChatSheet` consuming the first snapshot before sliding sync
  had downloaded any rooms. View models now re-poll `chatSummaries()`
  until non-empty (1s × 30 attempts).
- **Wave 7 bug #6 reverted** (commit `59b3180`) — both requester and
  responder now call `startSasVerification()`. Required for SAS to
  advance past phase=Ready against any matrix-js-sdk peer.
  **Open risk: matron-vs-matron not yet re-validated against your
  real homeserver.** See "Open risks" below.
- **One unresolved minor UX bug**: "Verify with another device"
  button on Mac doesn't show a pressed state when clicked — click
  registers (verification flow starts), just no visual feedback.
  Likely the navigation transition fires before the press animation
  can render.
- **iOS sim flows post-Wave-7** still not re-tested. Mac empty-chats
  fix is in shared `ChatListViewModel`, so iOS gets the same fix
  automatically; UI verify-with-other-device flow on iOS sim hasn't
  been driven yet.

---

## Current state of PR #3

Branch: `phase-3-e2ee-verification`. Open at https://github.com/Matronhq/matron-iOS-app/pull/3.

### Commit history (newest first)

```
ba7f4fa docs: HANDOVER session-2 update          ← (this commit)
1fbdea8 fix: re-poll chatSummaries() in NewChatSheet (iOS + Mac)
e8c57b6 fix: re-poll chatSummaries() until non-empty — empty-chats fix
7034ba0 fix(test): revert partner.mjs responder additions — broke verify
ebdffe0 test: scaffold matron-as-RESPONDER SDK test (skipped)
e8310a2 docs: bring tests/integration/README.md up to date
ec03bc4 test: run-all-sdk wrapper + .gitignore fix
8490e4a test: add recovery-key SDK test (re-validates recoverAndFixBackup)
1c66847 test: add chat-list SDK test + reorder verify test for sync-race
ee38126 test: assert post-SAS persistence + partner cross-signs
6ad12cc test: switch UI scenario to bootstrap-and-wait too
59b3180 fix: SDK verify-with-other-device passes end-to-end (Wave 7 #6 revert)
b56a7c6 test(wip): SDK + UI integration scenarios — flipped harness
344840c docs: HANDOVER refresh post-XCUITest unblock
cd57415 test: XCUITest infrastructure unblocked — Mac sandbox + signing
… plus 26+ prior commits for Phase 3 itself + Waves 1-7.
```

### Test counts

- **SPM:** 225 (4 skipped — those need iCloud Keychain entitlement
  the SPM host doesn't have). Was 224 pre-session-2; +1 for
  `test_retriesOnEmptySnapshot_until_populated`.
- **iOS scheme:** 53.
- **Mac scheme:** 66.
- **MatronIntegrationTests** (Mac scheme): 4 tests — 3 pass when run
  via the integration harness, 1 skipped pending investigation
  (`testAcceptIncomingVerificationRequestFromPartner`).

Run with:
```bash
cd MatronShared && swift test
xcodebuild test -scheme Matron \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme MatronMac \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_SKIP_SNAPSHOT_TESTS=1
```

Integration tests are gated behind the harness — see the
"Integration harness" section.

### Per-wave / per-session summary

- **Phase 3 itself** (17 tasks across 26 commits): plumbed
  verification + recovery + onboarding gate + per-bot banner + Mac
  menu wiring + Keychain probe. See `docs/phase-3-progress.md`.
- **Wave 1**: B1 SDK delegate wiring (then incomplete) + M4 snapshot
  CI env-var dual-naming.
- **Wave 2**: B2/M5 hoist VerificationCenter + per-bot SasViewModel
  to `@State`, M3 drain replaced FlowStore continuations, M2
  tri-state `isUserVerified`.
- **Wave 3**: B3+M1 Keychain access group (later partly reverted in
  Wave 5) + iOS Keychain probe.
- **Wave 4**: 8 minor expert-QA findings cleanup pass.
- **Wave 5**: 5 critical bugbot findings — including the
  `$(AppIdentifierPrefix)` literal that broke signed builds, and the
  side-effectful `service.startSAS(...)` in 7 wrapper view inits that
  cancelled the live SAS flow on every parent re-render.
- **Wave 6**: Mac UX live-test feedback — File→Sign Out / Help menu
  listeners moved into active-branch view; new
  `MacUnverifiedDeviceBanner` + `UnverifiedDeviceBanner` for
  pre-Phase-3 users.
- **Wave 7**: rewrote verification per Element X iOS patterns —
  lazy controller via `verificationStateListener`, single
  weak-wrapped delegate, `recoverAndFixBackup` instead of bare
  `recover`, requester-vs-responder role tracking on FlowStore.
- **Session 1 (XCUITest unblock, `cd57415`)**: per-config
  entitlements (Debug strips App Sandbox), ad-hoc signing, Mac dev
  account. XCUITest runner now connects in ~3s; was hanging 5+ min.
- **Session 2 (this session, `b56a7c6` → `ba7f4fa`)**: integration
  harness expansion — 3 SDK tests passing, empty-chats fixed,
  Wave 7 bug #6 reverted, `bootstrap-and-wait` partner pattern,
  cross-sign-after-SAS workaround for matrix-js-sdk peers.

---

## What we know works

### Live-validated (real homeserver)

- **Sign-in** against `http://localhost:6167` (test homeserver) and
  `https://matrix-dev2.yearbooks.be` (the user's dev box).
- **SAS "verify with another device"** end-to-end against another
  device of the same user (live-validated session 1, before the
  Wave 7 bug #6 revert). Trace template:
  ```
  verificationStateListener: fired with unverified
  startSAS: enter
  SDK→didReceiveVerificationData (emojis count: 7)
  routeSasFinished: yielding .verified
  verificationStateListener: fired with verified
  ```
- **Recovery key restore** API call succeeds with Wave 7's
  `recoverAndFixBackup`. Historical decryption hasn't been live-
  retested since the empty-chats observation, but the SDK test at
  least proves the API path is healthy.

### SDK-test-validated (every harness run)

- **`verify-sdk-against-partner.sh`** — full SAS round-trip against
  partner.mjs (matrix-js-sdk):
  matron sends `.request` → partner sends `.ready` → matron sends
  `.start` → both compute SAS → both confirm → partner cross-signs
  matron's device → matron's `verificationStateListener: fired with
  verified`. Asserts `.verified` and `isThisDeviceVerified()`
  flips true.
- **`chat-list-sdk.sh`** — partner creates an encrypted room before
  matron signs in; matron syncs and `chatSummaries()` yields the
  room. **This is what proves empty-chats is NOT in the SDK layer**
  — `chatSummaries()` returns the room reliably given enough time.
- **`recovery-key-sdk.sh`** — matron uses partner's recovery key to
  unlock cross-signing locally; `isThisDeviceVerified()` flips true.
  Re-validates Wave 7 bug #4 (`recoverAndFixBackup` switch).

---

## Open risks + unknowns

1. **matron-vs-matron not yet re-validated** after the Wave 7 bug #6
   revert. Wave 7 was added to fix a live-debugged "MAC mismatch"
   symptom in same-SDK flows. Best guess: matron-vs-matron worked
   because one matron-side was always issuing `.start` (the
   responder via Wave 7's logic); with both sides now issuing,
   matrix-rust-sdk should dedupe (Element X relies on this in
   production). **Needs a manual re-test against your real
   homeserver before merging.**

2. **iOS sim flows post-Wave-7** not re-tested. Pre-Wave-7
   observations (last live-tested):
   - "Use recovery key" bounced
   - "Verify with another device" crashed in
     `NavigationColumnState.boundPathChange`

   Wave 7 + Wave 5 fixes very likely fixed both — same root causes
   (the `$(AppIdentifierPrefix)` literal and the side-effectful
   init). The session-2 empty-chats fix in shared `ChatListViewModel`
   automatically applies to iOS. Worth a one-pass live retest on
   iOS sim before merging.

3. **No visible feedback on Mac "Verify with another device" tap**.
   Click registers (verification flow starts) but the button never
   shows a pressed state. Likely `path.append(.sasWithOtherDevice)`
   transitions the screen before the press animation can render.
   Probably needs a small loading state between tap and navigation.
   Minor — not a blocker.

4. **`testAcceptIncomingVerificationRequestFromPartner`** SDK test
   skip-gated. Two issues to investigate before unskipping:
   - Matron receives the request (`routeIncomingRequest` fires) but
     the flow stalls before SAS advances. matrix-rust-sdk's
     `didAcceptVerificationRequest` may only fire on the requester
     side, so matron's `routeAcceptedVerificationRequest`-driven
     `startSasVerification` never runs in the responder case.
   - Merely defining the partner-side
     `cmdBootstrapAndInitiateVerify` function in `partner.mjs`
     broke the verify scenario via some matrix-js-sdk module-load
     side effect (matrix-js-sdk's RustCrypto layer started ignoring
     incoming requests with `"Ignoring just-received verification
     request which did not start a rust-side verification"`).
     The function was reverted out of `partner.mjs` (commit
     `7034ba0`); the Swift-side scaffolding stays in
     `MatronIntegrationTests/VerificationFlowIntegrationTests.swift`,
     gated by `MATRON_RUN_INCOMING_VERIFY_TEST=1`.

5. **UI test (`verify-mac-ui-against-partner.sh`)** structurally
   works but the XCUITest runner init blocks on a macOS biometric /
   Accessibility prompt when invoked from non-interactive Bash.
   Run from an interactive Terminal session and dismiss the prompts
   to actually exercise it. Same SDK code path as
   `verify-sdk-against-partner.sh`, so once unblocked it should
   reach `.verified`.

---

## Integration harness — current state

```
tests/integration/
├── README.md                                  ← prereqs + usage
├── docker/docker-compose.yml                  ← matron-server (tuwunel) on :6167
├── partner/
│   ├── package.json                           ← matrix-js-sdk@41 + crypto-wasm@15
│   ├── partner.mjs                            ← Node CLI; mirrors add-bot.mjs
│   └── package-lock.json
├── scenarios/
│   ├── verify-sdk-against-partner.sh          ← canonical SDK SAS test ✓
│   ├── chat-list-sdk.sh                       ← chat-list / sync test ✓
│   ├── recovery-key-sdk.sh                    ← recovery-key restore test ✓
│   ├── incoming-verify-sdk.sh                 ← responder SDK test (gated)
│   ├── verify-mac-ui-against-partner.sh       ← XCUITest scenario
│   ├── verify-mac-against-partner.sh          ← AppleScript scenario (legacy)
│   └── run-all-sdk.sh                         ← wrapper: run all 3 SDK scenarios
└── run-harness.sh                             ← orchestrator
```

### How to run

```bash
# Image is private — auth once if not cached
gh auth token | docker login ghcr.io -u danbarker --password-stdin

# Single scenario
tests/integration/run-harness.sh verify-sdk-against-partner.sh
tests/integration/run-harness.sh chat-list-sdk.sh
tests/integration/run-harness.sh recovery-key-sdk.sh

# All three SDK scenarios in sequence (each gets a fresh Docker)
tests/integration/scenarios/run-all-sdk.sh

# Boot homeserver + register matron + leave it up (for ad-hoc work)
tests/integration/run-harness.sh
```

`run-harness.sh` auto-skips its own `bootstrap-anchor` step for the
inline-bootstrap scenarios (`verify-sdk-against-partner.sh`,
`chat-list-sdk.sh`, `recovery-key-sdk.sh`,
`verify-mac-ui-against-partner.sh`, `incoming-verify-sdk.sh`) — the
partner bootstraps inline via `bootstrap-and-wait` so the test owns
the partner lifecycle.

### Per-test isolation

Each SDK scenario runs against its own fresh Docker homeserver
because each test's inline bootstrap pollutes server-side
cross-signing state for the next. `run-harness.sh` tears down the
homeserver volume on exit. Don't try to run two SDK tests against a
single `xcodebuild` invocation — they share the homeserver and the
second one's bootstrap will fail (or worse, race silently). The
`run-all-sdk.sh` wrapper handles this by re-invoking
`run-harness.sh` per scenario.

### partner.mjs commands

- `register` — create a fresh user via the registration-token flow
- `bootstrap-anchor` — login + bootstrap SSSS + cross-signing,
  persists creds + recovery key to a store file. Used by scenarios
  that need a pre-bootstrapped trust anchor independent of the test
  process (the AppleScript scenario).
- `bootstrap-and-wait` — combined bootstrap + listen for incoming
  SAS in ONE long-running process (mirrors
  `claude-matrix-bridge/add-bot.mjs`'s working pattern). Optionally
  creates a test room first (`--create-room <name>`). Auto-
  cross-signs the verifying device on Done. **Used by all SDK
  scenarios** — the split bootstrap-anchor → wait-verify shape leaks
  in-memory crypto state and trips MAC interop.
- `wait-verify` — older standalone listener that resumes a previously
  bootstrapped session. Kept for the AppleScript scenario.
- `send-message`, `create-dm` — utility commands for ad-hoc tests.

### Critical learnings (don't re-litigate)

1. **partner.mjs runs as a SECOND DEVICE of @matron**, not a
   different Matrix user. The in-app "Verify with another device"
   button calls `requestDeviceVerification()` — a same-user-
   different-device to-device flow — so a different user wouldn't
   see the request.
2. **matrix-js-sdk does NOT auto-cross-sign after SAS**.
   `verifier.verify()` resolving doesn't upload a cross-signature.
   Need explicit `cryptoApi.crossSignDevice(deviceId)` from the
   Done branch. Without it, matron's `verificationStateListener`
   never fires `verified` even though SAS itself succeeded.
3. **Partner crypto state must be preserved across the SAS flow**.
   The split `bootstrap-anchor → wait-verify` shape resumes a fresh
   client and loses post-bootstrap in-memory crypto state — even
   with SSSS unlock on resume, MAC verification consistently fails.
   `bootstrap-and-wait` keeps everything in one process.
4. **Sync race**: `verificationStateListener: fired with .unverified`
   is necessary but NOT sufficient — the SDK's
   `getSessionVerificationController` may still throw "Failed
   retrieving user identity" while the full identity finishes
   landing. Tests retry `verification.start()` (which blocks on
   `awaitController`) up to 30s before calling `startSAS`.
5. **Order matters**: partner must bootstrap BEFORE matron-app signs
   in. Otherwise matron's first `/keys/query` lands an empty user
   identity into its local crypto store and never recovers in time.
6. **Per-test scenarios needed**: tests can't share a homeserver
   because each one's inline bootstrap replaces the server-side
   cross-signing master keys for `@matron`.

### Accessibility identifiers (already plumbed)

For the XCUITest scenarios:
- `signin.server`, `signin.username`, `signin.password`, `signin.submit`
- `verifygate.verifyWithOtherDevice`, `verifygate.useRecoveryKey`,
  `verifygate.generateNew`
- `sas.match`, `sas.dontMatch`

---

## Where to pick up

### 1. Live-validate matron-vs-matron after Wave 7 bug #6 revert

Highest-priority before merging. Sign in to your real homeserver on
Mac as a user with another already-verified device. Tap "Verify with
another device". The flow should reach `verified`. If it MAC-fails,
Wave 7 bug #6 was right and we need a different strategy for the
matrix-js-sdk interop case (e.g., role-conditional behaviour).

### 2. iOS sim retest

Mac empty-chats fix automatically applies to iOS via shared
`ChatListViewModel`, but the iOS verify-with-other-device flow
hasn't been driven post-Wave-7. With the harness running:

```bash
xcodebuild -scheme Matron -configuration Debug \
    -destination 'platform=iOS Simulator,id=337C3A3A-4191-4A51-9513-93F5805276EC' \
    build CODE_SIGNING_ALLOWED=NO
xcrun simctl uninstall 337C3A3A-4191-4A51-9513-93F5805276EC chat.matron.app
xcrun simctl install 337C3A3A-4191-4A51-9513-93F5805276EC \
    "$HOME/Library/Developer/Xcode/DerivedData/Matron-bxmhcklltdsxiccbqjrvsvbdiubi/Build/Products/Debug-iphonesimulator/Matron.app"
xcrun simctl launch 337C3A3A-4191-4A51-9513-93F5805276EC chat.matron.app
```

Sign in as `matron` / `matron-test-pw`. Try the recovery-key + verify-
with-other-device flows.

### 3. Fix the visual-feedback bug on Mac Verify button

`MacPostLoginVerificationView`'s "Verify with another device"
button: `path.append(.sasWithOtherDevice)` happens immediately on
tap, transitioning the screen before SwiftUI renders the press
animation. Fix probably wants either a brief loading state or
`.task`-driven pre-flight before navigation. Minor visible polish.

### 4. Run the UI scenario from an interactive Terminal

`tests/integration/run-harness.sh verify-mac-ui-against-partner.sh`
from a Terminal session, dismissing any TouchID / Accessibility
prompts. The XCUITest runner-init blocks from non-interactive Bash;
once dismissed, the test exercises the same SDK code path the
SDK scenario already proves green, so it should land at `.verified`.

### 5. Investigate the responder test stall

`testAcceptIncomingVerificationRequestFromPartner` is gated behind
`MATRON_RUN_INCOMING_VERIFY_TEST=1`. Two angles to dig into:
- matrix-rust-sdk's `didAcceptVerificationRequest` delegate firing
  semantics (does it fire only on the requester side?)
- The matrix-js-sdk module-load side effect that breaks the verify
  scenario when `cmdBootstrapAndInitiateVerify` is present in
  `partner.mjs`

Both block the test from passing. Phase 5 (per-bot trust UX) will
exercise the same `acceptIncoming` code path so the responder
coverage matters before then.

### 6. Decide on PR #3 disposition

PR #3 has accumulated 7 fix-up waves + 14 session-2 commits on top
of the Phase 3 base. It's substantial but coherent (each commit is
self-contained). Two options:
- **Merge as-is** once #1+#2 above pass. Phase 3 ships, remaining
  open items become Phase 4 work.
- **Split into stacked PRs** for cleaner review history.

User's stated preference earlier was to merge stacked when possible
but accepted squash for PR #1 (Phase 2). Merge-as-is is the
pragmatic call.

### 7. Long-running: build a CI hook for the harness

After matron-vs-matron is validated, wire the SDK scenarios into a
GitHub Actions workflow. Will need a self-hosted Mac runner (the
harness builds the app) or a GitHub-hosted macOS runner with Docker
(which costs $$).

---

## Useful state / paths

- **Repo**: `/Users/danbarker/Dev/matron-iOS-app`
- **Element X iOS** (verification reference): `/Users/danbarker/Dev/yearbook-messages-ios/ElementX`
- **claude-matrix-bridge** (add-bot.mjs reference): `/Users/danbarker/Dev/claude-matrix-bridge`
- **matron-server source**: `/Users/danbarker/Dev/matron-server`
- **Matron Mac app** (after build): `~/Library/Developer/Xcode/DerivedData/Matron-bxmhcklltdsxiccbqjrvsvbdiubi/Build/Products/Debug/MatronMac.app`
- **iOS sim ID**: `337C3A3A-4191-4A51-9513-93F5805276EC` (iPhone 17)
- **Test homeserver**: `http://localhost:6167` (Docker)
- **Test users**: `matron` / `matron-test-pw`
- **Real homeserver**: `https://matrix-dev2.yearbooks.be` (user has accounts there)
- **Per-run artifacts**: `tests/integration/artifacts/<timestamp>/` —
  matron os.Logger trace (`matron-sdk.log`), partner JSONL output,
  build log, test log, xcresult bundle, harness log
- **Crash report from iOS sim** (still in repo root): `ios-crash-report.txt`
  — pre-Wave-5; can probably be deleted now.

### Apple Developer accounts (Xcode → Settings → Accounts)

- **Personal Team** — team ID `T87DM9X88P` ("DANIEL JOHN B BARKER")
- **YEARBOOK MACHINE LIMITED** — team ID `4LJ7WRRRFD`, **Admin role**
  (this is the Matron-org parent; matronhq GH org belongs here)
- The iOS device `Dan's MacBook Pro` is **not registered** under
  YEARBOOK MACHINE LIMITED yet — would need to be added at
  https://developer.apple.com/account/resources/devices for full
  Apple-signed local testing. Ad-hoc signing (`CODE_SIGN_IDENTITY=-`)
  bypasses this and is what the integration harness uses.
- Two Mac development certs available locally (run `security
  find-identity -p codesigning -v`):
  - `Apple Development: DANIEL JOHN B BARKER (T87DM9X88P)`
  - `Apple Development: Dan Barker (MHQ4X3KS8L)`

### ghcr.io image pull

`ghcr.io/matronhq/matron-server:latest` is **private**. Auth before
running the harness if the image isn't cached:
```bash
gh auth token | docker login ghcr.io -u danbarker --password-stdin
```

---

## Things to NOT do

1. **Don't push to main.** Use PR #3.
2. **Don't bump the SDK version** (currently `matrix-rust-components-swift v26.04.01`).
3. **Don't `gh pr merge --delete-branch` for stacked PRs**. Auto-
   closes any child PRs.
4. **Don't try to fix XCUITest by tweaking signing alone** — the
   App Sandbox is the real blocker; per-config entitlements
   (`cd57415`) is the right path.
5. **Don't revert to `recover()` from `recoverAndFixBackup()`** —
   the former skips the post-import side effects that fetch
   historical message keys.
6. **Don't add a parallel boot-time verification controller fetch**
   — caused multi-controller races. Single controller, lazy build
   via `verificationStateListener`.
7. **Don't put `entitlements:` block at target level in `project.yml`
   when you also have per-config `CODE_SIGN_ENTITLEMENTS`** — the
   target-level block overrides per-config and breaks
   Debug-vs-Release entitlement variants.
8. **Don't fight Mac SwiftUI form-fill via XCUITest typeText for
   URLs** — typeText mangles `:` and `/`. Use `NSPasteboard` + ⌘V.
9. **Don't expect Mac apps launched from XCUITest to show a window**
   — they often come up as menu-bar-only background processes.
   Workaround: `app.activate()` + `app.typeKey("n", modifierFlags:
   [.command])` to send File→New Window.
10. **Don't re-add the `role == .responder` guard in
    `routeAcceptedVerificationRequest`** without first making
    matrix-js-sdk peers work. The original Wave 7 bug #6 fix made
    SAS deadlock at phase=Ready against matrix-js-sdk because
    neither side issued `m.key.verification.start`. If matron-vs-
    matron breaks after the revert, the right shape is probably
    role-conditional behaviour driven by detected peer SDK, not a
    blanket guard.
11. **Don't re-add `cmdBootstrapAndInitiateVerify` to
    `partner.mjs`** without first understanding the matrix-js-sdk
    module-load side effect that breaks the verify scenario when
    that function is present. See open risk #4.
12. **Don't run two SDK integration tests against the same
    `xcodebuild` invocation** — server-side cross-signing state from
    one test's inline bootstrap breaks the next. Use
    `run-all-sdk.sh` for sequential per-scenario isolation.

---

## Signal that things are working

When you run the SDK verify scenario, the os.Logger trace (in
`tests/integration/artifacts/<ts>/matron-sdk.log`, filtered to
`subsystem == "chat.matron"`) should show this sequence — both
`verification-live` and `verification-delegate` categories
interleaved:

```
verificationStateListener: fired with unverified
startSAS: enter userID=@matron:localhost deviceID=nil
SDK→didReceiveVerificationRequest: …      (when partner is requester)
SDK→didAcceptVerificationRequest          (when partner accepts our .request)
routeAcceptedVerificationRequest: calling startSasVerification() (role=…)
SDK→didStartSasVerification
routeSasStarted: activeFlowID=…
SDK→didReceiveVerificationData: emojis(…)
routeSasData: yielding .readyForEmoji(count: 7)
confirmEmojiMatch: enter
confirmEmojiMatch: approveVerification() returned OK
SDK→didFinish
routeSasFinished: yielding .verified for …
verificationStateListener: fired with verified
```

The final `verificationStateListener: fired with verified` is the
key signal — it means matron's local crypto store has received
partner's freshly-uploaded cross-signature and now considers this
device verified. Without it, SAS technically completed but the
device still shows unverified (which was the
`crossSignDevice`-missing bug we hit in session 2).

If the trace stops before `didReceiveVerificationData`, sync isn't
delivering to-device events (check `SyncServiceLive` is started, and
that the verificationStateListener has fired `!= .unknown`). If it
gets to emojis but never gets `didFinish`, check that approve was
called on both sides AND that partner is calling `crossSignDevice`
on Done.
