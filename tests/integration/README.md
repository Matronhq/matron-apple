# Matron integration test harness

Drives both Matron apps through real flows against a local matron-server
homeserver, with a scriptable Matrix partner that auto-responds to
verification + recovery requests.

## What's here

- `docker/docker-compose.yml` — boots `ghcr.io/matronhq/matron-server:latest`
  (Tuwunel fork) on `127.0.0.1:6167` with registration enabled and a
  fixed registration token (`matron-test-only`). Federation off, encryption
  on, ephemeral volume.
- `partner/partner.py` — Python `matrix-nio` partner client. Sub-commands:
  - `register` — create a fresh user via the registration-token auth flow
  - `login` — sign in + persist session/crypto state to a store directory
  - `setup-recovery` — wait for a sync + report the partner's identity keys
  - `auto-verify` — listen for an incoming SAS request and auto-confirm it
  - `create-dm` / `send-message` — plumb a room so Matron's chat list has
    something to render
- `scenarios/verify-mac-against-partner.sh` — first scripted scenario:
  wipes Mac state, builds + launches the Mac app, drives sign-in via
  AppleScript, taps "Verify with another device", has the partner
  auto-verify, asserts the Mac `os.Logger` trace contains the expected
  SAS lifecycle.
- `run-harness.sh` — orchestrator: brings the homeserver up, sets up the
  Python venv (via `uv`), registers two users, brings the partner online,
  and either hands off to a named scenario or stays up for ad-hoc work.
- `artifacts/<timestamp>/` — created on each run; collects logs,
  partner JSONL output, harness log.

## Prerequisites (one-time)

```bash
brew install uv docker
# Open Docker Desktop or `colima start`
```

## Running

```bash
# Boot homeserver + register users + leave it up (for manual testing)
tests/integration/run-harness.sh

# Or run a specific scripted scenario end-to-end
tests/integration/run-harness.sh verify-mac-against-partner.sh
```

The harness tears down the homeserver volume on exit, so each run starts
from a clean slate.

## Adding a scenario

1. Create `scenarios/your-scenario.sh`, `chmod +x` it.
2. Use the env vars exported by the runner: `MATRON_HOMESERVER`,
   `MATRON_USER`, `MATRON_PW`, `PARTNER_USER`, `PARTNER_PW`,
   `PARTNER_CLI`, `PARTNER_STORE`, `ARTIFACTS_DIR`, `ROOT`.
3. Use AppleScript / `osascript` to drive Mac UI today; XCUITest will
   replace this once the targets are wired (Phase 3.5 follow-up).
4. Use the partner sub-commands for the "other side" of any flow.
5. Assert against the captured `os.Logger` trace.

## Known limitations (v1)

- AppleScript UI driving is brittle; **needs accessibility identifiers**
  on Matron's verify/sign-in views and an XCUITest target for robust
  interaction. Tracked as Phase 3.5 follow-up.
- Partner setup only verifies identity-key presence; full cross-signing
  bootstrap requires either a separate priming step (Element Web)
  or a richer matrix-nio version with cross-signing API exposed.
- iOS sim driving not yet wired (same XCUITest gap).
- No CI integration yet — harness assumes Docker Desktop is running.

## Why a separate test homeserver

Running against `matrix-dev2.yearbooks.be` (the dev server) leaks state
across runs and ties tests to the dev server's availability. The
ephemeral docker-compose homeserver gives each run a fresh DB, isolated
account namespace, and offline-capable execution.
