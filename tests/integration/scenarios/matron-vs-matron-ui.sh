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
# Belt-and-braces fallback: live `log stream` intermittently captures
# zero entries even when the app is logging (TCC/buffering/throttle —
# session 4 saw this repeatedly). Re-query the unified log via
# `log show` against the run window after the test ends. If
# `log stream` worked, these files are duplicates; if it didn't, these
# are our only diagnostic.
MAC_RUNTIME_SHOW_LOG="$ARTIFACTS_DIR/matron-mac-show.log"
IOS_RUNTIME_SHOW_LOG="$ARTIFACTS_DIR/matron-ios-show.log"
# matrix-rust-sdk's `initPlatform`-configured file output. Default
# directory matches `MatronSDKTracing.defaultLogsDirectory` —
# `<cachesDirectory>/matron-sdk-trace`. Mac unsandboxed Debug build
# resolves to ~/Library/Caches; iOS sim resolves inside the app's
# data container.
MAC_SDK_TRACE_DIR="$HOME/Library/Caches/matron-sdk-trace"
MAC_SDK_TRACE_ARTIFACT="$ARTIFACTS_DIR/matron-mac-sdk.log"
IOS_SDK_TRACE_ARTIFACT="$ARTIFACTS_DIR/matron-ios-sdk.log"
MAC_XCRESULT="$ARTIFACTS_DIR/mac.xcresult"
IOS_XCRESULT="$ARTIFACTS_DIR/ios.xcresult"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# Capture scenario start time as ISO-ish format `log show` accepts
# ("YYYY-MM-DD HH:MM:SS"). Used by the post-run `log show` fallback
# to scope the unified-log query to just this run.
SCENARIO_START_TS="$(date '+%Y-%m-%d %H:%M:%S')"

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
# Wipe the matrix-rust-sdk trace directory so each run gets a clean
# log file for post-mortem (`MatronSDKTracing.defaultLogsDirectory`).
# iOS-side trace dir is wiped implicitly by the `simctl uninstall`
# below — that drops the entire app data container.
rm -rf "$MAC_SDK_TRACE_DIR" 2>/dev/null || true
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
# Poll-grep instead of tail|grep: BSD grep with `-m1` buffers input
# across the pipe and doesn't exit promptly when reading from `tail -F`,
# so the watcher silently never fired even when the marker landed in
# the log. A simple 1s poll-and-grep is more robust and one-second
# latency on the synchronization handoff is fine (the iOS test polls
# once per second too).
( while true; do
    if grep -q -F 'MATRON_MAC_TRUST_ANCHOR_READY' "$MAC_TEST_LOG" 2>/dev/null; then
        touch "$READY_FILE"
        log "  watcher: Mac trust-anchor ready, signalled iOS via $READY_FILE"
        break
    fi
    sleep 1
done ) &
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

# --- Belt-and-braces: replay the unified log via `log show` ---
# The live `log stream` capture above intermittently produces empty
# files (TCC throttle / buffering — session 4 saw this repeatedly,
# blocking diagnosis). `log show --start <ts>` reads the persisted
# unified-log buffer so we always have a record even when the stream
# missed events. Captures debug+info levels so DEBUG-level os.Logger
# entries (notice() does not require --debug, but trace()/debug()
# would be silently dropped at the default level) survive.
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
# Mac (Debug build, unsandboxed): trace files land in
# `~/Library/Caches/matron-sdk-trace/matron-sdk*.log`. Concatenate the
# rotated set into one artifact for easy reading.
if compgen -G "$MAC_SDK_TRACE_DIR/matron-sdk*.log" > /dev/null; then
    cat "$MAC_SDK_TRACE_DIR"/matron-sdk*.log > "$MAC_SDK_TRACE_ARTIFACT" 2>/dev/null || true
    log "  Mac SDK trace: $MAC_SDK_TRACE_ARTIFACT ($(wc -l < "$MAC_SDK_TRACE_ARTIFACT") lines)"
else
    log "  Mac SDK trace: no files found at $MAC_SDK_TRACE_DIR"
fi

# iOS sim: trace files live inside the app data container.
# `xcrun simctl get_app_container` resolves the path; the dir is
# wiped on each `simctl uninstall` so we don't need to clean it.
IOS_DATA_CONTAINER="$(xcrun simctl get_app_container "$SIM_UDID" chat.matron.app data 2>/dev/null || true)"
if [ -n "$IOS_DATA_CONTAINER" ]; then
    IOS_SDK_TRACE_DIR="$IOS_DATA_CONTAINER/Library/Caches/matron-sdk-trace"
    if compgen -G "$IOS_SDK_TRACE_DIR/matron-sdk*.log" > /dev/null; then
        cat "$IOS_SDK_TRACE_DIR"/matron-sdk*.log > "$IOS_SDK_TRACE_ARTIFACT" 2>/dev/null || true
        log "  iOS SDK trace: $IOS_SDK_TRACE_ARTIFACT ($(wc -l < "$IOS_SDK_TRACE_ARTIFACT") lines)"
    else
        log "  iOS SDK trace: no files found at $IOS_SDK_TRACE_DIR"
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
echo "--- last 60 lines of Mac runtime show (log show fallback) ---"
tail -60 "$MAC_RUNTIME_SHOW_LOG" 2>/dev/null || true
echo "--- last 60 lines of iOS runtime show (log show fallback) ---"
tail -60 "$IOS_RUNTIME_SHOW_LOG" 2>/dev/null || true
echo "--- last 60 lines of Mac SDK trace ---"
tail -60 "$MAC_SDK_TRACE_ARTIFACT" 2>/dev/null || true
echo "--- last 60 lines of iOS SDK trace ---"
tail -60 "$IOS_SDK_TRACE_ARTIFACT" 2>/dev/null || true
exit 1
