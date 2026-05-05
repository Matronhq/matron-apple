#!/usr/bin/env bash
# Scenario: Mac signs in to the test homeserver, taps Verify-with-Other-Device,
# and the partner client (matrix-js-sdk) auto-confirms SAS. Asserts on the
# Mac's os.Logger trace.
#
# Driven by run-harness.sh which exports the env vars used here.
#
# v1: drives the Mac via AppleScript (System Events keystroke). v2 will swap
# to XCUITest once the sandboxed-app + UI-testing connection is sorted —
# the accessibility identifiers are already plumbed through the SwiftUI
# views, so the rewrite is straightforward.
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require HOMESERVER
require ARTIFACTS_DIR
require PARTNER_CLI
require PARTNER_STORE
require ROOT
require MATRON_USER
require MATRON_PW

MAC_APP="$HOME/Library/Developer/Xcode/DerivedData/Matron-bxmhcklltdsxiccbqjrvsvbdiubi/Build/Products/Debug/MatronMac.app"
MAC_LOG="$ARTIFACTS_DIR/matron-mac.log"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# 1. Wipe Mac state for a deterministic run.
log "Wiping Mac app state…"
pkill -x MatronMac >/dev/null 2>&1 || true
sleep 1
rm -rf "$HOME/Library/Application Support/chat.matron.mac"
defaults delete chat.matron.mac >/dev/null 2>&1 || true

# 2. Build the Mac app (Debug, unsigned).
log "Building MatronMac (Debug, unsigned)…"
(cd "$ROOT" && xcodebuild -scheme MatronMac -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO >/dev/null) \
    || { echo "build failed"; exit 1; }

# 3. Start log capture (Matron os.Logger).
log "Starting Mac log stream → $MAC_LOG"
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info > "$MAC_LOG" 2>&1 &
LOG_PID=$!

# 4. Start the partner waiter in background — auto-confirms SAS as soon as
#    Matron sends the verification request.
log "Partner: wait-verify (background, timeout 90s)…"
$PARTNER_CLI wait-verify \
    --store-file "$PARTNER_STORE" \
    --timeout 90 \
    > "$ARTIFACTS_DIR/partner-wait-verify.jsonl" 2>&1 &
PARTNER_PID=$!

cleanup() {
    kill "$LOG_PID" 2>/dev/null || true
    kill "$PARTNER_PID" 2>/dev/null || true
    pkill -x MatronMac 2>/dev/null || true
}
trap cleanup EXIT

# 5. Brief pause so the partner is subscribed before Matron sends.
sleep 2

# 6. Launch the Mac app.
log "Launching MatronMac…"
open "$MAC_APP"
sleep 4

# 7. Drive the Mac UI: sign in. We use System Events keystrokes — the
#    SwiftUI form puts initial focus on the first text field and tab
#    cycles through them. AppleScript is brittle for general flows but
#    fine for a deterministic field-tab sequence on first launch.
log "Driving sign-in (homeserver=$HOMESERVER, user=$MATRON_USER)"
osascript - "$HOMESERVER" "$MATRON_USER" "$MATRON_PW" <<'OSA'
on run argv
    set hs to item 1 of argv
    set u to item 2 of argv
    set pw to item 3 of argv
    tell application "System Events"
        tell process "MatronMac"
            set frontmost to true
            delay 1
            keystroke hs
            keystroke tab
            keystroke u
            keystroke tab
            keystroke pw
            delay 0.5
            keystroke return
        end tell
    end tell
end run
OSA

log "Waiting for verify gate (5s)…"
sleep 5

log "Tapping 'Verify with another device' (return = default action)"
osascript <<'OSA'
tell application "System Events"
    tell process "MatronMac"
        set frontmost to true
        keystroke return
    end tell
end tell
OSA

# 8. Wait for the SAS sheet's emoji compare. The partner will be auto-
#    confirming in the background once it sees the request.
log "Waiting for emoji-compare screen (up to 30s)…"
for i in {1..30}; do
    if grep -q "routeSasData: yielding .readyForEmoji" "$MAC_LOG" 2>/dev/null; then
        log "  emojis appeared on Mac at $i s"
        break
    fi
    sleep 1
done

# 9. Press 'They match' on Mac (return = .borderedProminent default).
log "Pressing 'They match' on Mac"
osascript <<'OSA'
tell application "System Events"
    tell process "MatronMac"
        set frontmost to true
        keystroke return
    end tell
end tell
OSA

# 10. Wait for the partner waiter to complete its dance.
log "Waiting up to 30s for partner wait-verify to finish…"
for i in {1..30}; do
    if ! kill -0 "$PARTNER_PID" 2>/dev/null; then break; fi
    sleep 1
done

# 11. Assert the Mac log shows the full SAS lifecycle.
log "Asserting Mac log shows full SAS lifecycle…"
EXPECTED=(
    "verificationStateListener: fired with unverified"
    "startSAS: enter"
    "SDK→didReceiveVerificationData"
    "routeSasFinished: yielding .verified"
    "verificationStateListener: fired with verified"
)
PASS=true
for needle in "${EXPECTED[@]}"; do
    if grep -qF "$needle" "$MAC_LOG"; then
        echo "  OK: $needle"
    else
        echo "  FAIL: missing log line: $needle"
        PASS=false
    fi
done

# 12. Snapshot a screenshot for the artifact bundle.
screencapture -x "$ARTIFACTS_DIR/mac-final.png" 2>/dev/null || true

if $PASS; then
    log "✓ Scenario PASSED"
    exit 0
else
    log "✗ Scenario FAILED"
    log "  Logs: $MAC_LOG"
    log "  Partner: $ARTIFACTS_DIR/partner-wait-verify.jsonl"
    log "  Screenshot: $ARTIFACTS_DIR/mac-final.png"
    exit 1
fi
