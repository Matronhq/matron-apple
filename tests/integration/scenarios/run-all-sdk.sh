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

SCENARIOS=(
    "verify-sdk-against-partner.sh"
    "chat-list-sdk.sh"
    "recovery-key-sdk.sh"
)

declare -a results
overall_rc=0

for scenario in "${SCENARIOS[@]}"; do
    echo
    echo "============================================================"
    echo "  ▶ Scenario: $scenario"
    echo "============================================================"
    if "$HARNESS" "$scenario"; then
        results+=("✓ $scenario")
    else
        rc=$?
        results+=("✗ $scenario (rc=$rc)")
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
