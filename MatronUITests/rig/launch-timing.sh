#!/usr/bin/env bash
# Launch timing rig: times cold launches and returns to the foreground of
# the app launch-rig.sh installed. Before each one the journal gets a
# backlog (launch-backlog.mjs): comments on open items and one new question.
# Reads the launch marks and the "For you refresh" lines the app writes to
# its diagnostic file.
#
# Build Release with 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited)
# MATRON_PERF_PROBE', signed, as perf-gate.sh does.
#
#   cold    kill the app, file the backlog, launch
#   resume  background the app, stall its socket, file the backlog, return
#
# Run: RIG_UDID=<sim> launch-timing.sh [cold|resume] [runs]
set -euo pipefail
DIR="${RIG_DIR:-/tmp/matron-launch-rig}"
UDID="${RIG_UDID:?set RIG_UDID}"
MODE="${1:-cold}"; RUNS="${2:-5}"
export RIG_DIR="$DIR" RIG_PORT="${RIG_PORT:-9820}"
DATA=$(xcrun simctl get_app_container "$UDID" chat.matron.app data)
LOG="$DATA/Documents/matron-diag.log"
# The build must carry MATRON_PERF_PROBE (see perf-gate.sh): without the
# variable the notification alert keeps the scene inactive.
launch() { SIMCTL_CHILD_MATRON_PERF_NO_PUSH_PROMPT=1 xcrun simctl launch "$UDID" chat.matron.app "$@" >/dev/null; }

for run in $(seq 1 "$RUNS"); do
  if [[ "$MODE" == "cold" ]]; then
    xcrun simctl terminate "$UDID" chat.matron.app 2>/dev/null || true
    sleep 1
    (cd "$DIR" && node launch-backlog.mjs "cold-$run" >/dev/null)
    SKIP=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    launch -sync.scope for_you
    sleep "${RIG_SETTLE_S:-20}"
    python3 - "$LOG" "$run" "$SKIP" <<'PYEOF'
import re, sys
marks = {}
for line in open(sys.argv[1], errors='replace').readlines()[int(sys.argv[3]):]:
    m = re.search(r'launch (\w+) ([0-9.]+) s', line)
    if m: marks.setdefault(m.group(1), float(m.group(2)))
order = ['firstListPaint', 'forYouCached', 'connected', 'forYouFresh', 'catchUpComplete']
print(f"cold {sys.argv[2]}: " + '  '.join(f"{k}={marks[k]:.2f}" if k in marks else f"{k}=-" for k in order))
PYEOF
  else
    launch -sync.scope for_you
    sleep 8
    xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
    sleep "${RIG_AWAY_S:-20}"
    pkill -USR1 -f "$DIR/latency-proxy.mjs" || true
    (cd "$DIR" && node launch-backlog.mjs "resume-$run" >/dev/null)
    SKIP=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    launch
    sleep "${RIG_SETTLE_S:-20}"
    python3 - "$LOG" "$run" "$SKIP" "$DIR/proxy.log" <<'PYEOF'
import re, sys
from datetime import datetime, timezone
t0 = None; fresh = None
for line in open(sys.argv[1], errors='replace').readlines()[int(sys.argv[3]):]:
    m = re.match(r'(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) (.*)', line)
    if not m: continue
    t = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S.%f')
    if m.group(2).startswith('foreground') and t0 is None: t0 = t
    elif t0 is not None and fresh is None and m.group(2).startswith('For you refresh ok'): fresh = t
# From the proxy's request log: the item refetches the replayed markers
# caused, and when the last of them went out.
refetches = []
if t0:
    start = t0.astimezone(timezone.utc)
    for line in open(sys.argv[4], errors='replace'):
        m = re.match(r'(\S+Z) GET /items/\S+', line)
        if not m: continue
        t = datetime.fromisoformat(m.group(1).replace('Z', '+00:00'))
        if t >= start: refetches.append((t - start).total_seconds())
print(f"resume {sys.argv[2]}: foreground -> For you fresh = " + (f"{(fresh - t0).total_seconds():.2f} s" if t0 and fresh else '-')
      + (f"; {len(refetches)} item refetches, last sent at {max(refetches):.2f} s" if refetches else ''))
PYEOF
  fi
done
