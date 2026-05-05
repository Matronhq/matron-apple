#!/usr/bin/env bash
# Scenario: drive iOS sim (trust-anchor responder) + Mac (requester)
# end-to-end via XCUITest. Mirror of matron-vs-matron-ui.sh with the
# directions SWAPPED — handover Priority A test #2.
#
# iOS signs in first, runs the recovery-key generate flow, then prints
# MATRON_IOS_TRUST_ANCHOR_READY. The host tail-watcher creates
# /Users/Shared/matron-ios-ready when it sees that line. Mac polls the
# ready-file before signing in, then drives SAS as the requester.
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
READY_FILE="/Users/Shared/matron-ios-ready"

MAC_BUILD_LOG="$ARTIFACTS_DIR/rev-mac-build.log"
IOS_BUILD_LOG="$ARTIFACTS_DIR/rev-ios-build.log"
MAC_TEST_LOG="$ARTIFACTS_DIR/rev-mac-test.log"
IOS_TEST_LOG="$ARTIFACTS_DIR/rev-ios-test.log"
MAC_RUNTIME_LOG="$ARTIFACTS_DIR/rev-matron-mac.log"
IOS_RUNTIME_LOG="$ARTIFACTS_DIR/rev-matron-ios.log"
# Belt-and-braces: live `log stream` intermittently captures zero
# entries; `log show --start` fallback re-queries the unified log
# against the run window. See matron-vs-matron-ui.sh for the full
# rationale.
MAC_RUNTIME_SHOW_LOG="$ARTIFACTS_DIR/rev-matron-mac-show.log"
IOS_RUNTIME_SHOW_LOG="$ARTIFACTS_DIR/rev-matron-ios-show.log"
MAC_SDK_TRACE_DIR="$HOME/Library/Caches/matron-sdk-trace"
MAC_SDK_TRACE_ARTIFACT="$ARTIFACTS_DIR/rev-matron-mac-sdk.log"
IOS_SDK_TRACE_ARTIFACT="$ARTIFACTS_DIR/rev-matron-ios-sdk.log"
MAC_XCRESULT="$ARTIFACTS_DIR/rev-mac.xcresult"
IOS_XCRESULT="$ARTIFACTS_DIR/rev-ios.xcresult"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

SCENARIO_START_TS="$(date '+%Y-%m-%d %H:%M:%S')"

# --- Wipe stale signals + app state ---
log "Wiping app state (Mac + iOS sim) and stale ready-file…"
rm -f "$READY_FILE"
pkill -x MatronMac >/dev/null 2>&1 || true
sleep 1
rm -rf "$HOME/Library/Application Support/chat.matron.mac"
rm -f "$HOME/Library/Preferences/chat.matron.mac.plist"
defaults delete chat.matron.mac >/dev/null 2>&1 || true
killall cfprefsd 2>/dev/null || true
rm -rf "$MAC_SDK_TRACE_DIR" 2>/dev/null || true
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
if ! xcrun simctl list devices | grep -q "$SIM_UDID"; then
    log "✗ Simulator $SIM_UDID not found on this machine. Set MATRON_SIM_UDID env var to override."
    exit 1
fi
xcrun simctl terminate "$SIM_UDID" chat.matron.app >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_UDID" chat.matron.app >/dev/null 2>&1 || true

# --- Build both UI test bundles in parallel ---
log "Building ReverseDirectionMacUITests + ReverseDirectionIOSUITests for testing (parallel)…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/ReverseDirectionMacUITests \
    -allowProvisioningUpdates \
    > "$MAC_BUILD_LOG" 2>&1) &
MAC_BUILD_PID=$!

