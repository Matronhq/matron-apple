#!/usr/bin/env bash
# Runs iOS tests on an iPhone 17 simulator and fails loudly.
#   scripts/ios-test.sh MatronTests/TimelineScrollModelTests [MatronTests/Other ...]
# Env:
#   MATRON_SKIP_SNAPSHOT_TESTS (default 1) — 0 to compare snapshots.
#   MATRON_RECORD_SNAPSHOTS    (default 0) — 1 to (re)record baselines.
#   IOS_TEST_DESTINATION       (default 'platform=iOS Simulator,name=iPhone 17').
# Any TEST_RUNNER_* variable already in the environment reaches the runner.
set -euo pipefail
cd "$(dirname "$0")/.."
SKIP="${MATRON_SKIP_SNAPSHOT_TESTS:-1}"
RECORD="${MATRON_RECORD_SNAPSHOTS:-0}"
DEST="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
args=()
for t in "$@"; do args+=("-only-testing:$t"); done
log=$(mktemp /tmp/ios-test.XXXXXX)
set +e
env MATRON_SKIP_SNAPSHOT_TESTS="$SKIP" \
    TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS="$SKIP" \
    TEST_RUNNER_MATRON_RECORD_SNAPSHOTS="$RECORD" \
  xcodebuild test -project Matron.xcodeproj -scheme Matron \
    -destination "$DEST" CODE_SIGNING_ALLOWED=NO ${args[@]+"${args[@]}"} > "$log" 2>&1
status=$?
set -e
grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$log" | tail -1 || true
grep -E "error:|: error|failed \(" "$log" | head -40 || true
echo "log: $log"
exit $status
