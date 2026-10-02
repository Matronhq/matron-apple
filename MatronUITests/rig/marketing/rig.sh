#!/bin/bash
# Marketing screenshot rig: a throwaway local matron-journal seeded with
# invented work for a demo user, the iOS simulator app signed in to it, and
# a Mac home directory ready for the Mac captures. Nothing real is touched.
#
#   RIG_UDID=<iPhone 17 Pro Max sim>  RIG_JOURNAL=<matron-journal checkout> \
#     MatronUITests/rig/marketing/rig.sh
#
# Prereqs (see MatronUITests/rig/README.md "Marketing rig"):
#   - the iOS app built for testing into /tmp/matron-shots-dd (signed, so the
#     app group exists for the session injection);
#   - $RIG_JOURNAL has node_modules with 'ws' (npm ci there).
# Everything disposable lives in $DEMO. The journal is started on its own
# port and tracked by pidfile — other local journals are never killed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEMO="${RIG_DEMO:-/tmp/shots-demo}"
JOURNAL="${RIG_JOURNAL:-$HOME/Dev/matron-journal}"
UDID="${RIG_UDID:?set RIG_UDID to the iPhone 17 Pro Max simulator udid}"
APP="${RIG_APP:-/tmp/matron-shots-dd/Build/Products/Debug-iphonesimulator/Matron.app}"
PORT=9810
# RIG_CLOCK: the status-bar time; message times are placed before it. The
# default 9:41 is Apple's convention but leaves relative labels reading
# hours ago by the afternoon; RIG_CLOCK=now uses the real clock instead.
CLOCK="${RIG_CLOCK:-9:41}"
# RIG_APPEARANCE=light|dark sets the simulator appearance (the app follows it).
APPEARANCE="${RIG_APPEARANCE:-light}"
[[ "$CLOCK" == now ]] && CLOCK="$(date +%-H:%M)"
mkdir -p "$DEMO"
for p in journal responder; do
  if [[ -f "${DEMO:?}/${p:?}.pid" ]]; then
    kill "$(cat "${DEMO:?}/${p:?}.pid")" 2>/dev/null || true
    rm -f "${DEMO:?}/${p:?}.pid"
  fi
done
sleep 1
if curl -s -m 1 "http://127.0.0.1:$PORT/snapshot" >/dev/null 2>&1; then
  echo "rig: something else is already listening on $PORT" >&2; exit 1
fi
rm -rf "${DEMO:?}/matron.db" "${DEMO:?}/matron.db-shm" "${DEMO:?}/matron.db-wal" "${DEMO:?}/media" "${DEMO:?}/mac-home"
cp "$HERE/seed.mjs" "$HERE/responder.mjs" "$DEMO/"
ln -sfn "$JOURNAL/node_modules" "$DEMO/node_modules"

cd "$JOURNAL"
MATRON_DB="$DEMO/matron.db" MATRON_PORT=$PORT nohup node src/server.js > "$DEMO/journal.log" 2>&1 &
echo $! > "$DEMO/journal.pid"
sleep 2; grep -q listening "$DEMO/journal.log"
MATRON_DB="$DEMO/matron.db" MATRON_PASSWORD=matron-demo-2026 node bin/matron-admin.js user add demo
for a in mac-studio homelab cloud-dev; do
  MATRON_DB="$DEMO/matron.db" node bin/matron-admin.js agent add demo "$a" > "$DEMO/agent-$a.txt"
done
curl -s -X POST "http://127.0.0.1:$PORT/login" -H 'content-type: application/json' \
  -d '{"username":"demo","password":"matron-demo-2026","device_name":"iPhone"}' > "$DEMO/login-client.json"

cd "$DEMO"
node seed.mjs
# Back-date so every time on screen reads before the 9:41 status bar.
python3 "$HERE/backdate.py" "$DEMO/matron.db" "${RIG_CLOCK:-9:41}"
nohup node responder.mjs > "$DEMO/responder.log" 2>&1 &
echo $! > "$DEMO/responder.pid"
sleep 2; grep -q connected "$DEMO/responder.log"

# Session files: the iOS app group container and a Mac home.
python3 - "$DEMO" <<'PY'
import json, sys, os
d = sys.argv[1]
l = json.load(open(f'{d}/login-client.json'))
s = {'userID': 'demo', 'deviceID': str(l['device_id']), 'homeserverURL': 'http://127.0.0.1:9810', 'accessToken': l['token']}
os.makedirs(f'{d}/mac-home/sessions', exist_ok=True)
json.dump(s, open(f'{d}/mac-home/sessions/matron.journal.session.json', 'w'))
json.dump(s, open(f'{d}/session.json', 'w'))
PY
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" chat.matron.app || true
xcrun simctl install "$UDID" "$APP"
C=$(xcrun simctl get_app_container "$UDID" chat.matron.app groups | grep group.chat.matron | awk '{print $2}')
mkdir -p "$C/sessions"; cp "$DEMO/session.json" "$C/sessions/matron.journal.session.json"
xcrun simctl ui "$UDID" appearance "$APPEARANCE"
xcrun simctl status_bar "$UDID" override --time "$CLOCK" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
# Warm launch: first boot does the notification alert + initial sync.
xcrun simctl launch "$UDID" chat.matron.app >/dev/null; sleep 8
xcrun simctl terminate "$UDID" chat.matron.app 2>/dev/null || true
echo "marketing rig ready: journal pid $(cat "$DEMO/journal.pid"), demo dir $DEMO"
