#!/usr/bin/env bash
# Scenario: drive the verify-with-other-device SAS flow through the
# `MatronIntegrationTests/VerificationFlowIntegrationTests` xctest target.
# Hits `VerificationServiceLive.startSAS` directly — no SwiftUI, no
# AppleScript, no XCUITest form-fill — and asserts the
# `AsyncStream<SasFlowState>` reaches `.verified`. The partner is the
# matron-second-device bootstrapped by run-harness.sh.
#
# This is the canonical headless scenario. The AppleScript-driven
# verify-mac-against-partner.sh stays around as a UI smoke check.
#
# Driven by run-harness.sh which exports HOMESERVER, MATRON_USER,
# MATRON_PW, PARTNER_STORE, PARTNER_CLI, ARTIFACTS_DIR, ROOT.
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require MATRON_USER
require MATRON_PW
require PARTNER_STORE
require ARTIFACTS_DIR
require ROOT

XCRESULT="$ARTIFACTS_DIR/verify-sdk.xcresult"
BUILD_LOG="$ARTIFACTS_DIR/verify-sdk-build.log"
TEST_LOG="$ARTIFACTS_DIR/verify-sdk-test.log"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# Build the test bundle once (avoids the slow path of building inside `test`).
log "Building MatronIntegrationTests for testing…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronIntegrationTests \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$BUILD_LOG" 2>&1) \
    || { echo "build-for-testing failed; see $BUILD_LOG"; tail -50 "$BUILD_LOG"; exit 1; }

log "Running VerificationFlowIntegrationTests…"
# Capture matron's os.Logger output alongside the test so partner-vs-matron
# trace correlation is possible. `log stream` starts emitting when sub_log
# is launched; we backstop by also dumping `log show --start` after the test
# completes in case the stream missed early lines.
MATRON_LOG="$ARTIFACTS_DIR/matron-sdk.log"
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
TEST_RUNNER_MATRON_PARTNER_STORE="$PARTNER_STORE" \
TEST_RUNNER_MATRON_PARTNER_NODE_SCRIPT="$ROOT/tests/integration/partner/partner.mjs" \
TEST_RUNNER_MATRON_NODE_BIN="$(command -v node)" \
xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronIntegrationTests/VerificationFlowIntegrationTests \
    -resultBundlePath "$XCRESULT" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$TEST_LOG" 2>&1
RC=$?
set -e

[ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true

if [ $RC -eq 0 ]; then
    log "✓ Scenario PASSED"
    exit 0
fi

log "✗ Scenario FAILED (rc=$RC)"
log "  Test log: $TEST_LOG"
log "  Matron os.Logger trace: $MATRON_LOG"
log "  Partner stdout (live tail): /tmp/matron-partner-stdout.log"
log "  Result bundle: $XCRESULT"
echo "--- matron os.Logger (verification-* categories) ---"
grep -E "verification-(live|delegate)|sync-live" "$MATRON_LOG" 2>/dev/null | tail -60 || tail -60 "$MATRON_LOG"
echo "--- last 40 lines of test log ---"
tail -40 "$TEST_LOG"
exit $RC
