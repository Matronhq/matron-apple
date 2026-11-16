#!/usr/bin/env bash
# Launch timing rig: a throwaway local journal the size of a well-used one,
# reached through latency-proxy.mjs, and the app installed on a simulator
# with a session for it. Separate from rebuild-rig.sh's rig (its own
# folder and ports), so the two can run side by side.
#
#   RIG_UDID   simulator to install on (booted)
#   RIG_APP    path to a signed Matron.app built for the simulator
#   RIG_DIR    scratch folder (default /tmp/matron-launch-rig)
#   RIG_JOURNAL  matron-journal checkout (default ~/Dev/matron-journal)
#   RIG_PORT / RIG_PROXY_PORT  journal and proxy ports (9820 / 9821)
#   RIG_DELAY_MS  proxy delay each way (default 75)
#   RIG_RESEED=0  keep the journal and its items, only reinstall the app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${RIG_DIR:-/tmp/matron-launch-rig}"
JOURNAL="${RIG_JOURNAL:-$HOME/Dev/matron-journal}"
UDID="${RIG_UDID:?set RIG_UDID to a booted simulator}"
APP="${RIG_APP:?set RIG_APP to a signed simulator build of Matron.app}"
PORT="${RIG_PORT:-9820}"
PROXY_PORT="${RIG_PROXY_PORT:-9821}"
export RIG_DIR="$DIR" RIG_PORT="$PORT"

mkdir -p "$DIR"
cp "$HERE"/seed-launch.mjs "$HERE"/launch-backlog.mjs "$HERE"/latency-proxy.mjs "$DIR/"
ln -sfn "$JOURNAL/node_modules" "$DIR/node_modules"

if [[ "${RIG_RESEED:-1}" == "1" ]]; then
  # Only this rig's own journal and proxy: both carry its folder or port.
  pkill -f "launch-rig-journal-$PORT" 2>/dev/null || true
  pkill -f "$DIR/latency-proxy.mjs" 2>/dev/null || true
  sleep 1
  find "$DIR" -maxdepth 1 -name 'matron.db*' -delete
  (cd "$JOURNAL" && MATRON_DB="$DIR/matron.db" MATRON_PORT="$PORT" \
    nohup node src/server.js "launch-rig-journal-$PORT" > "$DIR/journal.log" 2>&1 &)
  sleep 2
  grep -q listening "$DIR/journal.log"
  (cd "$JOURNAL" && MATRON_DB="$DIR/matron.db" MATRON_PASSWORD=matron-rig-2026 node bin/matron-admin.js user add demo)
  (cd "$JOURNAL" && MATRON_DB="$DIR/matron.db" node bin/matron-admin.js agent add demo box-a > "$DIR/agent-box-a.txt")
  (cd "$DIR" && node seed-launch.mjs)
  (nohup node "$DIR/latency-proxy.mjs" "$PROXY_PORT" "$PORT" "${RIG_DELAY_MS:-75}" > "$DIR/proxy.log" 2>&1 &)
  sleep 1
fi
curl -s -X POST "http://127.0.0.1:$PORT/login" -H 'content-type: application/json' \
  -d '{"username":"demo","password":"matron-rig-2026","device_name":"rig-phone"}' > "$DIR/login-client.json"

xcrun simctl terminate "$UDID" chat.matron.app 2>/dev/null || true
xcrun simctl uninstall "$UDID" chat.matron.app || true
xcrun simctl install "$UDID" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$UDID" chat.matron.app groups | grep group.chat.matron | awk '{print $2}')
mkdir -p "$CONTAINER/sessions"
python3 - "$CONTAINER" "$DIR" "$PROXY_PORT" <<'PYEOF'
import json, sys
login = json.load(open(sys.argv[2] + '/login-client.json'))
session = {'userID': 'demo', 'deviceID': str(login['device_id']),
           'homeserverURL': 'http://127.0.0.1:' + sys.argv[3], 'accessToken': login['token']}
open(sys.argv[1] + '/sessions/matron.journal.session.json', 'w').write(json.dumps(session))
PYEOF

# First launch: the initial sync of every item.
SIMCTL_CHILD_MATRON_PERF_NO_PUSH_PROMPT=1 xcrun simctl launch "$UDID" chat.matron.app -sync.scope for_you >/dev/null
sleep "${RIG_FIRST_SYNC_S:-45}"
xcrun simctl terminate "$UDID" chat.matron.app 2>/dev/null || true
echo "launch rig ready"
