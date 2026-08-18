#!/usr/bin/env bash
# Rebuilds the screenshot rig from zero: journal DB, identities, seed,
# back-dating, responder, sim app state. Idempotent — run whenever the seed
# content changes.
set -euo pipefail

DEMO=/tmp/matron-demo
JOURNAL=~/Dev/matron-journal
UDID=E55664EB-2F33-4238-B360-38C616A43EE8
APP=/tmp/matron-dd/Build/Products/Debug-iphonesimulator/Matron.app

pkill -f 'node src/server.js' 2>/dev/null || true
pkill -f 'node responder.mjs' 2>/dev/null || true
pkill -f "$DEMO/responder.mjs" 2>/dev/null || true
sleep 1
rm -f "$DEMO"/matron.db*

cd "$JOURNAL"
(MATRON_DB="$DEMO/matron.db" nohup node src/server.js > "$DEMO/journal.log" 2>&1 &)
sleep 2
grep -q listening "$DEMO/journal.log"

MATRON_DB="$DEMO/matron.db" MATRON_PASSWORD=matron-demo-2026 node bin/matron-admin.js user add demo
MATRON_DB="$DEMO/matron.db" node bin/matron-admin.js agent add demo mac-studio > "$DEMO/agent-mac-studio.txt"
MATRON_DB="$DEMO/matron.db" node bin/matron-admin.js agent add demo homelab > "$DEMO/agent-homelab.txt"
curl -s -X POST http://127.0.0.1:9810/login -H 'content-type: application/json' \
  -d '{"username":"demo","password":"matron-demo-2026","device_name":"seed-client"}' > "$DEMO/login-client.json"

cd "$DEMO"
node seed.mjs

python3 - <<'PYEOF'
import sqlite3, time
now = int(time.time()*1000)
MIN = 60_000; H = 3_600_000
plan = {
  'demo-fix-flaky-upload': now - 6*MIN,
  'demo-pairing-room':     now - 11*MIN,
  'demo-auth-refactor':    now - 18*MIN,
  'demo-auth-explore':     now - 16*MIN,
  'demo-homelab-nightly':  now - 40*MIN,
  'demo-dark-mode':        now - 2*H,
  'demo-release-notes':    now - 20*H,
  'demo-memory-spike':     now - 26*H,
}
db = sqlite3.connect('/tmp/matron-demo/matron.db')
for convo, endts in plan.items():
    rows = db.execute("SELECT seq FROM events WHERE convo_id=? ORDER BY seq", (convo,)).fetchall()
    n = len(rows)
    for i, (seq,) in enumerate(rows):
        ts = endts - (n-1-i)*int(4*MIN/max(1,n-1)) if n > 1 else endts
        db.execute("UPDATE events SET ts=? WHERE convo_id=? AND seq=?", (ts, convo, seq))
    db.execute("UPDATE conversations SET created_at=? WHERE id=?", (endts - 5*MIN, convo))
db.commit()
print('back-dated')
PYEOF

(nohup node responder.mjs > responder.log 2>&1 &)
sleep 2
grep -q 'mac-studio. connected' responder.log || grep -q connected responder.log

# Fresh app state on the sim + session injection
xcrun simctl uninstall "$UDID" chat.matron.app || true
xcrun simctl install "$UDID" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$UDID" chat.matron.app groups | grep group.chat.matron | awk '{print $2}')
mkdir -p "$CONTAINER/sessions"
python3 - "$CONTAINER" <<'PYEOF'
import json, sys
login = json.load(open('/tmp/matron-demo/login-client.json'))
session = {'userID':'demo','deviceID':str(login['device_id']),'homeserverURL':'http://127.0.0.1:9810','accessToken':login['token']}
open(sys.argv[1] + '/sessions/matron.journal.session.json','w').write(json.dumps(session))
PYEOF

# Mac demo home too
mkdir -p /tmp/matron-demo-home/sessions
cp "$CONTAINER/sessions/matron.journal.session.json" /tmp/matron-demo-home/sessions/

# Warm launch: first boot does the notification alert + initial sync
xcrun simctl launch "$UDID" chat.matron.app >/dev/null
sleep 6
xcrun simctl terminate "$UDID" chat.matron.app 2>/dev/null || true
echo "rig rebuilt"
