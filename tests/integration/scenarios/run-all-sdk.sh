#!/usr/bin/env bash
# Convenience: run every SDK integration scenario in sequence, each
# against its own fresh harness (Docker homeserver torn down + brought
# back up between scenarios — required for per-test isolation since
# scenarios that bootstrap inline pollute server-side cross-signing
# state for any test that follows in the same homeserver).
#
# Usage:
#   tests/integration/scenarios/run-all-sdk.sh
#
# Each scenario must be invokable as
#   tests/integration/run-harness.sh <scenario>.sh
# from the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HARNESS="$ROOT/tests/integration/run-harness.sh"

# Each scenario maps to "max attempts". The verify scenario flakes
# ~1-in-3 due to a matrix-js-sdk RustCrypto request-tracker race
# ("Ignoring just-received verification request which did not start
# a rust-side verification") — partner's olm machine emits the
# `crypto.verificationRequestReceived` event before it's registered
# the request internally, so the JS-side handler asks the olm
# machine, gets nothing, and drops it. Each retry gets a completely
# fresh Docker harness, so the next partner instance usually
# accepts. Until matrix-js-sdk fixes the race upstream, we retry.
SCENARIOS=(
    "verify-sdk-against-partner.sh:3"
    "chat-list-sdk.sh:1"
    "recovery-key-sdk.sh:1"
)

declare -a results
overall_rc=0

for entry in "${SCENARIOS[@]}"; do
    scenario="${entry%:*}"
    max_attempts="${entry#*:}"
    echo
    echo "============================================================"
    echo "  ▶ Scenario: $scenario (max attempts: $max_attempts)"
    echo "============================================================"
    rc=1
    for attempt in $(seq 1 "$max_attempts"); do
        if [ "$attempt" -gt 1 ]; then
            echo "  ↻ retry $attempt of $max_attempts"
        fi
        if "$HARNESS" "$scenario"; then
            rc=0
            if [ "$attempt" -eq 1 ]; then
                results+=("✓ $scenario")
            else
                results+=("✓ $scenario (passed on retry $attempt)")
            fi
            break
        fi
        rc=$?
    done
    if [ "$rc" -ne 0 ]; then
        results+=("✗ $scenario (rc=$rc, exhausted $max_attempts attempts)")
        overall_rc=1
    fi
done

echo
echo "============================================================"
echo "  Summary"
echo "============================================================"
for r in "${results[@]}"; do
    echo "  $r"
done

exit $overall_rc
