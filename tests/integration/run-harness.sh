#!/usr/bin/env bash
# Matron integration test harness orchestrator.
#
# Brings up a fresh matron-server (tuwunel) in Docker, registers two users
# (matron-test + partner-test), drives the partner client to set up a trust
# anchor, then hands off to whichever scenario script is passed as $1.
#
# Usage:
#   tests/integration/run-harness.sh [scenario]
# Scenarios live under tests/integration/scenarios/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INT_DIR="$ROOT/tests/integration"
DOCKER_DIR="$INT_DIR/docker"
PARTNER_DIR="$INT_DIR/partner"
ARTIFACTS_DIR="$INT_DIR/artifacts/$(date +%Y%m%d-%H%M%S)"
HOMESERVER="http://localhost:6167"
REG_TOKEN="matron-test-only"
MATRON_USER="matron"
MATRON_PW="matron-test-pw"
PARTNER_USER="partner"
PARTNER_PW="partner-test-pw"

mkdir -p "$ARTIFACTS_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# --- Pre-flight ---
command -v docker >/dev/null || { echo "docker not found"; exit 1; }
command -v uv >/dev/null || { echo "uv not found (install: brew install uv)"; exit 1; }

# --- Boot homeserver ---
log "Bringing up matron-server (tuwunel)…"
(cd "$DOCKER_DIR" && docker compose down -v >/dev/null 2>&1 || true)
(cd "$DOCKER_DIR" && docker compose up -d --pull always)
trap '(cd "$DOCKER_DIR" && docker compose down -v >/dev/null 2>&1 || true)' EXIT

log "Waiting for homeserver /_matrix/client/versions to respond…"
for i in {1..60}; do
    if curl -fs "$HOMESERVER/_matrix/client/versions" >/dev/null 2>&1; then
        log "Homeserver is up."
        break
    fi
    sleep 1
    if [ "$i" = "60" ]; then echo "Homeserver never came up"; exit 1; fi
done

# --- Set up Python env for partner ---
log "Setting up partner client (uv venv)…"
PARTNER_VENV="$PARTNER_DIR/.venv"
if [ ! -d "$PARTNER_VENV" ]; then
    (cd "$PARTNER_DIR" && uv venv && uv pip install -r <(uv pip compile --quiet pyproject.toml) || \
        (cd "$PARTNER_DIR" && uv venv && uv pip install -e .))
fi
PARTNER_PY="$PARTNER_VENV/bin/python"
PARTNER_CLI="$PARTNER_PY $PARTNER_DIR/partner.py"

# --- Register users ---
log "Registering Matron test user @${MATRON_USER}:localhost…"
$PARTNER_CLI register \
    --homeserver "$HOMESERVER" \
    --user "$MATRON_USER" \
    --password "$MATRON_PW" \
    --token "$REG_TOKEN" \
    --device-name "matron-via-harness" \
    | tee "$ARTIFACTS_DIR/register-matron.json"

log "Registering partner test user @${PARTNER_USER}:localhost…"
$PARTNER_CLI register \
    --homeserver "$HOMESERVER" \
    --user "$PARTNER_USER" \
    --password "$PARTNER_PW" \
    --token "$REG_TOKEN" \
    --device-name "partner-via-harness" \
    | tee "$ARTIFACTS_DIR/register-partner.json"

# --- Bring partner online + set up trust anchor ---
PARTNER_STORE="$ARTIFACTS_DIR/partner-store"
log "Logging partner in (store: $PARTNER_STORE)…"
$PARTNER_CLI login \
    --homeserver "$HOMESERVER" \
    --user "$PARTNER_USER" \
    --password "$PARTNER_PW" \
    --store "$PARTNER_STORE" \
    --device-name "partner-via-harness" \
    | tee "$ARTIFACTS_DIR/login-partner.json"

log "Setting up partner cross-signing / recovery (trust anchor)…"
$PARTNER_CLI setup-recovery \
    --store "$PARTNER_STORE" \
    | tee "$ARTIFACTS_DIR/setup-recovery-partner.json"

# --- Export env for scenario scripts ---
export MATRON_HOMESERVER="$HOMESERVER"
export MATRON_USER MATRON_PW PARTNER_USER PARTNER_PW
export PARTNER_CLI PARTNER_STORE
export ARTIFACTS_DIR
export ROOT

# --- Hand off to scenario, if any ---
SCENARIO="${1:-}"
if [ -n "$SCENARIO" ]; then
    SCENARIO_PATH="$INT_DIR/scenarios/$SCENARIO"
    [ -f "$SCENARIO_PATH" ] || { echo "scenario not found: $SCENARIO_PATH"; exit 1; }
    log "Running scenario: $SCENARIO"
    bash "$SCENARIO_PATH"
    log "Scenario exit code: $?"
else
    log "No scenario specified — leaving harness up. Inspect at $HOMESERVER"
    log "Artifacts dir: $ARTIFACTS_DIR"
    log "Press ctrl-C to tear down."
    sleep infinity
fi
