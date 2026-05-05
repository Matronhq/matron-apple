#!/usr/bin/env bash
# Phase 2.5 Task 5 Step 5 — drives the long-lived chat-list subscription
# end-to-end against tuwunel + a partner-device room creation. matron-app
# subscribes to `chatSummaries()` first, partner.mjs (running as a SECOND
# DEVICE of the same @matron user) creates a fresh room SECOND, the test
# asserts the new room surfaces in matron's existing stream within 10s.
#
# This is the canonical proof that Phase 2.5's `RoomListSubscription` +
# fan-out broadcaster delivers diffs without sign-out / refresh.
#
# Driven by run-harness.sh (or run-all-ui.mjs) which exports HOMESERVER,
# MATRON_USER, MATRON_PW, ARTIFACTS_DIR, ROOT.
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require MATRON_USER
require MATRON_PW
require ARTIFACTS_DIR
require ROOT

XCRESULT="$ARTIFACTS_DIR/chat-list-live-updates-sdk.xcresult"
BUILD_LOG="$ARTIFACTS_DIR/chat-list-live-updates-sdk-build.log"
TEST_LOG="$ARTIFACTS_DIR/chat-list-live-updates-sdk-test.log"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# Build the test bundle once (avoids the slow path of building inside `test`).
log "Building MatronIntegrationTests for testing…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronIntegrationTests/ChatListLiveUpdatesTests \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_ENTITLEMENTS="$ROOT/MatronMac/App/MatronMac.Debug.AdHoc.entitlements" \
    > "$BUILD_LOG" 2>&1) \
    || { echo "build-for-testing failed; see $BUILD_LOG"; tail -50 "$BUILD_LOG"; exit 1; }

log "Running ChatListLiveUpdatesTests…"
# Capture matron's os.Logger output alongside the test so partner-vs-matron
# trace correlation is possible. `log stream` starts emitting when sub_log
# is launched; we backstop by also dumping `log show --start` after the test
# completes in case the stream missed early lines.
MATRON_LOG="$ARTIFACTS_DIR/matron-chat-live.log"
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info > "$MATRON_LOG" 2>&1 &
LOG_PID=$!
trap '[ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true' EXIT

# Env vars passed directly on xcodebuild's invocation don't reach the test
# bundle's `ProcessInfo.environment` — Xcode's test runner sandbox filters
# them out. The documented escape hatch is the `TEST_RUNNER_` prefix:
# Xcode strips the prefix and exports the rest into the runner process.
set +e
TEST_RUNNER_MATRON_HOMESERVER="$HOMESERVER" \
TEST_RUNNER_MATRON_USER="$MATRON_USER" \
TEST_RUNNER_MATRON_PW="$MATRON_PW" \
TEST_RUNNER_MATRON_PARTNER_NODE_SCRIPT="$ROOT/tests/integration/partner/partner.mjs" \
TEST_RUNNER_MATRON_NODE_BIN="$(command -v node)" \
xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronIntegrationTests/ChatListLiveUpdatesTests/testChatList_receivesNewRoomFromOtherDevice_within10s \
    -resultBundlePath "$XCRESULT" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_ENTITLEMENTS="$ROOT/MatronMac/App/MatronMac.Debug.AdHoc.entitlements" \
    > "$TEST_LOG" 2>&1
RC=$?
set -e

[ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true

if [ $RC -eq 0 ]; then
    log "✓ Scenario PASSED — live chat-list subscription delivers new room within 10s"
    exit 0
fi

log "✗ Scenario FAILED (rc=$RC)"
log "  Test log: $TEST_LOG"
log "  Matron os.Logger trace: $MATRON_LOG"
log "  Partner stdout (live tail): /tmp/matron-partner-stdout.log"
log "  Result bundle: $XCRESULT"
echo "--- matron os.Logger (chat-service / room-list-subscription) ---"
grep -E "chat-service|room-list-subscription|chat-summary-broadcast" "$MATRON_LOG" 2>/dev/null | tail -60 || tail -60 "$MATRON_LOG"
echo "--- last 40 lines of test log ---"
tail -40 "$TEST_LOG"
exit $RC
