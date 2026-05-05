#!/usr/bin/env bash
# Scenario: drive the Mac UI through XCUITest exercising the recovery-key
# restore path via the post-login verification gate (handover Priority A
# test #1).
#
# Self-contained on Mac — no iOS sim, no partner.mjs trust anchor. The
# in-app generate flow bootstraps cross-signing for @matron itself; the
# post-sign-out + sign-in restore flow then pulls those keys back from
# server-side secret storage. Auto-skipped from `bootstrap-anchor` in
# `run-harness.sh` so the partner client doesn't pre-upload a master
# key that would conflict with the in-app bootstrap.
#
# Flow asserted end-to-end by `RecoveryKeyRestoreUITests`:
#   1. Sign in (fresh user)
#   2. Generate recovery key
#   3. File → Sign Out
#   4. Sign back in
#   5. Verify gate offers "Use recovery key"
#   6. Restore → sheet dismisses (proxy for `.verified`)
#
# Driven by run-harness.sh which exports HOMESERVER, MATRON_USER,
# MATRON_PW, ARTIFACTS_DIR, ROOT.
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require MATRON_USER
require MATRON_PW
require ARTIFACTS_DIR
require ROOT

XCRESULT="$ARTIFACTS_DIR/recovery-key-restore-ui.xcresult"
BUILD_LOG="$ARTIFACTS_DIR/recovery-key-restore-ui-build.log"
TEST_LOG="$ARTIFACTS_DIR/recovery-key-restore-ui-test.log"
MATRON_LOG="$ARTIFACTS_DIR/matron-mac-recovery-key-restore.log"
CONFIG_FILE="/tmp/matron-test-config.json"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# Wipe any prior Mac-app state so the test exercises the first-launch
# path. Same belt+braces as `matron-vs-matron-ui.sh` — `defaults delete`
# alone is unreliable because cfprefsd caches the in-memory domain, so
# we nuke the plist file and restart cfprefsd too.
log "Wiping Mac app state…"
pkill -x MatronMac >/dev/null 2>&1 || true
sleep 1
rm -rf "$HOME/Library/Application Support/chat.matron.mac"
rm -f "$HOME/Library/Preferences/chat.matron.mac.plist"
defaults delete chat.matron.mac >/dev/null 2>&1 || true
killall cfprefsd 2>/dev/null || true
rm -rf "$HOME/Library/Caches/matron-sdk-trace" 2>/dev/null || true

# Build host app + UI test bundle.
log "Building MatronMac + RecoveryKeyRestoreUITests for testing…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/RecoveryKeyRestoreUITests \
    -allowProvisioningUpdates \
    > "$BUILD_LOG" 2>&1) \
    || { echo "build-for-testing failed; see $BUILD_LOG"; tail -50 "$BUILD_LOG"; exit 1; }

log "Writing ${CONFIG_FILE}…"
cat > "$CONFIG_FILE" <<EOF
{
  "homeserver": "$HOMESERVER",
  "user": "$MATRON_USER",
  "password": "$MATRON_PW",
  "verify_timeout": 60
}
EOF

cleanup() {
    [ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true
    pkill -x MatronMac 2>/dev/null || true
    rm -f "$CONFIG_FILE"
}
trap cleanup EXIT INT TERM

# Capture matron's os.Logger output for post-mortem.
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info \
    > "$MATRON_LOG" 2>&1 &
LOG_PID=$!
sleep 1

log "Running RecoveryKeyRestoreUITests…"
set +e
(cd "$ROOT" && xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/RecoveryKeyRestoreUITests \
    -resultBundlePath "$XCRESULT" \
    -allowProvisioningUpdates \
    > "$TEST_LOG" 2>&1)
RC=$?
set -e

if [ $RC -eq 0 ]; then
    log "✓ Scenario PASSED"
    exit 0
fi

log "✗ Scenario FAILED (rc=$RC)"
log "  Test log: $TEST_LOG"
log "  Matron os.Logger trace: $MATRON_LOG"
log "  Result bundle: $XCRESULT"
log "  Diagnostics (if produced by test): /Users/Shared/rkr-mac-debug.txt"
echo "--- last 60 lines of test log ---"
tail -60 "$TEST_LOG"
echo "--- last 30 lines of os.Logger trace ---"
tail -30 "$MATRON_LOG" 2>/dev/null || true
exit $RC
