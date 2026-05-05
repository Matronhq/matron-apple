# matron-vs-matron UI test — design

**Status:** approved 2026-05-04, ready for implementation plan.
**Owner:** phase-3-e2ee-verification branch.
**Related:** `docs/superpowers/specs/2026-05-02-matron-ios-design.md` (overall app design),
`docs/HANDOVER.md` open risk #1 (matron-vs-matron unvalidated post-Wave-7 revert),
existing scenario `tests/integration/scenarios/verify-mac-ui-against-partner.sh`.

## Why

Phase 3's verification UX has two same-SDK risks the existing test surface doesn't cover:

1. **Wave 7 bug #6 was reverted in `59b3180`** — both requester and responder now call
   `startSasVerification()`. Required for SAS to advance against matrix-js-sdk peers,
   but the matrix-rust-sdk ↔ matrix-rust-sdk path (matron-vs-matron) hasn't been
   re-validated since.
2. **The existing UI scenario pairs Mac with `partner.mjs`** (matrix-js-sdk).
   That validates `matrix-rust-sdk` as requester against a different SDK, not the
   matrix-rust-sdk-vs-matrix-rust-sdk responder path.

A live manual smoke would answer the immediate question but leaves the gap permanent.
An automated scenario answers it once and keeps answering it on every run.

## Goals

- Run unattended from `tests/integration/run-harness.sh matron-vs-matron-ui.sh`.
- Drive **two real matron clients** end-to-end via XCUITest: Mac as trust-anchor responder,
  iOS sim as requester.
- Both reach `verificationStateListener: fired with verified` in the os.Logger trace.
- Survive cold runs (fresh Docker, wiped app state, no Keychain residue).
- Diagnose failures without needing the human to re-run interactively (xcresult + screenshot
  + accessibility tree + os.Logger trace per side).

## Non-goals

- Wiring into `run-all-sdk.sh`. UI runs are slow (~3–5 min wall) and serial-only;
  they belong in a future `run-all-ui.sh`.
- CI integration. Punt to a later step once we know the scenario is stable locally.
- Validating Phase 4+ flows (push/notification, custom event types). Out of scope.
- Exercising the recovery-key restore branch. That's covered by `recovery-key-sdk.sh`
  and isn't part of the matron-vs-matron risk.
- Mac-vs-Mac (two parallel Mac instances). Rejected at the brainstorm stage as artificial
  and harder to set up than Mac+iOS.

## Architecture

```
run-harness.sh                       # boot Docker tuwunel, register @matron, skip partner bootstrap
  └── matron-vs-matron-ui.sh         # new scenario script
        ├── wipe Mac+iOS state
        ├── build MatronMacUITests + MatronUITests in parallel
        ├── write /tmp/matron-test-config.json
        ├── start os.Logger streams (Mac + iOS sim → artifacts)
        ├── FORK Mac xcodebuild test  ─┐
        │     sign in                  │
        │     "Generate new recovery"  │
        │     ack saved + continue     │
        │     write /tmp/matron-mac-ready  ─── synchronization point
        │     waitForExistence("verifybanner.accept", 120s)
        │     accept → SAS sheet → "They match" → wait dismiss
        ├── FORK iOS xcodebuild test ──┤
        │     poll /tmp/matron-mac-ready (XCTSkip after 30s)
        │     sign in                  │
        │     "Verify with another"    │
        │     SAS sheet → "They match" → wait dismiss
        ├── wait both PIDs
        └── assert: both rc=0 AND both os.Logger traces contain
                    "verificationStateListener: fired with verified"
```

**Synchronization points:**
1. `/tmp/matron-mac-ready` — gates iOS sign-in; written by Mac after bootstrap completes.
2. `XCUIElement.waitForExistence` on UI elements — handles SAS-sheet timing without sleeps.
3. Wrapper waits both PIDs — single join point for pass/fail.

**Isolation:**
- Fresh Docker volume each run (run-harness.sh teardown trap).
- Mac state wipe: `pkill -x MatronMac`, `rm -rf ~/Library/Application\ Support/chat.matron.mac`,
  `defaults delete chat.matron.mac`.
- iOS state wipe: `xcrun simctl uninstall <udid> chat.matron.app`.
- Keychain entries: per-user (`matron.recovery-key.@matron:localhost`); the uninstall
  on iOS clears the app's access group, and the Mac state wipe removes the local
  `chat.matron.mac` Keychain partition. Both clean for first-launch.

## Code & UI changes

### A. New iOS UI test target — `MatronUITests`

Add to `project.yml` mirroring `MatronMacUITests` (currently lines 215–225):

