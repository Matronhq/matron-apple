#!/usr/bin/env bash
# Scenario: drive Mac (trust-anchor responder) + iOS sim (requester)
# end-to-end via XCUITest, both running matron's matrix-rust-sdk
# build, both signed in as @matron against the Docker harness on
# :6167. No partner.mjs.
#
# Synchronization: Mac signs in first, runs the recovery-key
# generate flow, then writes /Users/Shared/matron-mac-ready. iOS polls that
# file before signing in (XCTSkip after 90s). Both reach the SAS
# sheet via XCUIElement.waitForExistence; "They match" on both sides
# completes SAS; auto-cross-signing flips both to verified.
#
# Pass criteria: both `xcodebuild test` exit 0 AND both runtime
# os.Logger streams contain "verificationStateListener: fired with
# verified".
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

SIM_UDID="${MATRON_SIM_UDID:-337C3A3A-4191-4A51-9513-93F5805276EC}"
TRACE_MARKER='verificationStateListener: fired with verified'
CONFIG_FILE="/tmp/matron-test-config.json"
READY_FILE="/Users/Shared/matron-mac-ready"

MAC_BUILD_LOG="$ARTIFACTS_DIR/mac-build.log"
IOS_BUILD_LOG="$ARTIFACTS_DIR/ios-build.log"
MAC_TEST_LOG="$ARTIFACTS_DIR/mac-test.log"
IOS_TEST_LOG="$ARTIFACTS_DIR/ios-test.log"
MAC_RUNTIME_LOG="$ARTIFACTS_DIR/matron-mac.log"
IOS_RUNTIME_LOG="$ARTIFACTS_DIR/matron-ios.log"
MAC_XCRESULT="$ARTIFACTS_DIR/mac.xcresult"
IOS_XCRESULT="$ARTIFACTS_DIR/ios.xcresult"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# --- Wipe stale signals + app state ---
log "Wiping app state (Mac + iOS sim) and stale ready-file…"
rm -f "$READY_FILE"
pkill -x MatronMac >/dev/null 2>&1 || true
sleep 1
rm -rf "$HOME/Library/Application Support/chat.matron.mac"
# `defaults delete` alone is unreliable: cfprefsd caches the in-memory
# domain and subsequent reads return the stale values, so the Mac app
# still sees `matron.verify-done.<userID>=1` from a prior run and
# bypasses the verify gate. Belt + braces: nuke the plist file too,
# then restart cfprefsd to flush the cache.
rm -f "$HOME/Library/Preferences/chat.matron.mac.plist"
defaults delete chat.matron.mac >/dev/null 2>&1 || true
killall cfprefsd 2>/dev/null || true
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
if ! xcrun simctl list devices | grep -q "$SIM_UDID"; then
    log "✗ Simulator $SIM_UDID not found on this machine. Set MATRON_SIM_UDID env var to override."
    exit 1
fi
xcrun simctl terminate "$SIM_UDID" chat.matron.app >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_UDID" chat.matron.app >/dev/null 2>&1 || true

# --- Build both UI test bundles in parallel ---
log "Building MatronMacUITests + MatronUITests for testing (parallel)…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/MatronVsMatronMacUITests \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$MAC_BUILD_LOG" 2>&1) &
MAC_BUILD_PID=$!

(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme Matron \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:MatronUITests/MatronVsMatronIOSUITests \
    CODE_SIGNING_ALLOWED=NO \
    > "$IOS_BUILD_LOG" 2>&1) &
IOS_BUILD_PID=$!

if ! wait $MAC_BUILD_PID; then
    log "✗ Mac build-for-testing failed"
    tail -50 "$MAC_BUILD_LOG"
    exit 1
fi
if ! wait $IOS_BUILD_PID; then
    log "✗ iOS build-for-testing failed"
    tail -50 "$IOS_BUILD_LOG"
    exit 1
fi
log "  builds OK"

# --- Write XCUITest config ---
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
    [ -n "${MAC_LOG_PID:-}" ] && kill "$MAC_LOG_PID" 2>/dev/null || true
    [ -n "${IOS_LOG_PID:-}" ] && kill "$IOS_LOG_PID" 2>/dev/null || true
    [ -n "${WATCHER_PID:-}" ] && kill "$WATCHER_PID" 2>/dev/null || true
    pkill -x MatronMac 2>/dev/null || true
    rm -f "$CONFIG_FILE" "$READY_FILE"
}
trap cleanup EXIT INT TERM