(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme Matron \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:MatronUITests/ReverseDirectionIOSUITests \
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

sleep 2

# --- Fork both tests in parallel ---
log "Running both UI tests in parallel (iOS trust-anchor + Mac requester)…"
# Pre-create the empty test log so the tail-watcher can attach before
# xcodebuild creates it.
: > "$IOS_TEST_LOG"

# Watcher: when the iOS test prints MATRON_IOS_TRUST_ANCHOR_READY, touch
# the host-side ready file. Same poll-grep shape (not tail | grep -m1) as
# the Mac watcher in matron-vs-matron-ui.sh — BSD grep with `-m1`
# buffers across pipes from `tail -F` and silently never fires.
( while true; do
    if grep -q -F 'MATRON_IOS_TRUST_ANCHOR_READY' "$IOS_TEST_LOG" 2>/dev/null; then
        touch "$READY_FILE"
        log "  watcher: iOS trust-anchor ready, signalled Mac via $READY_FILE"
        break
    fi
    sleep 1
done ) &
WATCHER_PID=$!

set +e
(cd "$ROOT" && xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/ReverseDirectionMacUITests \
    -resultBundlePath "$MAC_XCRESULT" \
    -allowProvisioningUpdates \
    > "$MAC_TEST_LOG" 2>&1) &
MAC_TEST_PID=$!

(cd "$ROOT" && xcodebuild test-without-building \
    -scheme Matron \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:MatronUITests/ReverseDirectionIOSUITests \
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

# --- Belt-and-braces: replay the unified log via `log show` ---
log "Collecting unified-log fallback via log show…"
/usr/bin/log show --predicate 'subsystem == "chat.matron"' \
    --start "$SCENARIO_START_TS" \
    --info --debug --style compact \
    > "$MAC_RUNTIME_SHOW_LOG" 2>&1 || true
xcrun simctl spawn "$SIM_UDID" log show --predicate 'subsystem == "chat.matron"' \
    --start "$SCENARIO_START_TS" \
    --info --debug --style compact \
    > "$IOS_RUNTIME_SHOW_LOG" 2>&1 || true

# --- Pull matrix-rust-sdk trace files into artifacts ---
if compgen -G "$MAC_SDK_TRACE_DIR/matron-sdk*.log" > /dev/null; then
    cat "$MAC_SDK_TRACE_DIR"/matron-sdk*.log > "$MAC_SDK_TRACE_ARTIFACT" 2>/dev/null || true
    log "  Mac SDK trace: $MAC_SDK_TRACE_ARTIFACT ($(wc -l < "$MAC_SDK_TRACE_ARTIFACT") lines)"
fi

IOS_DATA_CONTAINER="$(xcrun simctl get_app_container "$SIM_UDID" chat.matron.app data 2>/dev/null || true)"
if [ -n "$IOS_DATA_CONTAINER" ]; then
    IOS_SDK_TRACE_DIR="$IOS_DATA_CONTAINER/Library/Caches/matron-sdk-trace"
    if compgen -G "$IOS_SDK_TRACE_DIR/matron-sdk*.log" > /dev/null; then
        cat "$IOS_SDK_TRACE_DIR"/matron-sdk*.log > "$IOS_SDK_TRACE_ARTIFACT" 2>/dev/null || true
        log "  iOS SDK trace: $IOS_SDK_TRACE_ARTIFACT ($(wc -l < "$IOS_SDK_TRACE_ARTIFACT") lines)"
    fi
fi

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
if ! grep -q "$TRACE_MARKER" "$MAC_RUNTIME_LOG" "$MAC_RUNTIME_SHOW_LOG" 2>/dev/null; then
    log "✗ Mac os.Logger never logged: $TRACE_MARKER"
    PASS=0
fi
if ! grep -q "$TRACE_MARKER" "$IOS_RUNTIME_LOG" "$IOS_RUNTIME_SHOW_LOG" 2>/dev/null; then
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
log "  Mac runtime stream: $MAC_RUNTIME_LOG"
log "  iOS runtime stream: $IOS_RUNTIME_LOG"
log "  Mac runtime show:   $MAC_RUNTIME_SHOW_LOG"
log "  iOS runtime show:   $IOS_RUNTIME_SHOW_LOG"
log "  Mac SDK trace:      $MAC_SDK_TRACE_ARTIFACT"
log "  iOS SDK trace:      $IOS_SDK_TRACE_ARTIFACT"
log "  Mac xcresult: $MAC_XCRESULT"
log "  iOS xcresult: $IOS_XCRESULT"
echo "--- last 60 lines of Mac test log ---"
tail -60 "$MAC_TEST_LOG" || true
echo "--- last 60 lines of iOS test log ---"
tail -60 "$IOS_TEST_LOG" || true
echo "--- last 30 lines of Mac runtime stream ---"
tail -30 "$MAC_RUNTIME_LOG" 2>/dev/null || true
echo "--- last 30 lines of iOS runtime stream ---"
tail -30 "$IOS_RUNTIME_LOG" 2>/dev/null || true
echo "--- last 60 lines of Mac runtime show ---"
tail -60 "$MAC_RUNTIME_SHOW_LOG" 2>/dev/null || true
echo "--- last 60 lines of iOS runtime show ---"
tail -60 "$IOS_RUNTIME_SHOW_LOG" 2>/dev/null || true
exit 1