- `type: bundle.ui-testing`
- `platform: iOS`
- `deploymentTarget: ios.deploymentTarget` (inherit)
- `sources: - path: MatronUITests`
- `dependencies: - target: Matron`
- `settings.base.CODE_SIGNING_ALLOWED: NO`

Add `- MatronUITests` to the iOS scheme's `testTargets` (project.yml line ~86) so
`xcodebuild test -scheme Matron` exercises it locally and from Xcode.

New directory `MatronUITests/` at repo root with the test class file (see §C).

### B. Accessibility identifiers to plumb

| File | New identifiers | Notes |
|------|-----------------|-------|
| `Matron/Features/Onboarding/SignInView.swift` | `signin.server`, `signin.username`, `signin.password`, `signin.submit` | Plumb in iOS view; mirrors Mac. |
| `Matron/Features/Onboarding/PostLoginVerificationView.swift` | `verifygate.verifyWithOtherDevice`, `verifygate.useRecoveryKey`, `verifygate.generateNew` | Mirrors Mac post-login gate. |
| `Matron/Features/Verification/SasView.swift` | `sas.match`, `sas.dontMatch` | Mirrors `MacSasView`. |
| `MatronMac/Features/Verification/MacVerificationBanner.swift` | `verifybanner.accept` (existing "Verify" button at line 40) | Required for Mac responder leg. |
| `MatronMac/Features/Verification/MacRecoveryKeyView.swift` | `recoverykey.acknowledgeSaved` (toggle line 67), `recoverykey.continue` (button line 158) | Required for Mac trust-anchor leg. |

If the SAS button text or recovery-key save toggle lives in `MatronShared` rather than a
per-platform view, identifiers go on the shared view (verified during implementation).

### C. Two new XCUITest classes

#### `MatronMacUITests/MatronVsMatronMacUITests.swift`

Drives Mac as trust-anchor responder. Reuses `VerifyWithPartnerUITests`'s field-paste +
diagnostics helpers (initial pass: copy-paste; if a third UI test class lands, refactor
into a shared base). Skip if `/tmp/matron-test-config.json` is absent.

```
testTrustAnchorAcceptsIncomingFromIOSPeer():
  signIn(server, user, pw)       // pasteIntoTextField, etc.
  waitForVerifyGate()
  app.buttons["verifygate.generateNew"].click()
  // Recovery-key display screen (MacRecoveryKeyView).
  app.checkBoxes["recoverykey.acknowledgeSaved"].click()  // adjust to actual control type
  app.buttons["recoverykey.continue"].click()
  // Bootstrap done. Signal iOS.
  try "ready".write(toFile: "/tmp/matron-mac-ready", atomically: true, encoding: .utf8)
  // Wait for incoming verification request from iOS peer.
  let accept = app.buttons["verifybanner.accept"]
  XCTAssertTrue(accept.waitForExistence(timeout: 120),
                "incoming verification banner never appeared")
  accept.click()
  // SAS sheet → confirm → wait for dismissal as proxy for .verified.
  let match = app.buttons["sas.match"]
  XCTAssertTrue(match.waitForExistence(timeout: verifyTimeout))
  match.click()
  XCTAssertTrue(match.waitForNonExistence(timeout: 30),
                "SAS sheet did not dismiss after match — likely SAS didn't reach .verified")
```

Keeps the existing setup-time `app.activate()` + File→New Window dance — XCUITest-launched
MatronMac sometimes comes up menu-bar-only. Same `failWithDiagnostics` (screenshot +
accessibility tree → `/tmp/matron-mac-debug.txt`).

#### `MatronUITests/MatronVsMatronIOSUITests.swift`

Drives iOS sim as requester. Skip if `/tmp/matron-test-config.json` is absent.

```
testRequestsVerificationAgainstMacTrustAnchor():
  // Wait for Mac to bootstrap before signing in.
  guard waitForFile("/tmp/matron-mac-ready", timeout: 30) else {
    throw XCTSkip("Mac peer never reached ready signal")
  }
  signIn(server, user, pw)
  waitForVerifyGate()
  app.buttons["verifygate.verifyWithOtherDevice"].tap()
  let match = app.buttons["sas.match"]
  XCTAssertTrue(match.waitForExistence(timeout: verifyTimeout))
  match.tap()
  XCTAssertTrue(match.waitForNonExistence(timeout: 30))
```

Initial copy of the field-paste/diagnostic helpers from the Mac suite, adapted to iOS
(`AppKit`/`NSPasteboard` → `UIKit`/`UIPasteboard`; `.click()` → `.tap()`). Diagnostics
to `/tmp/matron-ios-debug.txt`.

### D. New scenario script — `tests/integration/scenarios/matron-vs-matron-ui.sh`

