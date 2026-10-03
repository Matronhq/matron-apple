#!/bin/bash
# Mac marketing captures against the running marketing rig (rig.sh first).
# Launches the Debug MatronMac through LaunchServices once per shot with the
# DebugSnapshot hooks, which capture the app's own window (no Screen
# Recording grant needed) at 1280×800 points → 2560×1600 px on a 2x display.
#   RIG_MAC_APP=<path to Debug MatronMac.app> MatronUITests/rig/marketing/mac-shots.sh [out dir]
set -euo pipefail
DEMO="${RIG_DEMO:-/tmp/shots-demo}"
APP="${RIG_MAC_APP:-/tmp/matron-shots-mac-dd/Build/Products/Debug/MatronMac.app}"
OUT="${1:-/tmp/shots-out-mac}"
APPEARANCE="${RIG_MAC_APPEARANCE:-light}"
# Seconds before the capture; raise it on a loaded machine (a capture before
# the window has drawn comes out black).
AFTER="${RIG_SNAPSHOT_AFTER:-14}"
mkdir -p "$OUT"
ids() { python3 - "$DEMO/matron.db" "$1" "$2" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); print(db.execute(f"SELECT id FROM {sys.argv[2]} WHERE title=?", (sys.argv[3],)).fetchone()[0])
PY
}
MISSION=$(ids missions 'Ship release 2.4')
PROJECT=$(ids projects 'Release 2.4')
ITEM=$(ids items 'Which retry policy for uploads?')
shot() { # name, env assignments...
  local name=$1; shift
  local args=()
  for kv in "$@"; do args+=(--env "$kv"); done
  rm -f "${OUT:?}/${name:?}.png"
  open -n --env MATRON_APP_SUPPORT_OVERRIDE="$DEMO/mac-home" --env MATRON_DEBUG_SNAPSHOT_AFTER="$AFTER" \
    --env MATRON_DEBUG_WINDOW_SIZE=1280x800 --env MATRON_DEBUG_SNAPSHOT_PATH="$OUT/$name.png" \
    "${args[@]}" "$APP" --args -MatronAppearance "$APPEARANCE"
  for _ in $(seq 1 $((AFTER * 4 + 60))); do [ -f "$OUT/$name.png" ] && break; sleep 0.5; done
  pkill -f "$APP/Contents/MacOS/MatronMac" || true
  sleep 2
  [ -f "$OUT/$name.png" ] && echo "shot $name" || echo "MISSING $name"
}
shot 01-coordinator MATRON_DEBUG_OPEN_NAV=coordinator
shot 02-release-chat MATRON_DEBUG_OPEN_CONVO=mk-release
shot 03-projects MATRON_DEBUG_OPEN_NAV=missions
shot 04-project-page MATRON_DEBUG_OPEN_NAV=missions MATRON_DEBUG_OPEN_PROJECT="$PROJECT"
shot 04b-mission-page MATRON_DEBUG_OPEN_NAV=missions MATRON_DEBUG_OPEN_MISSION="$MISSION"
shot 05-item-thread MATRON_DEBUG_OPEN_NAV=decisions MATRON_DEBUG_OPEN_ITEM="$ITEM"
shot 06-memories MATRON_DEBUG_OPEN_NAV=memories
shot 07-parent-with-subagent MATRON_DEBUG_OPEN_CONVO=mk-auth
ls -la "$OUT"
