#!/usr/bin/env bash
# Scenario: drive the Mac UI through XCUITest. Signs in via the SwiftUI
# form, taps Verify-with-Other-Device, the partner client (matrix-js-sdk)
# auto-confirms SAS on the other side. Asserts on Matron's `os.Logger`
# trace.
#
# Replacement for verify-mac-against-partner.sh — that one used
# AppleScript keystrokes which work in an interactive Terminal session
# but not from Claude Code's Bash tool. The XCUITest target reads its
# config from `/tmp/matron-test-config.json` (env-vars don't propagate
# cleanly to Mac UI test runners).
#
# KNOWN: the SDK-level test against partner.mjs (verify-sdk-against-
# partner.sh) hits a matrix-rust-sdk ↔ matrix-js-sdk MAC-verification
# interop gap for same-user device verification. This UI scenario
# exercises the same code path, so likely fails the same way at the
# SAS sheet. Useful regardless: validates form-fill, navigation, and
# sheet-presentation up to that point.
#
# Driven by run-harness.sh which exports HOMESERVER, MATRON_USER,
# MATRON_PW, PARTNER_STORE, PARTNER_CLI, ARTIFACTS_DIR, ROOT.
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require MATRON_USER
require MATRON_PW
require PARTNER_CLI
require ARTIFACTS_DIR
require ROOT

XCRESULT="$ARTIFACTS_DIR/verify-ui.xcresult"
BUILD_LOG="$ARTIFACTS_DIR/verify-ui-build.log"
TEST_LOG="$ARTIFACTS_DIR/verify-ui-test.log"
MATRON_LOG="$ARTIFACTS_DIR/matron-mac-ui.log"
PARTNER_LOG="$ARTIFACTS_DIR/partner-wait-verify.jsonl"
CONFIG_FILE="/tmp/matron-test-config.json"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# Wipe any prior Mac-app state so the test exercises the first-launch path.
log "Wiping Mac app state…"
pkill -x MatronMac >/dev/null 2>&1 || true
sleep 1
rm -rf "$HOME/Library/Application Support/chat.matron.mac"
defaults delete chat.matron.mac >/dev/null 2>&1 || true

# Build host app + UI test bundle.
log "Building MatronMac + MatronMacUITests for testing…"
(cd "$ROOT" && xcodebuild build-for-testing \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$BUILD_LOG" 2>&1) \
    || { echo "build-for-testing failed; see $BUILD_LOG"; tail -50 "$BUILD_LOG"; exit 1; }

# Write the config the UI test reads (env-vars don't propagate to Mac UI runners).
log "Writing $CONFIG_FILE for the UI test…"
cat > "$CONFIG_FILE" <<EOF
{
  "homeserver": "$HOMESERVER",
  "user": "$MATRON_USER",
  "password": "$MATRON_PW",
  "verify_timeout": 60
}
EOF

# Capture matron's os.Logger output for post-mortem.
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info > "$MATRON_LOG" 2>&1 &
LOG_PID=$!

# Spawn partner.mjs `bootstrap-and-wait` — bootstrap cross-signing AND
# wait for verification in one long-running process so all post-bootstrap
# crypto state stays in memory (mirrors the working SDK scenario; the
# split bootstrap-anchor → wait-verify shape leaks state and trips MAC).
# run-harness.sh auto-skips its own bootstrap-anchor for this scenario.
log "Spawning partner.mjs bootstrap-and-wait (timeout 120s)…"
$PARTNER_CLI bootstrap-and-wait \
    --homeserver "$HOMESERVER" \
    --user "$MATRON_USER" \
    --password "$MATRON_PW" \
    --device-name "matron-test-partner" \
    --timeout 120 \
    > "$PARTNER_LOG" 2>&1 &
PARTNER_PID=$!

# Wait for partner to bootstrap + start listening before the Mac app
# signs in. Otherwise matron's .request might land before partner has a
# crypto.verificationRequestReceived listener attached.
log "Waiting for partner to emit 'ready' (up to 60s)…"
for i in {1..60}; do
    if grep -q '"event":"ready"' "$PARTNER_LOG" 2>/dev/null; then
        log "  partner ready at ${i}s"
        break
    fi
    sleep 1
    if [ "$i" = "60" ]; then
        log "  ✗ partner never reached ready — see $PARTNER_LOG"
        tail -20 "$PARTNER_LOG"
        exit 1
    fi
done

cleanup() {
    [ -n "${LOG_PID:-}" ] && kill "$LOG_PID" 2>/dev/null || true
    [ -n "${PARTNER_PID:-}" ] && kill "$PARTNER_PID" 2>/dev/null || true
    pkill -x MatronMac 2>/dev/null || true
    rm -f "$CONFIG_FILE"
}
trap cleanup EXIT

log "Running VerifyWithPartnerUITests…"
set +e
xcodebuild test-without-building \
    -scheme MatronMac \
    -destination 'platform=macOS' \
    -only-testing:MatronMacUITests/VerifyWithPartnerUITests \
    -resultBundlePath "$XCRESULT" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    > "$TEST_LOG" 2>&1
RC=$?
set -e

if [ $RC -eq 0 ]; then
    log "✓ Scenario PASSED"
    exit 0
fi

log "✗ Scenario FAILED (rc=$RC)"
log "  Test log: $TEST_LOG"
log "  Matron os.Logger trace: $MATRON_LOG"
log "  Partner trace: $PARTNER_LOG"
log "  Result bundle: $XCRESULT"
log "  Field readbacks (if produced by test): /tmp/matron-test-fields.txt"
log "  Accessibility tree (if produced): /tmp/matron-test-debug.txt"
echo "--- field readbacks ---"
[ -f /tmp/matron-test-fields.txt ] && cat /tmp/matron-test-fields.txt || echo "(no field-readback file produced)"
echo "--- last 60 lines of test log ---"
tail -60 "$TEST_LOG"
exit $RC
