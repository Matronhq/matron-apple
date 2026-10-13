#!/usr/bin/env bash
# Rebuilds the e2e smoke-test rig from zero: a throwaway matron-journal on
# its own port, a user and agent, seeded content (seed.mjs), and a fresh
# install of the app on the dedicated "Matron e2e" simulator.
#
# Kept apart from MatronUITests/rig on purpose (port 9820, its own state
# dir, its own simulator) so it can run beside a release session that is
# using that rig or the default simulators.
#
# Env:
#   E2E_JOURNAL   matron-journal checkout (default ~/Dev/matron-journal)
#   E2E_STATE     state dir (default ~/Library/Caches/matron-e2e/rig)
#   E2E_PORT      journal port (default 9820)
#   E2E_SIM_NAME  simulator name (default "Matron e2e"; created if missing)
#   E2E_APP       built Matron.app (default the build e2e-run.sh makes)
#   E2E_INJECT_SESSION  1 (default) writes a signed-in session into the
#                 app group so tests start signed in; 0 leaves it signed out.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JOURNAL="${E2E_JOURNAL:-$HOME/Dev/matron-journal}"
STATE="${E2E_STATE:-$HOME/Library/Caches/matron-e2e/rig}"
PORT="${E2E_PORT:-9820}"
SIM_NAME="${E2E_SIM_NAME:-Matron e2e}"
APP="${E2E_APP:-$HOME/Library/Caches/matron-e2e/dd/Build/Products/Debug-iphonesimulator/Matron.app}"
BASE="http://127.0.0.1:$PORT"

mkdir -p "$STATE"
# Stop only our own journal (pid file), never another rig's.
if [[ -f "$STATE/journal.pid" ]]; then
  kill "$(cat "$STATE/journal.pid")" 2>/dev/null || true
  sleep 1
fi
rm -rf "${STATE:?}"/matron.db* "${STATE:?}/media"

# Fully detached (own session, no inherited fds): a plain `nohup … &` keeps
# a caller that pipes this script's output waiting on the server.
MATRON_DB="$STATE/matron.db" MATRON_PORT="$PORT" python3 - "$JOURNAL" "$STATE" <<'PYEOF'
import subprocess, sys
journal, state = sys.argv[1:3]
log = open(state + '/journal.log', 'w')
p = subprocess.Popen(['node', 'src/server.js'], cwd=journal, stdin=subprocess.DEVNULL,
                     stdout=log, stderr=log, start_new_session=True, close_fds=True)
open(state + '/journal.pid', 'w').write(str(p.pid))
PYEOF
for _ in $(seq 1 30); do grep -q listening "$STATE/journal.log" 2>/dev/null && break; sleep 0.5; done
grep -q listening "$STATE/journal.log"

cd "$JOURNAL"
MATRON_DB="$STATE/matron.db" MATRON_PASSWORD=matron-e2e-2026 node bin/matron-admin.js user add e2e > /dev/null
MATRON_DB="$STATE/matron.db" node bin/matron-admin.js agent add e2e e2e-box > "$STATE/agent.txt"
curl -sf -X POST "$BASE/login" -H 'content-type: application/json' \
  -d '{"username":"e2e","password":"matron-e2e-2026","device_name":"e2e-seed"}' > "$STATE/login-client.json"

E2E_STATE="$STATE" E2E_BASE="$BASE" node "$HERE/seed.mjs"

# Simulator: our own device, created on first use.
UDID=$(xcrun simctl list devices available | grep -F "    $SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)
if [[ -z "$UDID" ]]; then UDID=$(xcrun simctl create "$SIM_NAME" "iPhone 17"); fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
echo "$UDID" > "$STATE/udid"
# No "Save Password?" sheet after sign-in: it covers the app and its buttons
# are not reliably in the accessibility tree, so a test can't always answer it.
xcrun simctl spawn "$UDID" defaults write com.apple.WebUI AutoFillPasswords -bool NO

xcrun simctl terminate "$UDID" chat.matron.app 2>/dev/null || true
xcrun simctl uninstall "$UDID" chat.matron.app 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

if [[ "${E2E_INJECT_SESSION:-1}" == "1" ]]; then
  CONTAINER=$(xcrun simctl get_app_container "$UDID" chat.matron.app groups | grep group.chat.matron | awk '{print $2}')
  mkdir -p "$CONTAINER/sessions"
  python3 - "$CONTAINER" "$STATE" "$BASE" <<'PYEOF'
import json, sys
container, state, base = sys.argv[1:4]
login = json.load(open(state + '/login-client.json'))
session = {'userID': 'e2e', 'deviceID': str(login['device_id']), 'homeserverURL': base, 'accessToken': login['token']}
open(container + '/sessions/matron.journal.session.json', 'w').write(json.dumps(session))
PYEOF
fi
echo "rig ready: journal $BASE, sim $SIM_NAME ($UDID)"
