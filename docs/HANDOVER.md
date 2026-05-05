# Handover — Matron iOS+Mac, Phase 3 + integration harness

**As of 2026-05-05 early afternoon (session 7)**, after seven working
sessions on `phase-3-e2ee-verification`. Session 7 picked up the
"Open work for session 7 — Priority A" list session 6 left, and
closed all three items end-to-end. Two new scenario scripts +
a Node orchestrator + one SwiftUI snapshot test on the Mac side.
A real iOS production bug was uncovered + fixed by the new
reverse-direction test (nested `NavigationStack` inside iOS
`RecoveryKeyView` was breaking pushed navigation from the verify
gate — the user manually reproduced "switches to empty screen, then
immediately switches back"). All session-7 work is **uncommitted on
disk** as of handover — see "Open work for session 8" below for the
commit ordering recommendation. Previous block (session 6) is also
worth reading for the broader Phase 3 story.

**Session 5** closed out with `matron-vs-matron-ui` GREEN end-to-end
alongside the 3 SDK scenarios — full SAS round trip with both peers
reaching `verificationStateListener: fired with verified`. Required
four product-code changes plus a logging stack. See "Session 5"
block below.

Latest tip: **`879f44e`** (`fix(test/scenario): poll-grep watcher instead of tail|grep -m1`),
plus an uncommitted retry+logging diagnostic in
`VerificationServiceLive.buildController`.
Session 3 added the matron-vs-matron UI test scenario (Mac + iOS sim,
both running matrix-rust-sdk, no partner.mjs) — 19 commits, ending in a
**concrete reproducer of the matron-vs-matron responder bug** (Mac
chat-list-view doesn't render the incoming-verify banner when iOS sends
a verification request). See "Session 3" section.

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
  (E2EE + verification UX) plus seven post-Phase-3 fix-up waves, the
  integration-harness work, and (session 3) the matron-vs-matron UI
  test scenario. Latest SHA: **`879f44e`**.
- **3 SDK-level integration tests + 1 UI XCUITest scenario
  passing** end-to-end against partner.mjs (matron's second
  device): verify-with-other-device (SDK and UI), chat list
  (post-sync), recovery-key restore. See "Integration harness"
  section. Run all four with
  `tests/integration/scenarios/run-all-sdk.sh` (3-attempt retry
  on the verify scenarios for the matrix-js-sdk flake).
- **Session 3: new `matron-vs-matron-ui.sh` scenario** drives Mac (trust-
  anchor responder) + iOS sim (requester) end-to-end via XCUITest, both
  running matrix-rust-sdk against the Docker harness — **NOT yet
  green**. Mac signs in + drives the full multi-phase recovery-key
  bootstrap, iOS signs in + taps "Verify with another device" + calls
  `startSAS`, but Mac's chat list never renders the incoming-verify
  banner so iOS hangs at "starting verification" and times out. This
  is a concrete repro of HANDOVER open-risk #1 (matron-vs-matron
  responder broken post-Wave-7-revert) — see "Session 3 — current
  state of matron-vs-matron-ui" below for the full debug trail and
  next-step suggestions.
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
  automatically; the new matron-vs-matron-ui scenario (session 3) does
  drive the iOS verify-with-other-device flow, and confirmed that
  iOS-as-requester signs in, taps the verify-gate button, calls
  `startSAS`, and sends `m.key.verification.request` over to-device
  successfully — i.e., the iOS requester half is working end-to-end.

---

## Session 7 — Priority A test coverage; real iOS NavStack bug fix; Node harness orchestrator

**TL;DR for the next agent:** session 6 closed out with a "Priority A
— XCUITest gaps" list of three tests. Session 7 delivered all three
(in slightly different shapes than session 6 specified — the
chooser test became a snapshot rather than XCUITest, and #1 became
verify-gate restore rather than chat-list-banner restore; rationale
inline below). The reverse-direction test surfaced a real iOS bug
(nested NavigationStack in `RecoveryKeyView`) that had never been
caught because the Mac equivalent doesn't have a nested stack and
no prior automated coverage drove iOS through `.generate` from the
verify gate. Branch is in better shape than session 6 described:
two more scenarios green, one production bug fixed, harness
runtime cut substantially via team signing + a Node orchestrator
that brings Docker up once for the whole batch instead of per-
scenario.

**Everything is uncommitted on disk** — `git status` shows 11
modified files + 7 new files + 1 new snapshot directory. See
"Open work for session 8" for the recommended commit ordering.

### Setup state for the next agent (deltas from session 6)

- Same Docker harness on `http://localhost:6167`, container
  `matron-test-server`, same `tests/integration/docker/docker-compose.yml`.
- New convenience entry-point: `node tests/integration/run-all-ui.mjs`
  brings Docker up once, registers `@matron1` + `@matron2`
  (passwords `matron1-test-pw` / `matron2-test-pw` — pattern is
  `<user>-test-pw`), runs both new UI scenarios sequentially with
  the right user per scenario, tears Docker down on exit. ~3 min
  wall-clock for the happy-path batch.
- Single-scenario invocation still works via the existing
  `tests/integration/run-harness.sh <scenario>.sh`. Session 7
  added `recovery-key-restore-ui.sh` and `reverse-direction-ui.sh`
  to its auto-skip-bootstrap-anchor list.
- **Harness now uses team signing** (`-allowProvisioningUpdates`
  with `DEVELOPMENT_TEAM=4LJ7WRRRFD`) instead of ad-hoc signing.
  TCC grants the Accessibility/Automation permission to the test
  runner once per stable signature; with team signing, that
  signature persists across rebuilds, so TouchID is asked once and
  never again. The `MatronMac.Debug.AdHoc.entitlements` file is
  no longer referenced by the new scenario scripts but stays in
  the repo for backwards compat with `verify-mac-ui-against-partner.sh`
  and the original `matron-vs-matron-ui.sh` (those still use ad-hoc).
- iOS sim UDID unchanged: `337C3A3A-4191-4A51-9513-93F5805276EC`
  (iPhone 17, iOS 26.4.1).

### What was delivered (all uncommitted)

**New tests / scenarios:**

| Path | Type | Status |
|------|------|--------|
| `MatronMacUITests/RecoveryKeyRestoreUITests.swift` | XCUITest | ✓ green via `recovery-key-restore-ui.sh` |
| `MatronMacUITests/ReverseDirectionMacUITests.swift` | XCUITest (Mac as requester) | ✓ green via `reverse-direction-ui.sh` |
| `MatronUITests/ReverseDirectionIOSUITests.swift` | XCUITest (iOS as trust anchor) | ✓ green (paired with Mac above) |
| `MatronMacTests/MacVerifyDeviceChooserSnapshotTests.swift` | SwiftUI snapshot | ✓ green; baselines recorded |
| `MatronMacTests/__Snapshots__/MacVerifyDeviceChooserSnapshotTests/` | 6 PNG baselines | new dir, 6 files |
| `tests/integration/scenarios/recovery-key-restore-ui.sh` | new scenario script | ✓ |
| `tests/integration/scenarios/reverse-direction-ui.sh` | new scenario script | ✓ |
| `tests/integration/run-all-ui.mjs` | Node batched runner | ✓ |

**Production code touched:**

| File | What changed |
|------|--------------|
| `Matron/Features/Verification/RecoveryKeyView.swift` | (1) Removed inner `NavigationStack` — was nested with the parent and broke pushed navigation; (2) added 6 missing accessibility identifiers (`recoverykey.copy`, `recoverykey.acknowledgeSaved`, `recoverykey.generate`, `recoverykey.continue`, `recoverykey.confirm`, `recoverykey.reenterField`); (3) added `recoverykey.generatedKey` to the `Text` showing the key so XCUITest can read it without a pasteboard prompt. |
| `Matron/Features/Verification/VerificationBanner.swift` | Added `verifybanner.accept` accessibility identifier. |
| `Matron/Features/Onboarding/PostLoginVerificationView.swift` | Switched the "first device — generate a key" Button from plain text to `.buttonStyle(.bordered)` for tap reliability + clearer affordance. |
| `MatronMac/App/MatronMacApp.swift` | Refactored the chooser body of `HelpMenuVerifyDeviceSheet` to delegate to a new standalone `MacVerifyDeviceChooser` view (testability). Sheet keeps ownership of post-pick state mutations. |
| `MatronMac/Features/Verification/MacVerifyDeviceChooser.swift` (new) | Extracted chooser body — pure view that takes `hasOtherDevices: Bool` + 3 callbacks. Snapshot-tested. |
| `MatronMac/Features/Verification/MacRecoveryKeyView.swift` | Added 2 missing accessibility identifiers on the restore form (`recoverykey.restorePaste`, `recoverykey.restore`) so the new `RecoveryKeyRestoreUITests` can target them. |

**Pre-existing build breaks fixed (uncovered while running tests):**

Session 6 added `hasOtherVerifiedDevices()` and `cancelledRequests()` to `VerificationService` and updated the *shared* SPM fake (commit `1322554`), but missed four host-app fakes. Both Mac AND iOS schemes wouldn't compile until these were stubbed:

- `MatronMacTests/MacDeviceSettingsViewTests.swift` (`FakeVerificationServiceForSettings`)
- `MatronMacTests/MacChatViewTests.swift` (`CountingVerificationServiceForChat` + `FakeVerificationServiceForChat`)
- `MatronTests/DeviceSettingsViewTests.swift` (`FakeVerificationServiceForSettings`)
- `MatronTests/ChatViewBindingTests.swift` (`CountingVerificationServiceForChat` + `FakeVerificationServiceForChat`)

Stubbed implementations return `false` / empty stream — sufficient for view tests that don't exercise these surfaces.

**Harness changes:**

- `tests/integration/run-harness.sh` — added `recovery-key-restore-ui.sh` and `reverse-direction-ui.sh` to the auto-skip-bootstrap-anchor list.

### Production bugs caught + fixed live during this session

