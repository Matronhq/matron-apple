#!/usr/bin/env bash
# Matron integration test harness orchestrator.
#
# Brings up a fresh matron-server (tuwunel) in Docker, registers two users
# (matron-test + partner-test), drives the partner client (matrix-js-sdk via
# Node) to bootstrap cross-signing + a recovery key — making it a real trust
# anchor for Matron to verify against — then either hands off to a scenario
# script or stays up for ad-hoc work.
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
command -v node >/dev/null   || { echo "node not found (>=20)"; exit 1; }
command -v npm  >/dev/null   || { echo "npm not found"; exit 1; }

# --- Boot homeserver ---
log "Bringing up matron-server (tuwunel)…"
(cd "$DOCKER_DIR" && docker compose down -v >/dev/null 2>&1 || true)
(cd "$DOCKER_DIR" && docker compose up -d --pull always)
trap '(cd "$DOCKER_DIR" && docker compose down -v >/dev/null 2>&1 || true)' EXIT

log "Waiting for homeserver /_matrix/client/versions…"
for i in {1..60}; do
    if curl -fs "$HOMESERVER/_matrix/client/versions" >/dev/null 2>&1; then
        log "Homeserver up."
        break
    fi
    sleep 1
    if [ "$i" = "60" ]; then echo "Homeserver never came up"; exit 1; fi
done

# --- Install partner deps ---
if [ ! -d "$PARTNER_DIR/node_modules" ]; then
    log "Installing partner Node deps (npm install)…"
    (cd "$PARTNER_DIR" && npm install --silent)
fi
PARTNER_CLI="node $PARTNER_DIR/partner.mjs"
PARTNER_STORE="$ARTIFACTS_DIR/partner-store.json"

# --- Register users ---
log "Registering @${MATRON_USER}:localhost (Matron user)…"
$PARTNER_CLI register \
    --homeserver "$HOMESERVER" \
    --user "$MATRON_USER" \
    --password "$MATRON_PW" \
    --token "$REG_TOKEN" \
    | tee "$ARTIFACTS_DIR/register-matron.json"

log "Registering @${PARTNER_USER}:localhost (partner trust anchor)…"
$PARTNER_CLI register \
    --homeserver "$HOMESERVER" \
    --user "$PARTNER_USER" \
    --password "$PARTNER_PW" \
    --token "$REG_TOKEN" \
    | tee "$ARTIFACTS_DIR/register-partner.json"

# --- Bring partner online + bootstrap trust anchor ---
log "Bootstrapping partner trust anchor (SSSS + cross-signing + recovery key)…"
$PARTNER_CLI bootstrap-anchor \
    --homeserver "$HOMESERVER" \
    --user "$PARTNER_USER" \
    --password "$PARTNER_PW" \
    --store-file "$PARTNER_STORE" \
    | tee "$ARTIFACTS_DIR/bootstrap-partner.json"

# --- Export env for scenarios ---
export HOMESERVER="$HOMESERVER"
export MATRON_USER MATRON_PW PARTNER_USER PARTNER_PW
export PARTNER_CLI PARTNER_STORE
export ARTIFACTS_DIR ROOT

SCENARIO="${1:-}"
if [ -n "$SCENARIO" ]; then
    SCENARIO_PATH="$INT_DIR/scenarios/$SCENARIO"
    [ -f "$SCENARIO_PATH" ] || { echo "scenario not found: $SCENARIO_PATH"; exit 1; }
    log "Running scenario: $SCENARIO"
    bash "$SCENARIO_PATH"
    rc=$?
    log "Scenario exit code: $rc"
    exit $rc
else
    log "No scenario specified — leaving harness up."
    log "Homeserver: $HOMESERVER"
    log "Partner store: $PARTNER_STORE (recovery_key inside)"
    log "Artifacts: $ARTIFACTS_DIR"
    log "Press ctrl-C to tear down."
    sleep infinity
fi
