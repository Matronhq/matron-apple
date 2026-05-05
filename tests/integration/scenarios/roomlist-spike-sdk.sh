#!/usr/bin/env bash
# Phase 2.5 spike scenario — does RoomList.entriesWithDynamicAdapters
# work against tuwunel today?
#
# See `MatronIntegrationTests/RoomListSubscriptionSpikeTests.swift` for
# the test method and expected outcomes. This scenario is throwaway —
# delete it once the dynamic-adapters question is empirically answered
# and Phase 2.5 Task 2's RoomListSubscription.swift carries the
# decision inline.
#
# Same harness shape as the other SDK scenarios (auto-skips
# bootstrap-anchor; this test signs in fresh and creates rooms via the
# SDK directly, no partner.mjs needed).
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require MATRON_USER
require MATRON_PW
require ARTIFACTS_DIR
require ROOT

XCRESULT="$ARTIFACTS_DIR/roomlist-spike-sdk.xcresult"
BUILD_LOG="$ARTIFACTS_DIR/roomlist-spike-sdk-build.log"
TEST_LOG="$ARTIFACTS_DIR/roomlist-spike-sdk-test.log"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

log "Building MatronIntegrationTests for testing…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronIntegrationTests/RoomListSubscriptionSpikeTests \
    -allowProvisioningUpdates \
    > "$BUILD_LOG" 2>&1) \
    || { echo "build-for-testing failed; see $BUILD_LOG"; tail -50 "$BUILD_LOG"; exit 1; }

log "Running RoomListSubscriptionSpikeTests…"
MATRON_LOG="$ARTIFACTS_DIR/matron-roomlist-spike.log"
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info > "$MATRON_LOG" 2>&1 &
LOG_PID=$!
trap '[ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true' EXIT

# TEST_RUNNER_ prefix strips and propagates into the runner process —
# xcodebuild's test runner sandbox filters env vars otherwise.
set +e
TEST_RUNNER_MATRON_HOMESERVER="$HOMESERVER" \
TEST_RUNNER_MATRON_USER="$MATRON_USER" \
TEST_RUNNER_MATRON_PW="$MATRON_PW" \
xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronIntegrationTests/RoomListSubscriptionSpikeTests \
    -resultBundlePath "$XCRESULT" \
    -allowProvisioningUpdates \
    > "$TEST_LOG" 2>&1
RC=$?
set -e

[ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true

if [ $RC -eq 0 ]; then
    log "✓ Scenario PASSED — entriesWithDynamicAdapters works against tuwunel"
    log "  Test log: $TEST_LOG  (search for [RoomListSpike] markers for the captured diff stream)"
    exit 0
fi

log "✗ Scenario FAILED (rc=$RC)"
log "  Test log: $TEST_LOG"
log "  Matron os.Logger: $MATRON_LOG"
log "  Result bundle: $XCRESULT"
echo "--- last 60 lines of test log ---"
tail -60 "$TEST_LOG"
exit $RC