1. **iOS `RecoveryKeyView` had a nested `NavigationStack`** inside the parent `PostLoginVerificationView`'s NavStack. iOS would briefly mount the destination view then immediately pop back to the verify gate (user manually reproduced: "switches to another empty screen and then immediately switches back"). Mac doesn't have this bug because `MacRecoveryKeyView` doesn't host an inner NavStack. Fix: removed the inner stack from iOS `RecoveryKeyView.body`; wrapped the one sheet call site (`ChatListView.swift:659`) in its own NavStack to preserve the title bar there.

2. **iOS verify-gate "first device" Button was plain-text + ~20pt tall** — XCUITest tap synthesis on iOS 26 simulator was unreliable (tap fired but action didn't always register). Bumping to `.buttonStyle(.bordered)` gives a 34pt-tall hit target. The actual user-visible improvement is small (was tappable manually, just looked less affordant); main payoff is test reliability.

3. **iOS SwiftUI Toggle `.tap()` doesn't reliably flip state on iOS 26.4 sim.** The acknowledge toggle in the recovery-key-show step was getting tapped (synthesized event) but the `@Binding` wouldn't update. Fixed test-side: coordinate-based tap on the right edge (where the switch thumb lives), with a `swipeRight()` fallback if the value still hasn't flipped. Added a value-readback assert so future regressions surface immediately rather than silently skipping the toggle. Not a production bug per se but worth knowing.

4. **iOS pasteboard read triggers a system-modal "X would like to paste" prompt** that XCUITest can't dismiss without `XCUIInterruptionMonitor` glue. The original test approach (tap Copy → read `UIPasteboard.general.string` → type back into reenter) hung the test for 126s waiting for the user to tap Allow. New approach: read the displayed key from `app.staticTexts["recoverykey.generatedKey"].label` directly, no pasteboard involved. The Copy button itself is no longer exercised by the test (still works in production; just not tapped during reverse-direction).

### Harness improvements

- **Single Docker bring-up per batch** via `tests/integration/run-all-ui.mjs` (Node, ~140 LOC, no new deps — uses Node 18+ built-ins). Saves ~60s per scenario vs `run-harness.sh`-per-scenario.
- **Per-scenario user isolation** — `matron1` for recovery-key-restore, `matron2` for reverse-direction. Server-side cross-signing state from one scenario can't leak into the next; client-side state wipe is already handled by each scenario's existing `rm -rf` block at the top.
- **Team-identity signing** for harness builds — TCC permission persists across rebuilds, so TouchID is asked once and never again on the dev's machine.
- **75s Mac wait timeout** in `ReverseDirectionMacUITests` (down from 300s). iOS deterministically fails in ~28s, so 75s buys plenty of headroom on warm-sim happy paths (~40s) while keeping failure cycles short.
- **Why a Node orchestrator and not bash:** scenarios are still bash, but the orchestrator (Docker setup, user registration, sequential dispatch, summary) is Node — closer to where the existing `partner.mjs` lives. We discussed this explicitly: shell stays fine for ~150 LOC scenarios, but the orchestration glue grows fastest as more scenarios land, and Node gives us proper data structures + error handling without adding any runtime deps. Bash stays as the per-scenario implementation language.

### Decisions on session 6's "Priority A" list (and what was skipped)

- **A#1 `test_chatListChooser_recoveryKeyPath` → reframed as `testRecoveryKeyRestoreViaVerifyGate`.** The handover spec said "sign out, sign back in, chat-list banner appears" — but `MatronMacApp.signOut()` clears `verifyDone`, so sign-back-in lands at the verify gate, not the chat list. The chat-list-banner state (verifyDone=true + isThisDeviceVerified=false) only happens via app-quit + selective state wipe, which the user pointed out is a legacy-upgrade-only state and **this app has never been released**. So no real users will hit it. The verify-gate restore path covers the same `recoverykey.restore` + `Restore` + verified production code; just reached via a more natural surface for new users. ✓ green.
- **A#2 reverse-direction matron-vs-matron** — implemented as spec'd: iOS as trust-anchor responder (signs in first, generates key, prints `MATRON_IOS_TRUST_ANCHOR_READY` to stdout, host-watcher creates `/Users/Shared/matron-ios-ready`, Mac waits, signs in, drives SAS as requester). Inverse of the original `matron-vs-matron-ui.sh`. Surfaced the iOS NavStack bug above. ✓ green end-to-end.
- **A#3 chooser button states → snapshot test, not XCUITest.** The chooser is reachable via the same legacy-only state as A#1's chat-list path — XCUITest would need state-injection trickery. Refactored the chooser into `MacVerifyDeviceChooser` and added two snapshot tests covering the `hasOtherDevices=true` and `false` arms. Same logical guarantee, ~50 LOC vs ~150 LOC + new scenario. ✓ green; baselines recorded.

### How to validate the branch end-to-end

The fast path:
```bash
node tests/integration/run-all-ui.mjs
```
~3 min, runs both new scenarios. Expected output ends with:
```
Summary
  ✓ PASS    recovery-key-restore-ui.sh    (user: @matron1, rc=0)
  ✓ PASS    reverse-direction-ui.sh       (user: @matron2, rc=0)
```

Snapshot tests (no Docker needed):
```bash
xcodebuild test \
    -scheme MatronMac -destination 'platform=macOS' \
    -only-testing:MatronMacTests/MacVerifyDeviceChooserSnapshotTests \
    -allowProvisioningUpdates
```

The original `matron-vs-matron-ui.sh` and other session-6 scenarios are unchanged and should still work via `tests/integration/run-harness.sh <scenario>.sh`.

### Open work for session 8

**Priority A — commit + PR the session-7 work:**

1. Commit the production-code changes (the 4 modified `*.swift` files + `MacVerifyDeviceChooser.swift` + `MacRecoveryKeyView.swift` accessibility-id additions) as one logical commit. The iOS NavStack fix is the most important — flag it clearly in the commit message because it's a real user-visible bug fix.
2. Commit the new tests + scenario scripts + orchestrator as a second commit.
3. Commit the snapshot baselines as a third commit (they're binary PNGs; a separate commit keeps the diff readable).
4. Commit the four pre-existing-fake fixes as a fourth commit explicitly noting "fixes session-6 build breaks introduced by `1322554` only updating the SPM fake".
5. Then either rebase + force-push to PR #3, or merge into main if the PR is being abandoned.

**Priority B — Priority B/C tests from session 6's list** (still un-touched):

- `test_recoveryKey_reenterMustMatch` — pure single-device, simple
- `test_recoveryKey_restoreError_invalidKey` — error branch coverage
- `test_helpMenu_alreadyVerified` — UX-only
- `test_cancelled_closeButton` — UX-only

Each is ~80-100 LOC. Recommend doing as a follow-up batch only if the underlying surfaces gain new bugs — no current evidence they're broken.

**Priority C — investigate dead code uncovered by session 7's analysis:**

- `MacUnverifiedDeviceBanner` (in `MatronMac/Features/Verification/`) and the chat-list code path that surfaces it (`MacChatListView.swift` showUnverified branch) are **only reachable via the legacy-upgrade state that doesn't exist in a never-released app.** Worth either deleting or explicitly gating behind a `#if DEBUG` flag with a comment explaining when it would activate. Same applies to the iOS chat-list chooser at `Matron/Features/ChatList/ChatListView.swift:680-728` (the inline chooser body that mirrors `MacVerifyDeviceChooser`). Both surfaces have working code paths, just no users.
- The "Things to NOT undo" bullet from session 6 about the chat-list-banner chooser ("happens on every sign-out + sign-in cycle since loginPassword wipes basePath and verifyDone UserDefaults survives the wipe") is **inaccurate** — `signOut()` does clear verifyDone (MatronMacApp.swift:328). The chat-list-banner state only happens with app force-quit + external state surgery, not normal sign-out + sign-in. Worth correcting that note when consolidating Priority C above.

**Priority D — carried forward from session 6:**

- `verify-sdk-against-partner.sh` regression (matrix-js-sdk same-user-verification race) — still un-fixed, partner-side workaround needs the rust olm machine poll
- iOS rust-verification-machine drops `.ready` event upstream bug — workaround landed in session 6's `57e7c4c`, still no upstream report filed

### Things to NOT undo (specific to session 7)

- **Don't re-add the inner `NavigationStack` to iOS `RecoveryKeyView`** — it nests with the parent NavStack from `PostLoginVerificationView` and immediately pops the destination. The user manually reproduced this on iOS 26.4 sim. The `ChatListView.swift:659` sheet call site wraps in its own NavStack to preserve the title bar there; if you change the sheet to push from a parent NavStack instead, drop that wrapper.
- **Don't switch the iOS verify-gate "first device" Button back to plain text** — XCUITest tap synthesis on iOS 26.4 sim is unreliable on plain-text buttons under ~30pt tall. `.buttonStyle(.bordered)` is also a UX win (clearer affordance for a primary action).
- **Don't switch the iOS reverse-direction test back to UIPasteboard for capturing the recovery key** — iOS shows a system-modal paste prompt that hangs unattended runs. Read from `app.staticTexts["recoverykey.generatedKey"].label` instead.
- **Don't drop the toggle value-readback** in `ReverseDirectionIOSUITests.swift` — iOS SwiftUI Toggle's `.tap()` is flaky on iOS 26 sim; the coordinate-tap-then-swipeRight fallback + post-condition assert catches the silent-failure mode.
- **Don't switch harness scenarios back to ad-hoc signing** — TouchID would be required on every rebuild. Team signing (4LJ7WRRRFD) keeps TCC permission across rebuilds.
- **Don't merge `MacVerifyDeviceChooser` back into `HelpMenuVerifyDeviceSheet`** — the extraction is what makes the snapshot test possible (the sheet's `Phase` state machine is `private` and not testable in isolation).

### Files changed this session (~600 LOC + 6 new files)

**Product code (uncommitted):**
- `Matron/Features/Verification/RecoveryKeyView.swift` — drop inner NavStack, add 7 accessibility IDs
- `Matron/Features/Verification/VerificationBanner.swift` — add `verifybanner.accept`
- `Matron/Features/Onboarding/PostLoginVerificationView.swift` — `.buttonStyle(.bordered)` on `verifygate.generateNew`
- `Matron/Features/ChatList/ChatListView.swift` — wrap sheet recovery-key case in `NavigationStack`
- `MatronMac/App/MatronMacApp.swift` — refactor `chooserView` to delegate to `MacVerifyDeviceChooser`
- `MatronMac/Features/Verification/MacVerifyDeviceChooser.swift` (new) — extracted chooser view
- `MatronMac/Features/Verification/MacRecoveryKeyView.swift` — add 2 restore-form accessibility IDs

**Tests (uncommitted, all new):**
- `MatronMacUITests/RecoveryKeyRestoreUITests.swift`
- `MatronMacUITests/ReverseDirectionMacUITests.swift`
- `MatronUITests/ReverseDirectionIOSUITests.swift`
- `MatronMacTests/MacVerifyDeviceChooserSnapshotTests.swift`
- `MatronMacTests/__Snapshots__/MacVerifyDeviceChooserSnapshotTests/` (6 PNGs)

**Pre-existing fake fixes (uncommitted):**
- `MatronMacTests/MacDeviceSettingsViewTests.swift`
- `MatronMacTests/MacChatViewTests.swift`
- `MatronTests/DeviceSettingsViewTests.swift`
- `MatronTests/ChatViewBindingTests.swift`

**Harness (uncommitted):**
- `tests/integration/run-all-ui.mjs` (new, ~140 LOC)
- `tests/integration/scenarios/recovery-key-restore-ui.sh` (new)
- `tests/integration/scenarios/reverse-direction-ui.sh` (new)
- `tests/integration/run-harness.sh` — added two scenarios to auto-skip-bootstrap list

---

## Session 6 — manual-testing pass; UX polish; product fixes; partial test coverage

**TL;DR for the next agent:** session 5 closed out matron-vs-matron-ui
green at the harness level. Session 6 ran the full Phase 3 user
journey by hand on a signed Mac build (Yearbook Machine team) +
fresh iOS sim against a local Docker homeserver. Found and fixed
twelve real issues — most user-visible UX bugs, some SDK-state
edge cases. Branch is in good shape; major remaining work is
XCUITest coverage for the new paths (chooser, recovery-key restore
via UI, reverse-direction matron-vs-matron). See "Open work for
session 7" at the bottom of this block.

### Setup state for the next agent

- Local Docker homeserver running: `http://localhost:6167`
  (`tests/integration/docker/docker-compose.yml`). Container name
  `matron-test-server`. Nuke + restart with
  `cd tests/integration/docker && docker compose down -v && docker compose up -d`.
- Test user: `dan` / `test-pw`. Created in this session via
  `node tests/integration/partner/partner.mjs register --homeserver
  http://localhost:6167 --user dan --password test-pw --token
  matron-test-only`. Cross-signing identity is live on the server
  for `@dan:localhost`.
- Mac is signed with Yearbook Machine Limited (`DEVELOPMENT_TEAM:
  4LJ7WRRRFD`, sticky in project.yml as of `6ee5b7d`). Xcode-Run
  picks up signing automatically; CLI builds need
  `-allowProvisioningUpdates`. Harness builds use ad-hoc signing
  via `MatronMac.Debug.AdHoc.entitlements` (an entitlements file
  without `keychain-access-groups`, since ad-hoc signing can't
  validate it).
- iOS sim: iPhone 17, UDID `337C3A3A-4191-4A51-9513-93F5805276EC`.
  matron-iOS app installed at last test, possibly in a
  partially-verified state.

### Twelve commits landed

| SHA | Type | What |
|-----|------|------|
| `9c3c954` | fix | `keychain-access-groups` in Mac Debug entitlements (was missing, signed dev builds couldn't write recovery key) |
| `98705d1` | fix | Defer Mac "Verify with another device" nav 120 ms so the borderedProminent press animation visibly completes; soften recovery-key warning copy |
| `6ee5b7d` | fix | `DEVELOPMENT_TEAM: 4LJ7WRRRFD` sticky in `project.yml`; new `MatronMac.Debug.AdHoc.entitlements` for harness ad-hoc builds |
| `92293a4` | fix | Drain `VerificationCenter.pending` on successful SAS; yield `.awaitingConfirmation` from `confirmEmojiMatch` so the SAS view shows "Waiting for the other device…" between local approve and partner-side approve |
| `b511e9a` | fix | Close button on cancelled SAS sheet (Mac + iOS); Help → Verify This Device shows "already verified" confirmation when device is verified instead of running redundant SAS |
| `c0c2e99` | fix | Chat-list verify-banner chooser — replaces immediate-SAS with a two-button chooser (SAS / recovery-key); plumbs `recoveryKeyRestore` closure from host so the sheet stays free of `RecoveryKeyManager` deps |
| `31bfa3c` | fix | `hasOtherVerifiedDevices` SDK probe; chooser disables SAS button + caption when no other peer; drop "SAS" jargon from copy; `XXXX-XXXX-XXXX-XXXX` placeholder → "Enter recovery key" / "Re-enter recovery key"; combine inline Restore + bottom Done into single Restore-with-progress button |
| `1322554` | test | `ScriptedVerificationService` test fake conforms to new `hasOtherVerifiedDevices` |
| `57e7c4c` | fix | **Prime `userIdentity(fallbackToServer: true)` before `requestDeviceVerification` so the SDK has the partner's CURRENT device list before sending `.request`. Without this, .ready arrives from a from_device the local rust olm machine doesn't recognise and silently drops it. This was the bug that stalled SAS at "Starting verification…" with the partner's .ready never landing.** |
| `6662a6c` / `51daac1` | fix | iOS sign-in: `https://matrix.example.com` placeholder was rendered as a tappable blue link by Form's data detection. Replaced with plain "Homeserver URL". |
| `453e9a9` | fix | New `cancelledRequests()` AsyncStream on `VerificationService` + observation in `VerificationCenter.start()` to drain `pending` when the SDK fires `didCancel` for a flow with no active SAS continuation (e.g. partner cancelled before our user clicked the banner). Routes through `routeSasCancelled`'s no-active-continuation branch. |
| `d76e085` | test | 4 SPM tests for the cancelled-stream drain (regression for `453e9a9`) |

### Manual testing journey — what was validated

Driven through the Phase 3 + Phase 5 playlist plus follow-on tests:

1. **Mac signed-build keychain access** ✓ — recovery key persists to
   Keychain on a Yearbook-team-signed Debug build. Console.app shows
   `recovery-key:generate: keychain.set OK — exit`.
2. **Mac press feedback** ✓ — borderedProminent button visibly
   compresses + releases before NavigationStack swap.
3. **matron-vs-matron SAS round trip** ✓ — both peers reach
   `verificationStateListener: fired with verified`. End-to-end via
   the chat-list banner click on Mac (responder) + verify-gate click
   on iOS (requester).
4. **Reverse-direction SAS** ✓ — Mac as requester (verify-gate
   "Verify with another device") + iOS as responder (chat-list
   banner click). Same outcome.
5. **Recovery-key restore via verify-gate** ✓ — sign out + sign back
   in lands at verify-gate; "Use recovery key" + paste → device
   verified.
6. **Recovery-key restore via chat-list chooser** ✓ — banner Verify
   tap → chooser → "Use recovery key" → verified.
7. **iOS Settings → Encryption** ✓ — verified status visible to user.
8. **`hasOtherVerifiedDevices` probe disables SAS button** ✓ — when
   no other verified device exists, chooser shows the SAS button
   greyed out with explanatory caption.
9. **SDK timeout cancel propagates** ✓ — both sides show "Verification
   cancelled" with Close button (was a stuck UI before `b511e9a`).
10. **Sign-out cycle returns to verify-gate** ✓.

### Bugs caught + fixed live during testing

- "Couldn't auto-save your recovery key" warning on Mac signed builds
  → entitlements fix (`9c3c954`).
- Click on "Verify with another device" had no visible feedback →
  defer fix (`98705d1`).
- `XCODE_DEVELOPMENT_TEAM` evaporating across `xcodegen generate`
  → sticky team in project.yml (`6ee5b7d`).
- Cancelled SAS sheet had no Close button → `b511e9a`.
- Sidebar verify banner stayed after successful verification →
  `92293a4` + `453e9a9`.
- "Verify with another device" on already-verified Mac re-initiated
  SAS instead of saying "you're verified" → `b511e9a`.
- Chat-list verify-banner only offered SAS, no path to recovery-key
  restore (stranded users with both devices unverified) → `c0c2e99`.
- "SAS" jargon in copy; mid-flow no "waiting for other device" cue;
  clicking Restore showed no progress feedback → `31bfa3c`.
- iOS sign-in URL placeholder rendered as blue link → `6662a6c`.
- iOS SAS got stuck at "Starting verification…" — partner's .ready
  arrived but iOS's rust verification machine silently dropped it
  because iOS's local /keys/query hadn't yet seen Mac's NEW device
  → `57e7c4c` (force-prime via `userIdentity(fallbackToServer: true)`).
- Stale banner on remote cancel before local user clicks Verify →
  `453e9a9`.

### Open work for session 7

Branch is in a great state to merge — but XCUITest coverage of the
new paths is partial. SPM tests cover the cancelled-stream drain
(via `d76e085`); the rest is manual-only.

**Priority A — XCUITest gaps (high-value, ~150 LOC each):**

1. `test_chatListChooser_recoveryKeyPath` — sign in fresh, generate
   recovery key, sign out, sign back in, chat-list banner appears,
   tap Verify → chooser → "Use recovery key" → restore → verified.
   Self-contained on Mac; no two-device dance needed. Add as a new
   `func test_*()` in `MatronVsMatronMacUITests` — shares the
   harness Docker but the test method is independent of the
   existing trust-anchor test.
2. `test_reverseDirection_macAsRequester_iOSAsResponder` — mirror of
   the existing matron-vs-matron flow with directions swapped. Needs
   coordinated test methods in BOTH `MatronVsMatronMacUITests` and
   `MatronVsMatronIOSUITests` because the existing scenario script
   spawns both in parallel.
3. `test_chooser_buttonStates_basedOnHasOtherDevices` — assert SAS
   button is enabled when another verified device exists, disabled
   when not. Lower-cost: probe `hasOtherDevices` is `true` on the
   working setup; test the disabled path by using a freshly
   registered second user with no devices.

**Priority B — recovery-key UI flow scenarios (~250 LOC + new
scenario script):**

4. New scenario `recovery-key-ui.sh` — partner.mjs `bootstrap-anchor`
   first to seed `@matron`'s cross-signing identity, then matron app
   signs in, hits verify-gate, takes the "Use recovery key" path
   with the bootstrap recovery key. Asserts on `chat.matron:recovery-key`
   trace + chat-list mount.
5. `test_recoveryKey_reenterMustMatch` — generate flow's re-enter
   phase rejects mismatched re-entry, accepts matching one. Pure
   single-device.
6. `test_recoveryKey_restoreError_invalidKey` — paste garbage,
   inline error renders + Restore button stays clickable for retry.

**Priority C — UX-only XCUITests (~80 LOC each):**

7. `test_helpMenu_alreadyVerified` — Help menu after verified shows
   green check + Close, no SAS.
8. `test_cancelled_closeButton` — force a SAS cancel via partner
   (timeout), verify Close button appears + clicking it dismisses
   the sheet AND drains the chat-list banner.
9. `test_remoteCancel_drainsBanner` (XCUITest) — already SPM-covered
   in `d76e085`; XCUITest adds end-to-end UI assertion.

**Priority D — sliding-sync / timing investigations:**

10. **iOS rust-verification-machine drops .ready event**
    (workaround landed in `57e7c4c`). Investigate the underlying
    matrix-rust-sdk behaviour to file an upstream bug report. The
    current workaround prevents the symptom but the root SDK bug
    affects any cold-start verification.
11. **matrix-js-sdk same-user-verification lookup miss**
    (`verify-sdk-against-partner.sh` regression from `da37ba2`).
    Documented in session 5 block; partner-side workaround would
    poll the rust olm machine for request registration before
    signalling "ready".

### Files changed this session (~1200 LOC total)

**Product code:**
- `MatronShared/Sources/Verification/VerificationService.swift` —
  `hasOtherVerifiedDevices()`, `cancelledRequests()` protocol additions
- `MatronShared/Sources/Verification/VerificationServiceLive.swift` —
  protocol impl, `cancelledContinuation` in FlowStore,
  `userIdentity(fallbackToServer:)` prime, `routeSasCancelled`
  no-continuation branch, yield `.awaitingConfirmation` in
  `confirmEmojiMatch`
- `MatronShared/Sources/ViewModels/VerificationCenter.swift` —
  `markCompleted(_:)` method, parallel `cancelObservationTask` in
  `start()`/`stop()`
- `MatronShared/Sources/ViewModels/RecoveryKeyViewModel.swift` —
  softer warning copy
- `MatronMac/Features/Verification/MacSasView.swift` — `onCancelled`
  callback, Close button in `.cancelled` case
- `MatronMac/Features/Verification/MacRecoveryKeyView.swift` —
  placeholder text, single Restore button with progress
- `MatronMac/Features/ChatList/MacChatListView.swift` —
  `MacIncomingRequestSasSheet` plumbs `onCancelled`, drain on cancel
- `MatronMac/Features/Onboarding/MacPostLoginVerificationView.swift`
  — defer nav, `onCancelled` to pop nav
- `MatronMac/App/MatronMacApp.swift` — `HelpMenuVerifyDeviceSheet`
  becomes a chooser with already-verified guard
- `MatronMac/App/MatronMac.Debug.entitlements` — add
  `keychain-access-groups`
- `MatronMac/App/MatronMac.Debug.AdHoc.entitlements` (new) —
  ad-hoc-signing variant for harness
- `Matron/Features/Verification/SasView.swift` — `onCancelled`,
  Close button in `.cancelled`
- `Matron/Features/Verification/RecoveryKeyView.swift` —
  placeholder, single Restore button with progress
- `Matron/Features/ChatList/ChatListView.swift` —
  `IncomingRequestSasSheet` and `SelfVerifyThisDeviceSheet` plumb
  `onCancelled` + chooser logic
- `Matron/Features/Onboarding/PostLoginVerificationView.swift` —
  `onCancelled` to pop nav
- `Matron/Features/Onboarding/SignInView.swift` — placeholder text
  fix
- `project.yml` — `DEVELOPMENT_TEAM: 4LJ7WRRRFD`,
  `CODE_SIGN_STYLE: Automatic`
- All 6 `tests/integration/scenarios/*.sh` — `CODE_SIGN_ENTITLEMENTS=
  $ROOT/MatronMac/App/MatronMac.Debug.AdHoc.entitlements` override

**Tests:**
- `MatronShared/Tests/VerificationTests/FakeVerificationService.swift`
  — `hasOtherVerifiedDevicesValue`, `cancelledRequests` stub
- `MatronShared/Tests/VerificationTests/VerificationServiceLiveTests.swift`
  — 2 new tests for `routeSasCancelled` no-continuation +
  defensive branches
- `MatronShared/Tests/ViewModelTests/VerificationCenterTests.swift`
  — `ScriptedVerificationService` gains `scheduleCancelledIDs(_:)`,
  2 new tests for cancelled-stream drain

### How to validate the branch

All SPM tests pass:
```bash
cd MatronShared && swift test
```

Mac signed build:
```bash
xcodebuild build -scheme MatronMac -destination 'platform=macOS' -allowProvisioningUpdates
```

Mac harness build (ad-hoc):
```bash
xcodebuild build -scheme MatronMac -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_ENTITLEMENTS="$PWD/MatronMac/App/MatronMac.Debug.AdHoc.entitlements"
```

Integration scenarios (still green):
- `tests/integration/run-harness.sh matron-vs-matron-ui.sh` ✓
- `tests/integration/run-harness.sh chat-list-sdk.sh` ✓
- `tests/integration/run-harness.sh recovery-key-sdk.sh` ✓
- `tests/integration/run-harness.sh verify-sdk-against-partner.sh`
  ✗ (matrix-js-sdk same-user-verification race; documented session 5)

### Things to NOT undo (specific to session 6)

- Don't drop `userIdentity(fallbackToServer: true)` from
  `startSAS`'s prelude — it's not optional cosmetics, it's the
  workaround for an iOS-side rust-verification-machine bug that
  silently drops `.ready` events when the partner's device_id
  isn't in the local cache at request time.
- Don't drop the `cancelledRequests()` stream — `routeSasCancelled`'s
  no-active-continuation branch needs somewhere to broadcast,
  otherwise stale banners reappear.
- Don't merge `MatronMac.Debug.entitlements` and
  `MatronMac.Debug.AdHoc.entitlements` into one — they have
  different `keychain-access-groups` posture by signing mode and
  the harness depends on having an ad-hoc-friendly file to point
  `CODE_SIGN_ENTITLEMENTS=` at.
- _(Corrected by session 7 — see session-7 block above for context.)_
  The chat-list-banner-tap chooser surface
  (`MacUnverifiedDeviceBanner` → `HelpMenuVerifyDeviceSheet.chooserView`)
  was added to recover devices in the state `verifyDone=true` AND
  `isThisDeviceVerified()=false`. Session 7 verified the original
  description of when this happens was wrong: `MatronMacApp.signOut()`
  *does* clear `verifyDone` (line 328), so a normal File → Sign Out →
  sign-back-in cycle lands at the verify gate, NOT the chat list with
  banner. The split state is only reachable via app force-quit +
  external state surgery (admin-revoked device, manual `rm -rf basePath`
  while UserDefaults persists). For a never-released app there are no
  upgrade paths to this state either. **Consider deletion** rather
  than preservation — session-8 Priority C.

---

## Session 5 — matron-vs-matron-ui ✓ GREEN end-to-end

**TL;DR for the next agent:** matron-vs-matron-ui passes — both peers
reach `verificationStateListener: fired with verified`. Latest run:
`tests/integration/artifacts/20260505-071320/`. The fix landed in four
layers, each one revealing the next blocker:

1. **`autoEnableCrossSigning(true)` on every `ClientBuilder()`** —
   without this the local crypto store carries only an "empty cross
   signing identity stub" and `getSessionVerificationController()`
   throws "Failed retrieving user identity" forever (no retry budget
   was ever enough). Element X parity.
2. **Element X `recoveryState` branching in `RecoveryKeyManager.generateAndPersist`** —
   once cross-signing auto-bootstraps on first sign-in, the recovery
   state may not be `.disabled`, and calling `enableRecovery()` on a
   non-`.disabled` state hangs. Branch to `resetRecoveryKey()`
   otherwise. Element X `SecureBackupController.generateRecoveryKey:113-145`
   parity.
3. **`acknowledgeVerificationRequest(senderId:flowId:)` before
   `acceptVerificationRequest()`** in `acceptIncoming` — this was the
   actual reason `acceptVerificationRequest()` silently no-op'd
   originally (the early "30 s sliding-sync long-poll" hypothesis was
   wrong; the SDK was waiting for the ack, not for the sync round).
   Element X `SessionVerificationControllerProxy.acknowledgeVerificationRequest:71-80`
   parity. The `senderId` is captured in `routeIncomingRequest` from
   the SDK's `didReceiveVerificationRequest` callback and stashed in
   `FlowStore.senderIDs`.
4. **Responder-skip guard in `routeAcceptedVerificationRequest`** —
   only the requester (initiator) calls `startSasVerification()`. With
   both sides calling, matrix-rust-sdk's verification machine sees
   duplicate `m.key.verification.start` events on each peer and fires
   `didCancel` within milliseconds. Wave 7's original guard was
   correct; the post-Wave-7 revert (commit 59b3180) was a regression
   driven by misdiagnosis of an unrelated partner.mjs flake.

Plus the diagnostic stack that made all four diagnoses tractable:

- `MatronSDKTracing.setup()` → `MatrixRustSDK.initPlatform(...)` with
  file output to `<cachesDirectory>/matron-sdk-trace/`. Every
  rust-side verification / sliding-sync / `/keys/query` event is now
  observable. Without this we were flying blind for three sessions.
- `RecoveryKeyManager.generateAndPersist` os.Logger entries
  (mirroring `restore`'s coverage).
- `matron-vs-matron-ui.sh` collects `log show` fallback (live
  `log stream` is unreliable) and pulls the SDK trace files for
  both Mac and iOS sim into the artifact dir.

### Working tree (uncommitted)

| File | What changed |
|------|------|
| `MatronShared/Sources/Auth/AuthServiceLive.swift` | `.autoEnableCrossSigning(autoEnableCrossSigning: true)` on both `ClientBuilder()` sites (probe + login). |
| `MatronShared/Sources/Sync/ClientProvider.swift` | Same — `.autoEnableCrossSigning(autoEnableCrossSigning: true)` on the resume-session ClientBuilder. |
| `MatronShared/Sources/Auth/SDKTracing.swift` | New file. `MatronSDKTracing.setup()` wraps `MatrixRustSDK.initPlatform(config:useLightweightTokioRuntime:)` with file output to `<cachesDirectory>/matron-sdk-trace/`. Idempotent. |
| `Matron/App/MatronApp.swift`, `MatronMac/App/MatronMacApp.swift` | Call `MatronSDKTracing.setup()` as the first line of `bootstrap()` so the SDK is wired BEFORE the first ClientBuilder lands. |
| `MatronShared/Sources/Verification/RecoveryKeyManager.swift` | `generateAndPersist` now branches on `encryption.recoveryState()`: `.disabled` → `enableRecovery()`, otherwise → `resetRecoveryKey()`. Plus entry/SDK-call/exit logging mirroring `restore`. |
| `MatronShared/Sources/Verification/VerificationServiceLive.swift` | The 60 × 500 ms retry from session 4 stays — kept as belt-and-braces in case `autoEnableCrossSigning` doesn't propagate identity in time on the first listener fire. With autoEnableCrossSigning the retry is now a no-op (succeeds on attempt 1). |
| `MatronUITests/MatronVsMatronIOSUITests.swift` | `waitForReadyFile` mtime gate widened from `runStartedAt` to `runStartedAt - 5min`. Mac bootstrap is now fast enough (~30 s post-fix) that Mac writes the marker BEFORE iOS's `setUp()` fires; the strict gate was rejecting fresh files. |
| `tests/integration/scenarios/matron-vs-matron-ui.sh` | Added `log show` fallback + SDK-trace file collection. The scenario now writes `matron-mac-show.log`, `matron-ios-show.log` (unified-log replay over the run window), `matron-mac-sdk.log`, `matron-ios-sdk.log` (rotated SDK trace files). Trace assertion accepts a marker in EITHER live stream OR show fallback. |

### Confirmed evidence (run `tests/integration/artifacts/20260504-213538/`)

Mac's chat.matron + SDK trace, in order:
```
21:36:51.770  recovery-key   generate: enter
21:36:51.770  recovery-key   generate: recoveryState=disabled
21:36:51.770  recovery-key   generate: state=.disabled — calling encryption().enableRecovery
21:36:51.836  recovery-key   generate: enableRecovery returned (keyLength=59)
21:36:51.842  recovery-key   generate: keychain.set threw -34018 (expected for unsigned Debug)
21:37:00.611  verification   verificationStateListener: fired with verified  ← cross-signing live
21:37:00.756  verification   buildController: fetched (handle: …) on attempt path  ← attempt 1!
21:37:14.019  verification   SDK→didReceiveVerificationRequest from=@matron:localhost
21:37:15.327  verification   acceptIncoming: enter
21:37:15.328  verification   acceptIncoming: acceptVerificationRequest returned OK
[then silence — no SDK→didStartSasVerification, no didReceiveVerificationData]
```

iOS's chat.matron, in order:
```
21:37:13.897  verification   installVerificationStateListener: initial state=unverified
21:37:13.984  verification   buildController: fetched (handle: …) on attempt path  ← attempt 1!
21:37:13.984  verification   startSAS: calling requestDeviceVerificationIfPossible
21:37:13.994  verification   startSAS: SDK request returned — yielding .requested
[then silence — no SDK→didAcceptVerificationRequest]
```

### Why this took so long — false leads worth recording

**False lead 1: "30 s sliding sync long-poll delays outgoing
`m.key.verification.ready`."** This was a plausible-looking
explanation in the session-5-mid notes — Mac's encryption-conn
position would tick once every 30 s, suggesting outgoing requests
also got drained at that cadence. **The actual issue was that
`acceptVerificationRequest()` was a no-op because we'd never
called `acknowledgeVerificationRequest(senderId:flowId:)` to
register the active inbound flow.** Mac's outgoing queue was
empty, not waiting; Mac never had anything to send. Lesson: when
"pipeline blocked" looks like a credible stall hypothesis, also
check whether the work was ever actually queued.

**False lead 2: "Wave 7 was wrong, both sides must call
`startSasVerification`."** Session 2's revert (commit 59b3180)
was driven by a misdiagnosed partner.mjs flake. Session 5 reproed
the same flake while exercising the correct (responder-skip) shape
in matron-vs-matron-ui — confirming partner.mjs's matrix-js-sdk
RustCrypto race is unrelated to matron's startSas behaviour. The
correct shape is what Wave 7 originally landed: only the requester
(initiator) calls `startSasVerification`, per the Matrix spec.

### What's been ruled IN (and stays)

1. `autoEnableCrossSigning(true)` makes cross-signing auto-bootstrap.
   Live evidence: SDK trace contains the cross-signing keys upload
   AND `verificationStateListener: fired with verified` for Mac's own
   device.
2. `RecoveryKeyManager.generateAndPersist`'s recoveryState branching
   means session 4's recovery-key-stall regression DOES NOT recur —
   the flow now completes in ~70 ms (state=.disabled → enableRecovery
   returns synchronously).
3. SDK-internal tracing via `initPlatform` is the right shape — both
   apps now produce ~500-line debug-level trace files captured by the
   harness. Element X's pattern; works for us.
4. `log show` fallback in the scenario is essential. Live `log stream`
   intermittently captures zero entries for reasons not pinned down,
   but the unified-log replay is reliable. Use it as the primary
   diagnostic surface; `log stream` is now belt-and-braces.

### What's been ruled OUT

1. The session 4 hypothesis "autoEnableCrossSigning regresses
   recoverykey.generate" — not real. The session 4 stall was a
   stale-state artifact (multiple back-to-back UI test runs without
   environment cleanup); after `simctl shutdown all` + `pkill -x
   testmanagerd` (host only) + wiping defaults plist, the recovery-key
   flow runs cleanly with autoEnableCrossSigning enabled.
2. Session 3 "Mac doesn't render banner" — also not real. With the
   crypto identity properly bootstrapped, Mac DOES render the banner
   AND the test clicks it (timeline: t=42.27s click on
   `verifybanner.accept`). The session 3 framing was correct
   (something downstream stalls) but wrong about the layer (it was
   `getSessionVerificationController` failing, not the banner UI).

### Concrete next steps (ranked)

1. **Live-validate matron-vs-matron against the user's real
   homeserver.** The scenario is green against a fresh Docker
   homeserver; the next test is an actual sign-in on
   `https://matrix-dev2.yearbooks.be` with two real matron devices.
2. **iOS sim verify-with-other-device retest.** The Mac side of
   matron-vs-matron-ui exercises Mac-as-responder; the iOS side
   exercises iOS-as-requester. Both green via the harness, but the
   iOS sim was not driven through the Help-menu / Settings paths
   yet — that's a small follow-up.
3. **Decide on PR #3 disposition.** PR #3 has accumulated 7 fix-up
   waves + the session-5 close-out commits on top of the Phase 3
   base. Merge-as-is is the pragmatic call; Phase 4+ work picks up
   from main.
4. **(Stretch.)** Investigate the matrix-js-sdk RustCrypto race so
   verify-sdk-against-partner.sh and verify-mac-ui-against-partner.sh
   come back green — see the test infra status section below for
   the partner-side workaround sketch.

### Test infra status (delta vs session 4)

- Mac+iOS UI test runners now produce `matron-{mac,ios}-{stream,show,sdk}.log`
  artifacts per run. Stream files often empty (TCC throttle); show files
  reliable; SDK files reliable.
- `matron-vs-matron-ui.sh`: ✓ PASS (run `20260505-071320`).
- `chat-list-sdk.sh`, `recovery-key-sdk.sh`: ✓ PASS (regression test post-fix).
- `verify-sdk-against-partner.sh` and `verify-mac-ui-against-partner.sh`:
  ✗ FAIL — both depend on partner.mjs's matrix-js-sdk RustCrypto, which
  has an upstream same-user-verification lookup bug
  (`"Ignoring just-received verification request which did not start a
  rust-side verification"`). The rust olm machine logs
  `INFO matrix_sdk_crypto::verification::machine: Received a new
  verification request` so it definitely processed matron's request —
  but matrix-js-sdk's wrapper at
  `node_modules/matrix-js-sdk/lib/rust-crypto/rust-crypto.js:1768`
  then calls `olmMachine.getVerificationRequest(sender, txnId)` and
  gets `null`. The wrapper's lookup doesn't find requests where
  `sender == ourOwnUserID` (same-user verifications, which is exactly
  what matron-vs-partner is — both are devices of `@matron:localhost`).
  Pre-fix this scenario flaked ~1-in-3, "self-resolving" sometimes
  because matron was slow enough that the rust olm machine had
  wallclock time to settle whatever internal indexing made the lookup
  work; post-fix matron is faster (`autoEnableCrossSigning` removed
  a bootstrap step) and the lookup misses every time. matrix-rust-sdk
  issue 2896 references the same surface. **Trade-off accepted:**
  matron-vs-matron-ui (real-product flow) is more load-bearing than
  matron-vs-matrix-js-sdk (test-harness interop). If this needs to
  come back green, the path is a partner-side workaround in
  `bootstrap-and-wait` — poll the olm machine until
  `getVerificationRequest` returns the request, before signalling
  "ready"; or hold the request via the lower-level
  `olmMachine.receiveSyncChanges` callback rather than going through
  matrix-js-sdk's high-level wrapper.

---

## Session 4 — root cause confirmed: SDK identity isn't loaded

**TL;DR for the next agent:** session 3's "Mac doesn't render banner"
framing was the symptom, not the cause. The actual blocker is
**`client.getSessionVerificationController()` throws
`ClientError.Generic("Failed retrieving user identity")` on iOS** —
so iOS never reaches `requestDeviceVerification()` and Mac never
receives anything to render. Both sides hit this; on Mac it surfaces
when the chat-list mounts, on iOS when the user taps "Verify with
another device".

The SDK integration test at
`MatronIntegrationTests/VerificationFlowIntegrationTests.swift:140-168`
**already documents the same error** (read its docstring carefully) and
works around it with a 60 × 500ms retry. The UI flow has no equivalent
retry. The error is silently swallowed by `try?` in
`installVerificationStateListener`'s callback path.

### What's in the working tree (uncommitted)

`MatronShared/Sources/Verification/VerificationServiceLive.swift` now
has a 60 × 500ms retry + per-attempt `os.Logger.notice` inside
`buildController()`. Without this you don't see the error at all (it
hits `try?`) — keep this even if you change the fix shape, because the
next time this stalls you'll want the trace.

### Confirmed evidence (run `tests/integration/artifacts/20260504-203040/matron-mac.log`)

After retry-only fix, both sides log:
```
buildController: getSessionVerificationController() threw on attempt N/60:
  MatrixRustSDK.ClientError.Generic(msg: "Failed retrieving user identity", ...) — retrying in 500ms
... (60 attempts) ...
buildController: getSessionVerificationController() failed after 60 attempts
```

i.e., 30s of retries does NOT clear the error in this scenario. The
identity never lands in the local crypto store. Compare with the SDK
test which usually clears within a few attempts — the difference is
how the cross-signing identity gets into the SDK's local store, which
is the next thread to pull.

### Tried and ruled out (DO NOT re-attempt without understanding)

1. **`autoEnableCrossSigning(true)` on `ClientBuilder`** (the
   Element-X-iOS-parity fix at
   `ElementX/Sources/Other/Extensions/ClientBuilder.swift:42`).
   *Diagnostic value:* Element X explicitly relies on this flag to
   bootstrap cross-signing on first sign-in; without it the SDK's
   "Failed retrieving user identity" path never resolves on the
   trust-anchor side. *Why it didn't land:* it caused a regression in
   the recovery-key generate flow — the click on `recoverykey.generate`
   takes ~12s to deliver (XCUITest's "Falling back to element center
   point" diagnostic shows the runner couldn't find a precise
   hit-test target for ~5s after the click was synthesised, then
   another ~5s before the app went idle), and `enableRecovery` never
   appears to return inside that window. Whether enableRecovery is
   genuinely hanging or whether it's an unrelated test-runner artefact
   wasn't conclusively determined — the chat.matron logs went
   completely silent in those runs (no `RecoveryKeyManager` log
   either, even with explicit logging added) which points at a deeper
   interaction.

2. **`waitForE2eeInitializationTasks()` + `userIdentity(fallbackToServer: true)`
   inside `buildController` before the retry.** The intuition was that
   waiting for E2EE init would cover the trust-anchor side and the
   identity prefetch would force `/keys/query` for the responder side
   without changing ClientBuilder behaviour. *Result:* same failure mode
   as autoEnableCrossSigning — recovery-key flow stalls at the Generate
   click, no diagnostic logs from anywhere in the chat.matron subsystem
   even though the binary contains the strings (verified via
   `strings .../MatronVerification.framework/.../MatronVerification`).
   Reverted.

3. **Stale `testmanagerd` from prior wedged runs.** Killed
   (`pkill -x testmanagerd`) between attempts; no behavioural change.
   The host testmanagerd is not the proximate cause of the regression.

### Concrete next steps (ranked)

1. **Reproduce on a clean Mac state.** Kill Docker, `simctl shutdown
   all`, restart Mac if practical. The recovery-key click delay is
   environmental in some way that wasn't pinned down — multiple runs
   in a row exhibit it identically, suggesting cumulative state, but
   restarts may clear it. Without that baseline restored, you can't
   tell whether autoEnableCrossSigning's regression is real or a
   stale-state artefact.

2. **If autoEnableCrossSigning's regression is real:** the Element X
   shape uses `autoEnableCrossSigning(true)` AND has a more elaborate
   recovery state machine in `SecureBackupController.swift`. Their
   `generateRecoveryKey` checks `recoveryState.value == .disabled` and
   calls `resetRecoveryKey()` instead of `enableRecovery` if cross-
   signing is already bootstrapped (lines 113-145). Mirror this:
   inspect `client.encryption().recoveryState()` and pick
   `enableRecovery` vs `resetRecoveryKey` accordingly. This is the
   missing piece — once cross-signing is auto-enabled, calling the
   bootstrap-shaped `enableRecovery` is the wrong API.

3. **Don't trust the HANDOVER's hypothesis ranking from session 3.**
   All five hypotheses (sync race, delegate timing, factory churn,
   Wave-7 lazy controller, server replay) assumed iOS was sending the
   request. iOS's `m.key.verification.request` was never sent in any
   recorded run. The whole responder-side investigation is downstream
   of fixing iOS's controller fetch first.

### Test infrastructure note

The matron-vs-matron-ui scenario's runtime os.Logger collection
intermittently captures zero `chat.matron` entries even when the
test runs to completion. The streams do attach (filter line is
written), but no log entries appear. Multiple runs across late
session 4 had this empty-log behaviour despite the binary being
known-correct (verified by `strings` against the linked
`MatronVerification.framework`). Whether this is an os.Logger
buffering issue, a TCC/sandbox throttle, or something else wasn't
nailed down. Workaround: query the unified log directly with
`/usr/bin/log show --predicate 'subsystem == "chat.matron"' --last 5m
--info` after a failing run, AND grep the test bundle log for any
verification-related output.

---

## Session 3 — current state of `matron-vs-matron-ui`

**TL;DR for the next agent:** the test scaffolding is built and
executes both peers fully through SAS *initiation*. The remaining
blocker is *Mac doesn't render the incoming-verify banner*, which is
either a real product bug (HANDOVER open risk #1) or a
sync/lifecycle race between recovery-key bootstrap completing and
`VerificationCenter` registering its delegate. Before iterating
further on the test wrapper, focus on the Mac responder code path.

### What got built (commits since `ba7f4fa`)

```
879f44e fix(test/scenario): poll-grep watcher instead of tail|grep -m1
56672ab fix(test/scenario): tail watcher must start from line 1
62d10b0 fix(test): stdout marker + host-side ready-file watcher
7aef48d fix(test): synchronize via /Users/Shared instead of /tmp
2559f1f fix(test/scenario): aggressive Mac defaults wipe via plist + cfprefsd
ad3f424 fix(test/scenario): brace-quote $CONFIG_FILE before unicode ellipsis
8db0d7c test: register matron-vs-matron-ui.sh in run-harness auto-skip
7cbf8f8 fix(test/scenario): matron-vs-matron-ui.sh polish
213566d test: add matron-vs-matron-ui.sh scenario
7df0464 fix(test/mac): meaningful sheet-dismiss signal + pasteboard diagnostic
4cea75a test(mac): MatronVsMatronMacUITests — drive Mac as trust anchor
b783f96 fix(test/ios): clickAndPaste cleanup + stale-ready-file guard
aa3bef0 test(ios): MatronVsMatronIOSUITests — drive iOS as verify requester
208b379 fix(harness): tail -f /dev/null instead of sleep infinity
4197549 test(ios): add MatronUITests XCUITest target
bb66d8a feat(mac): plumb XCUITest accessibility identifiers
46394a8 feat(ios): plumb XCUITest accessibility identifiers
552d4a4 docs: implementation plan for matron-vs-matron UI test
5c1c81f docs: spec for matron-vs-matron UI test scenario
```

Plus:
- Spec: [`docs/superpowers/specs/2026-05-04-matron-vs-matron-ui-test-design.md`](superpowers/specs/2026-05-04-matron-vs-matron-ui-test-design.md)
- Plan: [`docs/superpowers/plans/2026-05-04-matron-vs-matron-ui-test.md`](superpowers/plans/2026-05-04-matron-vs-matron-ui-test.md)

### Files added / modified

| Path | What it does |
|------|------|
| `MatronUITests/MatronVsMatronIOSUITests.swift` | iOS XCUITest — sign in, tap "Verify with another device", confirm SAS emojis. Reads `/tmp/matron-test-config.json`, polls `/Users/Shared/matron-mac-ready` with mtime gate. |
| `MatronMacUITests/MatronVsMatronMacUITests.swift` | Mac XCUITest — sign in, drive multi-phase `MacRecoveryKeyView` (Generate → Copy → ack toggle → Continue → Paste → auto-confirm), wait for chat list to mount, `print("MATRON_MAC_TRUST_ANCHOR_READY")`, wait for `verifybanner.accept`, click, confirm SAS emojis. |
| `tests/integration/scenarios/matron-vs-matron-ui.sh` | Orchestrator — wipes state (defaults plist + cfprefsd kill, sandbox container nuke, simctl uninstall), parallel `xcodebuild build-for-testing`, parallel `test-without-building`, captures both runtime os.Logger streams, runs a 1s-poll watcher that turns Mac's stdout marker into `/Users/Shared/matron-mac-ready`, asserts both rc=0 AND both runtime logs contain `verificationStateListener: fired with verified`. |
| `tests/integration/run-harness.sh` | (1) `tail -f /dev/null` instead of `sleep infinity` (BSD `sleep` rejects `infinity`), (2) added `matron-vs-matron-ui.sh` to the inline-bootstrap auto-skip list (no partner.mjs in this scenario). |
| `Matron/Features/Onboarding/SignInView.swift` | +4 a11y IDs: `signin.{server,username,password,submit}` |
| `Matron/Features/Onboarding/PostLoginVerificationView.swift` | +3 a11y IDs: `verifygate.{verifyWithOtherDevice,useRecoveryKey,generateNew}` |
| `Matron/Features/Verification/SasView.swift` | +2 a11y IDs: `sas.{match,dontMatch}` |
| `MatronMac/Features/Verification/MacVerificationBanner.swift` | +1 a11y ID: `verifybanner.accept` (the "Verify" button on the incoming-request sidebar banner) |
| `MatronMac/Features/Verification/MacRecoveryKeyView.swift` | +5 a11y IDs across the multi-phase generate flow: `recoverykey.{generate,copy,acknowledgeSaved,continue,paste}` |
| `project.yml` | Added `MatronUITests` target (mirrors `MatronMacUITests`, iOS sim, no signing). Added to `Matron` scheme's `testTargets`. |

### Run it

```bash
tests/integration/run-harness.sh matron-vs-matron-ui.sh
```

`run-harness.sh` boots Docker tuwunel, registers `@matron`, skips
partner-bootstrap (auto-detected from scenario name), then hands off.
The scenario script handles all UI-runner state wiping, parallel build,
parallel test runs, log capture, and trace assertions. Total wall time
for a clean run: ~3-5 minutes (most of it is parallel xcodebuild
compile + waits).

### Observed test results — where it stops

Latest run (commit `879f44e`):

| Side | Outcome |
|------|---------|
| Mac sign-in | ✅ form found, server/user/pw pasted, submit clicked, post-login screen reached |
| Mac recovery-key bootstrap | ✅ all 4 phases drive cleanly (`recoverykey.generate` → `.copy` → ack toggle → `.continue` → `.paste` → auto-advance to `.confirmed` → 600ms `.task` fires `onFinished()` → `verifyDone=true` → MacChatListView mounts → `MATRON_MAC_TRUST_ANCHOR_READY` printed) |
| Synchronization | ✅ scenario watcher catches the stdout marker via 1s poll-grep, touches `/Users/Shared/matron-mac-ready` |
| iOS sign-in | ✅ form found, server/user/pw typed, submit tapped, verify-gate reached |
| iOS verify-with-other-device | ✅ button tapped, SAS controller built, `startSAS: enter userID=@matron:localhost` logged → `m.key.verification.request` sent over to-device |
| Mac receives request | ❌ **FAILS HERE.** `verificationStateListener` fires twice on Mac (initial-after-signin + post-bootstrap), but `MacVerificationBanner` never renders. iOS waits 60s for SAS sheet, gives up; Mac waits 120s for `verifybanner.accept`, gives up. |

UI hierarchy at Mac timeout (extracted from xcresult): chat list is
fully mounted with sidebar + Compose toolbar + the
`MacUnverifiedDeviceBanner` ("This device hasn't been verified.
Verify."), but no `MacVerificationBanner` for the incoming request.

### Specific debugging hypotheses to chase next

1. **Sync-restart race on `verifyDone` flip.** `MatronMacApp` swaps
   between the verify-gate branch and the chat-list branch when
   `verifyDone` becomes true. Both branches have a
   `.task { try? await dependencies.syncService(for: session).start() }`,
   but the swap cancels the gate-branch's `.task` and starts the
   chat-list branch's. If `syncService.start()` is non-idempotent or
   the cancellation interrupts mid-`/sync`, the to-device event from
   iOS could land in a window where neither task is actively
   processing. Worth: instrument `SyncServiceLive.start()` with
   os.Logger entry/exit + cancellation traces, run the scenario,
   and check whether iOS's request arrives during a sync gap.

2. **VerificationCenter delegate registration timing.**
   `MacChatListView` builds + starts `VerificationCenter` in
   `.task(id: session.userID)` (lines 124-130 of `MatronMacApp.swift`).
   That `.task` runs *after* the view body — there's a window between
   `verifyDone=true` flipping and the center being live. If iOS's
   request arrives in that window, the `verificationService` may
   process it but no delegate is attached to surface it as a
   `VerificationRequestSummary` for the banner. Worth: log the exact
   moment `center.start()` returns + any `didReceiveVerificationRequest`
   delegate fires; compare against iOS's `startSAS` timestamp.

3. **`verificationService(for: session)` instance churn.** The verify
   gate branch and the chat-list branch both pass through
   `dependencies.verificationService(for: session)` — but if that
   factory rebuilds the service per-call rather than caching by
   session, the chat-list branch gets a fresh service whose internal
   state didn't observe the gate-time events. Worth: confirm the
   factory caches; log the service identity (e.g. `ObjectIdentifier`)
   from both branches to verify it's the same instance.

4. **Wave 7 lazy-controller pattern + matrix-rust-sdk responder
   semantics.** The handover open-risk #1 specifically warned this.
   Wave 7 made the controller build lazily via
   `verificationStateListener`. If the listener fires with
   `unverified` *before* the SDK has cached an incoming request, the
   built controller might miss subsequent request events. The
   `acceptIncoming` path was the original Wave 7 #6 territory. Worth
   reading: `MatronShared/Sources/Verification/VerificationServiceLive.swift`
   alongside ElementX iOS's reference impl in
   `/Users/danbarker/Dev/yearbook-messages-ios/ElementX`.

5. **Server-side cross-signing replay.** When iOS signs in second, it
   inherits the cross-signing identity Mac just uploaded. The
   `requestDeviceVerification` to-device event might land before
   Mac's local crypto store has finished processing iOS's `/keys/upload`
   reply, so the to-device event fails an internal lookup
   ("device unknown") and the SDK silently drops it. Workaround: have
   iOS test wait an extra ~5s after signing in before tapping verify,
   to let device-list propagation settle.

### Gotchas worth knowing (do NOT re-derive)

- **Mac UI test runner is sandboxed.** Filesystem writes to `/tmp` AND
  `/Users/Shared` both fail with POSIX EPERM ("Operation not
  permitted"). Synchronization between Mac UI test and iOS UI test
  cannot be done via the runner's filesystem. We use `print()` →
  xcodebuild captures stdout in test log → host bash polls the log
  with `grep -q` and writes the ready-file (host bash CAN write
  `/Users/Shared`). See commit `62d10b0` for the rationale block.
- **`tail -F` defaults to last 10 lines.** A naive `tail -F log | grep
  marker` will skip the marker entirely if it's already past the
  10-line tail when the watcher starts. Use `tail -n +1 -F` to start
  from line 1. (We then switched to a poll-grep loop because BSD
  `grep -m1` doesn't exit promptly when reading from a still-live
  pipe — see commits `56672ab` + `879f44e`.)
- **`defaults delete chat.matron.mac` is unreliable.** cfprefsd
  caches the in-memory domain and serves stale `verifyDone` flags
  even after `defaults delete`. Belt + braces: `rm` the plist file
  AND `killall cfprefsd`. See commit `2559f1f`.
- **macOS BSD `sleep infinity` doesn't exist.** Use `tail -f
  /dev/null`. See commit `208b379`.
- **`xcodegen generate` must be run after adding new test files.**
  Even though `sources: [{ path: ... }]` should auto-discover, the
  pbxproj doesn't update until you re-run xcodegen. We saw this
  silently produce "Executed 0 tests" with `** TEST EXECUTE
  SUCCEEDED **" because the new test class wasn't in the bundle —
  always run `xcodegen generate` after dropping a new
  `*UITests.swift` file in.
- **iOS sim's `/tmp` is NOT host's `/tmp`.** They're separate
  filesystems. `xcrun simctl spawn UDID ls /tmp/foo` will not see
  host /tmp. *However*, the **iOS UI test runner** runs on the
  host (not in the sim) — the runner uses `XCUIApplication` to drive
  the simulated app via XPC, but the test code itself executes on
  the host. So host `/tmp` IS readable from the iOS test code (which
  is how the iOS test reads `/tmp/matron-test-config.json` and
  `/Users/Shared/matron-mac-ready`).
- **Stale `testmanagerd` from a wedged prior run** can hold the
  LocalAuthentication subsystem hostage and any subsequent Mac
  XCUITest run will fail with `LAErrorSystemCancel` ("System
  authentication is running"). Fix:
  `pkill -x testmanagerd` (only the host one — the simruntime
  testmanagerd inside CoreSimulator is fine).
- **`MacRecoveryKeyView` generate flow is 4 phases**, not 2 like the
  spec originally assumed: `.notStarted` (Generate button), `.show`
  (Copy + Toggle + Continue), `.reenter` (TextField + Paste, with
  auto-advance via `.onChange`), `.confirmed` (auto-dismiss after
  600ms). The Mac UI test must drive each phase explicitly.
- **`pasteBtn.exists==false` is *not* a sufficient signal that the
  recovery-key sheet has fully dismissed**, because the SwiftUI
  switch-case transitions to `.confirmed` first (paste button stops
  rendering immediately), THEN the `.confirmed` view's `.task`
  waits 600ms before calling `onFinished()` which actually flips
  `verifyDone` and dismisses the sheet. The Mac test currently
  treats `pasteBtn` disappearance as the synchronization point;
  `verifybanner.accept` not appearing on time may be partly because
  iOS races the chat-list mount. Consider waiting for a chat-list
  element (e.g. the Compose toolbar `square.and.pencil` button) to
  exist before printing the ready marker.

### Test infra status

- `MatronTests` (iOS host SPM-style): **228 passing, 4 skipped** (unchanged)
- `Matron` scheme tests: **53 passing** (unchanged)
- `MatronMac` scheme tests: **66 passing** (unchanged)
- `MatronIntegrationTests`: 4 (3 pass + 1 skipped, unchanged)
- `MatronMacUITests`: now contains 2 classes — `VerifyWithPartnerUITests` (passes via existing scenario) + `MatronVsMatronMacUITests` (new, fails as documented above)
- `MatronUITests`: new target, 1 class — `MatronVsMatronIOSUITests` (test currently XCTSkips on standalone runs since the synchronization file isn't there; passes as far as `startSAS` when run via the scenario)

### Where the next agent should pick up

Order by load-bearingness:

1. **Debug Mac responder path.** Add os.Logger entries to
   `MacChatListView`'s VerificationCenter wiring + `VerificationCenter.start()`
   + `VerificationServiceLive`'s `didReceiveVerificationRequest`
   delegate, run the scenario, find where iOS's request gets dropped.
   This is the actual matron-vs-matron bug; the test infrastructure
   is now sufficient to reproduce it deterministically every run.
2. Once Mac receives the request, the rest of the test should sail
   through to green — both sides reach SAS emojis, both sides confirm,
   both sides land at `verificationStateListener: fired with verified`.
3. (Stretch.) Wire `matron-vs-matron-ui.sh` into a future
   `run-all-ui.sh` once it's stably green.

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

- **SPM:** 228 (4 skipped — those need iCloud Keychain entitlement
  the SPM host doesn't have). Was 224 pre-session-2; +4 across
  `test_retriesOnEmptySnapshot_until_populated`,
  `test_routeAcceptedVerificationRequest_doubleFire_isSafe`,
  `test_routeAcceptedVerificationRequest_noRole_stillCallsStartSas`,
  and `test_routeAcceptedVerificationRequest_startSasThrows_cleansUp`.
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

1. **matron-vs-matron responder broken (session 3 finding).**
   ✓ RESOLVED in session 5 — see Session 5 block at top of this file.
   Root cause was missing `acknowledgeVerificationRequest` before
   `acceptVerificationRequest` in `acceptIncoming`, plus duplicate
   `m.key.verification.start` from both peers calling
   `startSasVerification`. Both fixed; matron-vs-matron-ui ✓ green
   end-to-end (run `20260505-071320`). The session-3 hypotheses
   ranked above were investigating the wrong layer — the chat-list
   delegate registration was fine; the SDK was silently no-op'ing
   `acceptVerificationRequest`. Kept here as historical record.

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
   ✓ RESOLVED in session 5 close-out. `MacPostLoginVerificationView`
   now defers the `path.append(.sasWithOtherDevice)` mutation by
   ~120 ms inside a `Task { @MainActor in … }` so the button's
   press-up animation visibly completes before NavigationStack
   unmounts the host view.

4. **`testAcceptIncomingVerificationRequestFromPartner`** SDK test
   still skip-gated. matron-side code is correct as-is:
   `acceptIncoming` only calls `acceptVerificationRequest` (sends
   `.ready`); matrix-rust-sdk auto-progresses SAS when the
   initiator's `.start` arrives via `didStartSasVerification` +
   `didReceiveVerificationData` callbacks. (Commit `03d7c30`
   added a synthesised `startSasVerification` call here; reverted
   in commit `4bdca06` — the SDK throws "Verification request
   missing" when called immediately after accept, before the
   initiator's `.start` arrives. Element X's "user taps Start"
   pattern works because the user-tap gives the SDK time; we
   can't synthesise that delay programmatically without flake.)

   The blocker is partner-side and it's **upstream**:
   `request.startVerification("m.sas.v1")` from matrix-js-sdk's
   RustCrypto throws `"startVerification(): other device is
   unknown"` because the rust olm machine doesn't have matron's
   device cached, even after `cryptoApi.getUserDeviceInfo(...,
   downloadUncached: true)` was called moments earlier (which
   does return the device — the data is just somewhere matrix-js-sdk
   doesn't read from for verification). matrix-js-sdk's source
   explicitly references this as
   [`matrix-rust-sdk` issue 2896](https://github.com/matrix-org/matrix-rust-sdk/issues/2896)
   in `tests/integration/partner/node_modules/matrix-js-sdk/lib/rust-crypto/verification.js:341`
   — the workaround in matrix-js-sdk only covers detection, not
   resolution. Tried explicit `/keys/query` refresh immediately
   before `startVerification` — same error. Without an upstream
   fix or a more invasive workaround (manually priming the rust
   olm machine via `markAllTrackedUsersAsDirty` + manual sync
   trigger, then waiting), the responder integration test stays
   blocked.

   The Swift-side scaffolding (test method, scenario script,
   FlowStore-actor continuation race fix from commit `9314331`,
   diagnostic logging in `acceptIncoming` from commit `4bdca06`)
   is all in place and ready for when the partner side works
   end-to-end. `cmdBootstrapAndInitiateVerify` is currently
   **not** in partner.mjs — re-add the function (see git history
   for commit `ebdffe0`'s additions) when investigating.

   Also: an earlier theory that defining
   `cmdBootstrapAndInitiateVerify` in partner.mjs broke the
   verify scenario via a matrix-js-sdk module-load side effect
   was disproven (verify scenario passes either way; the flake
   is just the documented matrix-js-sdk RustCrypto race).

5. **UI test (`verify-mac-ui-against-partner.sh`) — now passing
   end-to-end automated** (commit `b660f6a`). Two unblocks
   landed:
   - **`sudo DevToolsSecurity -enable`** (one-time per Mac
     account) turns off the TouchID prompt that XCUITest
     runner-init triggers. Without it the runner-init fails with
     "Authentication cancelled. System authentication is
     running." from non-interactive Bash. Required setup; not
     something that can be done from CI without a human present
     for the sudo prompt the first time.
   - **ServerURLValidator localhost carve-out**: plain `http://`
     is now allowed for `localhost` / `127.0.0.1` / `::1` only.
     The Docker test homeserver runs on `http://localhost:6167`;
     before this fix the UI test's submit triggered "That
     doesn't look like a valid server URL." The carve-out
     mirrors Element Web; production homeservers always run
     behind HTTPS so it can't expose remote credentials.

   The full chain now runs from XCUITest: sign-in form-fill →
   submit → verify gate → tap "Verify with another device" →
   SAS sheet shows emojis → tap "They match" → verified. Subject
   to the same matrix-js-sdk RustCrypto flake as the SDK verify
   scenario (~1-in-3) — `run-all-sdk.sh` wraps the UI scenario
   with the same 3-attempt retry.

6. **`verify-sdk-against-partner.sh` is intermittently flaky.**
   Roughly 1-in-3 runs fails with matron's SAS stream timing out
   at 60s — partner.mjs's matrix-js-sdk RustCrypto layer logs
   `"Ignoring just-received verification request which did not
   start a rust-side verification"` and silently drops matron's
   `.request`. The other two SDK scenarios (chat-list, recovery-key)
   don't hit this because they don't initiate verification. Likely
   a matrix-js-sdk timing race in its incoming-request tracker.
   Workaround: re-run the scenario; the next fresh partner instance
   usually accepts the request fine. Worth investigating if the
   flake affects CI signal once that's wired up.

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
│   ├── verify-mac-ui-against-partner.sh       ← XCUITest scenario ✓
│   ├── matron-vs-matron-ui.sh                 ← Mac+iOS XCUITest, no partner.mjs ✓ (session 5 close-out — see Session 5 block above)
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

**Session 6 added "Open work for session 7" inside its own block (top
of this file).** That's the canonical ranked next-steps list.
Highest-priority items: XCUITest coverage for the chat-list chooser
recovery-key path + reverse-direction matron-vs-matron + Help-menu
already-verified guard. Mid-priority: a new `recovery-key-ui.sh`
scenario script. Lower-priority: investigation of the iOS rust-
verification-machine `.ready`-drop bug (workaround landed in
`57e7c4c` but worth an upstream report).

Below is the residual list of items from earlier sessions that
remain open — read alongside the session-6 list.

### A. iOS sim — drive the user-tap paths post-fix

The harness exercises iOS-as-requester end-to-end (matron-vs-matron-ui
✓), but the manual user-tap paths (Help menu, Settings → Encryption,
per-bot banner) haven't been driven by hand post-session-5. Quick
local validation:

```bash
xcodebuild -scheme Matron -configuration Debug \
    -destination 'platform=iOS Simulator,id=337C3A3A-4191-4A51-9513-93F5805276EC' \
    build CODE_SIGNING_ALLOWED=NO
xcrun simctl uninstall 337C3A3A-4191-4A51-9513-93F5805276EC chat.matron.app
xcrun simctl install 337C3A3A-4191-4A51-9513-93F5805276EC \
    "$HOME/Library/Developer/Xcode/DerivedData/Matron-bxmhcklltdsxiccbqjrvsvbdiubi/Build/Products/Debug-iphonesimulator/Matron.app"
xcrun simctl launch 337C3A3A-4191-4A51-9513-93F5805276EC chat.matron.app
```

Sign in as `matron` / `matron-test-pw`. Try recovery-key + verify-
with-other-device flows. Walk through Settings → Encryption +
per-bot banner.

### B. Investigate the responder SDK test stall

`testAcceptIncomingVerificationRequestFromPartner` is gated behind
`MATRON_RUN_INCOMING_VERIFY_TEST=1`. With session 5's
`acknowledgeVerificationRequest` fix the matron-side wiring is now
correct — the remaining blocker is the matrix-js-sdk
same-user-verification lookup bug (see Session 5 block's "Test
infra status" section). Phase 5 (per-bot trust UX) will exercise
the same `acceptIncoming` path so coverage matters before then.

### C. Decide on PR #3 disposition

PR #3 has accumulated 7 fix-up waves + 5 session-5 commits + the
Mac entitlements fix on top of the Phase 3 base. Self-contained
commits but substantial. Options:
- **Merge as-is** once real-homeserver validation passes. Phase 3
  ships, remaining open items become Phase 4 work.
- **Split into stacked PRs** for cleaner review history.

User's stated preference earlier was to merge stacked when possible
but accepted squash for PR #1 (Phase 2). Merge-as-is is the
pragmatic call.

### D. Long-running: build a CI hook for the harness

Wire the green scenarios (`matron-vs-matron-ui.sh`, `chat-list-sdk.sh`,
`recovery-key-sdk.sh`) into a GitHub Actions workflow. Needs either a
self-hosted Mac runner (the harness builds the app) or a GitHub-
hosted macOS runner with Docker (which costs $$).

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