Modelled on `verify-mac-ui-against-partner.sh`. Differences: no partner.mjs,
two parallel `xcodebuild test` invocations, two os.Logger streams, additional
trace-content assertion at the end. Skeleton owns:

- env-var `require` checks
- state wipes (Mac + iOS)
- parallel `build-for-testing`
- config file write
- two os.Logger streams (Mac via `/usr/bin/log stream`; iOS sim via `xcrun simctl spawn ... log stream`)
- two parallel `test-without-building` runs in background, both with their own
  `-resultBundlePath` and stdout log
- `wait $MAC_TEST_PID; MAC_RC=$?` then `wait $IOS_TEST_PID; IOS_RC=$?`
- trace-content assertions: both runtime logs contain
  `verificationStateListener: fired with verified`
- failure path: tail last 60 lines of each test log + dump field readbacks

`trap` on EXIT: kill log-stream PIDs, terminate MatronMac, remove `/tmp/matron-test-config.json`,
remove `/tmp/matron-mac-ready`.

### E. `run-harness.sh` change

Add `matron-vs-matron-ui.sh` to the auto-skip pattern (line ~85) that drops
the bootstrap-anchor step for inline-bootstrap scenarios. The harness still
boots Docker + registers `@matron`; the scenario manages all post-bootstrap state.

## Assertions, in priority order

1. Mac `xcodebuild test` exit code = 0 (Mac XCUITest's own assertions all passed).
2. iOS `xcodebuild test` exit code = 0 (same for iOS).
3. Mac runtime os.Logger contains `verificationStateListener: fired with verified` —
   proves Mac's local crypto store received the cross-signature post-SAS.
4. iOS runtime os.Logger contains the same — proves the iOS device hit verified.

A pass requires all four. Any failure: scenario exits non-zero, dumps diagnostics.

## Failure modes & diagnostics

| Failure | Detection | Diagnostic output |
|---------|-----------|-------------------|
| Mac sign-in form never appears | `waitForExistence` on `signin.server` (15s) | screenshot, accessibility tree → `/tmp/matron-mac-debug.txt` |
| Wrong creds rejected | `verifygate.verifyWithOtherDevice` doesn't appear within 30s | scrape in-form error text via `inFormErrorMessage()` (existing helper) |
| Mac never bootstraps | `/tmp/matron-mac-ready` never appears | iOS test XCTSkips; wrapper sees iOS skipped + Mac failure |
| iOS sign-in form never appears | same as Mac | `/tmp/matron-ios-debug.txt` |
| Incoming-request banner never reaches Mac | `waitForExistence` on `verifybanner.accept` (120s) | screenshot of Mac chat-list state |
| SAS emoji sheet never appears | `waitForExistence` on `sas.match` (60s default) | screenshot + tail os.Logger for SDK delegate trace |
| SAS sheet appears but doesn't dismiss | `waitForNonExistence` on `sas.match` (30s) | screenshot — likely SDK never fired didFinish on one side |
| `xcodebuild test` exit 0 but trace assertion fails | grep on runtime log | tail 60 lines of runtime log per side; common cause: `crossSignDevice` skipped |

## Open risks & flagged unknowns

- **`MacRecoveryKeyView` interaction shape** — current best guess from grep is "toggle ack +
  Continue button". If it's a single-button "Save and continue" the test needs adjusting.
  Verified during implementation (one read of the view body), no design change needed.
- **iOS UI test target type** — `bundle.ui-testing` should "just work" via xcodegen, but
  I haven't validated against this xcodegen version. If it bounces, fall back to mirroring
  the exact `MatronMacUITests` block in project.yml line-for-line (target type, settings, deps).
- **iOS sim Keychain wipe completeness** — `simctl uninstall` clears the app's access group,
  but cross-app access group entries (none in current code) wouldn't be touched. Not a concern
  given we only have one app's access group.
- **`MatronShared` vs per-platform views** — SAS button labels and recovery-key controls
  may live in `MatronShared` rather than `Matron/`/`MatronMac/`. Identifiers go on the
  actual rendering view; small adjustment during implementation.
- **Cross-process identifier collisions** — `/tmp/matron-mac-ready` and `/tmp/matron-test-config.json`
  are the only shared filesystem paths; both are wiped on entry and removed on exit
  via the EXIT trap.

## Out of scope (deferred for future work)

- iOS-as-trust-anchor + Mac-as-requester (mirror direction). Same code paths; one direction
  validates the round-trip. If we later have time, easy to add as a second test method.
- Verifying after a sign-out / re-sign-in cycle. Recovery-key restore handles that;
  separate concern.
- Multiple devices (3+). Out of scope for matron-vs-matron.
- Real homeserver (matrix-dev2.yearbooks.be). Docker harness gives us deterministic state.
