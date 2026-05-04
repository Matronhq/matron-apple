#!/usr/bin/env bash
# Scenario: drive the Mac app through "Verify with another device" and have
# the partner client auto-accept + auto-confirm. Asserts that the Mac log
# contains the expected SAS state transitions.
#
# Pre-conditions: run-harness.sh has booted the homeserver + registered
# both users + brought the partner online. ENV vars are set by the runner.
set -euo pipefail

require() { [ -n "${!1:-}" ] || { echo "missing env: $1"; exit 1; }; }
require MATRON_HOMESERVER
require ARTIFACTS_DIR
require PARTNER_CLI
require PARTNER_STORE
require ROOT

MAC_APP="$HOME/Library/Developer/Xcode/DerivedData/Matron-bxmhcklltdsxiccbqjrvsvbdiubi/Build/Products/Debug/MatronMac.app"
MAC_LOG="$ARTIFACTS_DIR/matron-mac.log"

log() { echo "[scenario] $*" | tee -a "$ARTIFACTS_DIR/harness.log"; }

# 1. Wipe Mac state for a deterministic run
log "Wiping Mac app state…"
pkill -x MatronMac >/dev/null 2>&1 || true
sleep 1
rm -rf "$HOME/Library/Application Support/chat.matron.mac"
defaults delete chat.matron.mac >/dev/null 2>&1 || true

# 2. Build (make sure the binary matches the source tree)
log "Building MatronMac (Debug, unsigned)…"
(cd "$ROOT" && xcodebuild -scheme MatronMac -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO >/dev/null) \
    || { echo "build failed"; exit 1; }

# 3. Start log capture
log "Starting Mac log stream → $MAC_LOG"
/usr/bin/log stream --predicate 'subsystem == "chat.matron"' --style compact --level info > "$MAC_LOG" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null || true' EXIT

# 4. Launch app
log "Launching MatronMac…"
open "$MAC_APP"
sleep 3

# 5. Drive UI: sign in + tap Verify with another device
#    (uses AppleScript / osascript for now; XCUITest in v2)
log "Driving Mac UI: sign in as @${MATRON_USER}:localhost"
osascript <<EOF
tell application "System Events"
    tell process "MatronMac"
        set frontmost to true
        delay 1
        -- The sign-in form uses three text fields; tab through them
        keystroke "$MATRON_HOMESERVER"
        keystroke tab
        keystroke "$MATRON_USER"
        keystroke tab
        keystroke "$MATRON_PW"
        delay 0.5
        keystroke return
    end tell
end tell
EOF

log "Waiting for verify gate to appear (5s)…"
sleep 5

log "Tapping 'Verify with another device' (return key on default action)"
osascript <<'EOF'
tell application "System Events"
    tell process "MatronMac"
        set frontmost to true
        keystroke return
    end tell
end tell
EOF

# 6. Have partner auto-accept the verification
log "Partner waiting + auto-confirming SAS (timeout 60s)…"
$PARTNER_CLI wait-verify --store-file "$PARTNER_STORE" --timeout 60 \
    | tee "$ARTIFACTS_DIR/partner-wait-verify.jsonl"

# 7. Tap "Confirm" on the Mac (return key on the SAS sheet's default action)
sleep 1
osascript <<'EOF'
tell application "System Events"
    tell process "MatronMac"
        set frontmost to true
        keystroke return
    end tell
end tell
EOF

log "Waiting 5s for didFinish to land…"
sleep 5

# 8. Assert log contents
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
    if ! grep -qF "$needle" "$MAC_LOG"; then
        echo "  FAIL: missing log line: $needle"
        PASS=false
    else
        echo "  OK: $needle"
    fi
done

if $PASS; then
    log "✓ Scenario PASSED"
    exit 0
else
    log "✗ Scenario FAILED — see $MAC_LOG and $ARTIFACTS_DIR/"
    exit 1
fi
