#!/usr/bin/env bash
# Scenario: drive the recovery-key restore test. matron-app signs in
# fresh, then uses partner's previously-bootstrapped recovery key to
# unlock cross-signing locally (the "Use recovery key" branch of the
# verify gate, not SAS). Asserts `isThisDeviceVerified()` flips true.
#
# Re-validates the Wave 7 fix that switched the SDK call from
# `recover` to `recoverAndFixBackup`.
#
# Same harness shape as the other SDK scenarios (auto-skips
# bootstrap-anchor; partner runs inline via `bootstrap-and-wait`).
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require MATRON_USER
require MATRON_PW
require ARTIFACTS_DIR
require ROOT

XCRESULT="$ARTIFACTS_DIR/recovery-key-sdk.xcresult"
BUILD_LOG="$ARTIFACTS_DIR/recovery-key-sdk-build.log"
TEST_LOG="$ARTIFACTS_DIR/recovery-key-sdk-test.log"

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

log "Running testRecoveryKeyRestoreVerifiesThisDevice…"
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
TEST_RUNNER_MATRON_PARTNER_NODE_SCRIPT="$ROOT/tests/integration/partner/partner.mjs" \
TEST_RUNNER_MATRON_NODE_BIN="$(command -v node)" \
xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronIntegrationTests/VerificationFlowIntegrationTests/testRecoveryKeyRestoreVerifiesThisDevice \
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