# --- Capture os.Logger streams from both sides ---
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info \
    > "$MAC_RUNTIME_LOG" 2>&1 &
MAC_LOG_PID=$!

xcrun simctl spawn "$SIM_UDID" log stream --predicate 'subsystem == "chat.matron"' --style compact --level info \
    > "$IOS_RUNTIME_LOG" 2>&1 &
IOS_LOG_PID=$!

# Give the log streams a moment to attach before tests start firing
# log lines we want to capture.
sleep 2

# --- Fork both tests in parallel ---
log "Running both UI tests in parallel (Mac trust-anchor + iOS requester)…"
# Pre-create the empty test log so the tail-watcher can attach before
# xcodebuild creates it.
: > "$MAC_TEST_LOG"

# Watcher: when the Mac test prints MATRON_MAC_TRUST_ANCHOR_READY (the
# stdout marker the test emits after recovery-key bootstrap completes),
# touch the host-side ready file. We have to do this on the host side
# because the Mac UI test runner sandbox denies all filesystem writes
# outside its container — see the print() rationale in the test class.
( tail -F "$MAC_TEST_LOG" 2>/dev/null \
    | grep -m1 -F 'MATRON_MAC_TRUST_ANCHOR_READY' >/dev/null \
    && touch "$READY_FILE" \
    && log "  watcher: Mac trust-anchor ready, signalled iOS via $READY_FILE"
) &
WATCHER_PID=$!

set +e
(cd "$ROOT" && xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/MatronVsMatronMacUITests \
    -resultBundlePath "$MAC_XCRESULT" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$MAC_TEST_LOG" 2>&1) &
MAC_TEST_PID=$!

(cd "$ROOT" && xcodebuild test-without-building \
    -scheme Matron \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:MatronUITests/MatronVsMatronIOSUITests \
    -resultBundlePath "$IOS_XCRESULT" \
    CODE_SIGNING_ALLOWED=NO \
    > "$IOS_TEST_LOG" 2>&1) &
IOS_TEST_PID=$!

wait $MAC_TEST_PID
MAC_RC=$?
wait $IOS_TEST_PID
IOS_RC=$?
set -e

log "  Mac rc=$MAC_RC, iOS rc=$IOS_RC"

# --- Trace assertions ---
PASS=1
if [ $MAC_RC -ne 0 ]; then
    log "✗ Mac xcodebuild test failed"
    PASS=0
fi
if [ $IOS_RC -ne 0 ]; then
    log "✗ iOS xcodebuild test failed"
    PASS=0
fi
if ! grep -q "$TRACE_MARKER" "$MAC_RUNTIME_LOG"; then
    log "✗ Mac os.Logger never logged: $TRACE_MARKER"
    PASS=0
fi
if ! grep -q "$TRACE_MARKER" "$IOS_RUNTIME_LOG"; then
    log "✗ iOS os.Logger never logged: $TRACE_MARKER"
    PASS=0
fi

if [ $PASS -eq 1 ]; then
    log "✓ Scenario PASSED"
    exit 0
fi

log "✗ Scenario FAILED — collecting diagnostics"
log "  Mac test log: $MAC_TEST_LOG"
log "  iOS test log: $IOS_TEST_LOG"
log "  Mac runtime: $MAC_RUNTIME_LOG"
log "  iOS runtime: $IOS_RUNTIME_LOG"
log "  Mac xcresult: $MAC_XCRESULT"
log "  iOS xcresult: $IOS_XCRESULT"
echo "--- last 60 lines of Mac test log ---"
tail -60 "$MAC_TEST_LOG" || true
echo "--- last 60 lines of iOS test log ---"
tail -60 "$IOS_TEST_LOG" || true
echo "--- last 30 lines of Mac runtime log ---"
tail -30 "$MAC_RUNTIME_LOG" 2>/dev/null || true
echo "--- last 30 lines of iOS runtime log ---"
tail -30 "$IOS_RUNTIME_LOG" 2>/dev/null || true
exit 1
