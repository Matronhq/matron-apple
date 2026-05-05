# Matron integration test harness

Drives both Matron apps through real flows against a local matron-server
homeserver, with a scriptable Matrix partner that auto-responds to
verification + recovery requests.

## What's here

- `docker/docker-compose.yml` — boots `ghcr.io/matronhq/matron-server:latest`
  (Tuwunel fork) on `127.0.0.1:6167` with registration enabled and a
  fixed registration token (`matron-test-only`). Federation off, encryption
  on, ephemeral volume.
- `partner/partner.mjs` — Node `matrix-js-sdk` + `matrix-sdk-crypto-wasm`
  partner client. Mirrors `claude-matrix-bridge/add-bot.mjs`'s patterns —
  same SDK, full cross-signing bootstrap. Runs as a **second device of
  @matron** (not a separate Matrix user), because the in-app
  "Verify with another device" button calls `requestDeviceVerification()`
  — a same-user-different-device to-device flow. A different user
  wouldn't see the request. Sub-commands:
  - `register` — create a fresh user via the registration-token flow
  - `bootstrap-anchor` — login + bootstrap SSSS + cross-signing, persists
    creds + recovery key to a store file. Used by scenarios that need a
    pre-bootstrapped trust anchor independent of the test process.
  - `bootstrap-and-wait` — combined bootstrap + listen for incoming SAS
    in ONE long-running process (mirrors add-bot.mjs's working pattern).
    Optionally creates a test room first (`--create-room <name>`).
    Auto-cross-signs the verifying device on Done. **Used by all SDK
    scenarios** — the split bootstrap-anchor → wait-verify shape leaks
    in-memory crypto state and trips MAC interop.
  - `wait-verify` — older standalone listener that resumes a previously
    bootstrapped session. Kept for the AppleScript scenario.
  - `send-message` — send a test message into a room (decryption check)
  - `create-dm` — create an encrypted DM with a target user

### SDK-level scenarios (canonical, headless)

- `scenarios/verify-sdk-against-partner.sh` — drives `startSAS` directly
  through `VerificationServiceLive` and asserts the
  `AsyncStream<SasFlowState>` reaches `.verified` AND
  `isThisDeviceVerified()` flips true.
- `scenarios/chat-list-sdk.sh` — partner creates an encrypted room
  before matron-app signs in; asserts `chatSummaries()` yields a
  non-empty snapshot. Targets the "empty chat list after fresh
  sign-in (Mac)" regression — currently passes (so the bug is in the
  UI binding above ChatService, not the SDK).
- `scenarios/recovery-key-sdk.sh` — recovery-key restore path; asserts
  `isThisDeviceVerified()` flips true after `recoverAndFixBackup`.
  Re-validates the Wave 7 fix.
- `scenarios/run-all-sdk.sh` — convenience wrapper, runs all three
  scenarios sequentially against fresh harnesses.

### UI scenarios (require interactive Terminal — auth prompt)

- `scenarios/verify-mac-ui-against-partner.sh` — XCUITest scenario
  that drives the Mac sign-in form + verify gate. Reaches the same
  SDK code path as the SDK scenario; requires being run from an
  interactive Terminal session (TouchID / "allow control" prompts
  block the test runner from non-interactive Bash).
- `scenarios/verify-mac-against-partner.sh` — older AppleScript
  scenario, brittle, useful as a smoke check only.

### Other

- `run-harness.sh` — orchestrator: brings the homeserver up, registers
  matron, runs `bootstrap-anchor` (auto-skipped for inline-bootstrap
  scenarios), then hands off to a named scenario or stays up for
  ad-hoc work.
- `artifacts/<timestamp>/` — created on each run; collects matron
  os.Logger trace, partner JSONL output, build log, test log,
  xcresult bundle, harness log.

## Prerequisites (one-time)

```bash
brew install node docker     # node ≥20
# Open Docker Desktop or `colima start`
```

## Running

```bash
# Boot homeserver + register matron + leave it up (for manual testing)
tests/integration/run-harness.sh

# Run any scripted scenario end-to-end
tests/integration/run-harness.sh verify-sdk-against-partner.sh
tests/integration/run-harness.sh chat-list-sdk.sh
tests/integration/run-harness.sh recovery-key-sdk.sh

# Run all SDK scenarios in sequence (each gets its own fresh harness)
tests/integration/scenarios/run-all-sdk.sh
```

The harness tears down the homeserver volume on exit, so each run starts
from a clean slate.

## Adding a scenario

1. Create `scenarios/your-scenario.sh`, `chmod +x` it.
2. Use the env vars exported by the runner: `HOMESERVER`,
   `MATRON_USER`, `MATRON_PW`, `PARTNER_DEVICE_NAME`,
   `PARTNER_CLI`, `PARTNER_STORE`, `ARTIFACTS_DIR`, `ROOT`.
3. Use AppleScript / `osascript` to drive Mac UI today; XCUITest will
   replace this once the targets are wired (Phase 3.5 follow-up).
4. Use the partner sub-commands for the "other side" of any flow.
5. Assert against the captured `os.Logger` trace.

## Known limitations

- **UI scenarios need an interactive Terminal**. Running the XCUITest
  scenario via Bash from a CLI session (e.g. Claude Code) blocks
  on macOS biometric / Accessibility prompts that prevent the test
  runner from initialising. From `Terminal.app` you can dismiss
  these and the scenario proceeds.
- iOS sim driving not yet wired.
- No CI integration yet — harness assumes Docker Desktop / colima is
  running locally.

## Per-test isolation

Each SDK scenario runs against its own fresh Docker homeserver
because each test's inline bootstrap pollutes server-side
cross-signing state for the next. `run-harness.sh` tears down the
homeserver volume on exit. Don't try to run two SDK tests against
the same xcodebuild invocation — they share the homeserver and
the second one's bootstrap will fail (or worse, race silently).
The `run-all-sdk.sh` wrapper handles this by re-invoking
`run-harness.sh` per scenario.

## Why a separate test homeserver

Running against `matrix.example.com` (the dev server) leaks state
across runs and ties tests to the dev server's availability. The
ephemeral docker-compose homeserver gives each run a fresh DB, isolated
account namespace, and offline-capable execution.
