#!/usr/bin/env bash
# UIKit timeline performance gate (spec 2026-09-26 §4; plan Task 29).
# Prereq: the rig rebuilt with RIG_TIMELINE=1 on $RIG_UDID (booted iPhone 17).
# Builds Release (-O) with MATRON_PERF_PROBE, SIGNED (an unsigned build drops
# the app group and with it the rig's injected session), installs over the
# rig's app (data kept), runs 3 × 15 s auto-scrolls at 25 and at 150
# pt/frame and checks the targets on their means:
#   25 pt/frame  → mean app CPU ≤ 1.0 s and 0 hitches
#   150 pt/frame → mean ≤ 1 hitch per second
# Then one more run per speed with `sample` on the host, for the main-thread
# profile. Those runs are reported, not gated: `sample` suspends the app
# ~500×/s to walk its stacks, which on this rig multiplied the 150 pt/frame
# hitch rate by ~4 (1.98 → 8.58 hitches/s, same build, Task 29 report).
# The SwiftUI baseline this gate once compared against is gone with the
# SwiftUI timeline (2026-09-28); its numbers are in the spec, §1.
# Env:
#   PERF_SKIP_BUILD=1 — reuse the last build in $DD (e.g. baseline after gate).
#   PERF_PROFILE=0 — skip the sampled profile runs.
#   PERF_SAMPLED_GATE=1 — sample DURING the gated runs instead (the numbers
#     then include sample's own hitches; kept for comparison).
#   PERF_RUNS — runs per speed (default 3; the gate is defined on 3).
#   PERF_REPO — repo checkout to build (default: this script's repo).
#   PERF_OUT — output dir (default /tmp/matron-perf-<variant>).
set -euo pipefail
# Run from the repo (MatronUITests/rig/perf-gate.sh), or set PERF_REPO when
# running the /tmp/matron-demo copy.
REPO="${PERF_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -d "$REPO/Matron.xcodeproj" ] || { echo "no Matron.xcodeproj in $REPO (set PERF_REPO)" >&2; exit 2; }
UDID="${RIG_UDID:?set RIG_UDID to the rig iPhone 17 simulator udid}"
VARIANT=uikit
DD=/tmp/matron-perf-dd
OUT="${PERF_OUT:-/tmp/matron-perf-$VARIANT}"
rm -rf "$OUT" && mkdir -p "$OUT"

if [[ "${PERF_SKIP_BUILD:-0}" != "1" ]]; then
  xcodebuild build -project "$REPO/Matron.xcodeproj" -scheme Matron -configuration Release \
    -destination "id=$UDID" -derivedDataPath "$DD" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MATRON_PERF_PROBE' > "$OUT/build.log" 2>&1 \
    || { tail -30 "$OUT/build.log"; echo "build failed: $OUT/build.log"; exit 1; }
fi
xcrun simctl install "$UDID" "$DD/Build/Products/Release-iphonesimulator/Matron.app"
DATA=$(xcrun simctl get_app_container "$UDID" chat.matron.app data)

run() {
  local pt=$1 i=$2 sampled=$3
  rm -f "$DATA/tmp/timeline-perf.json" "$DATA/tmp/timeline-perf.started"
  local launched pid
  launched=$(SIMCTL_CHILD_MATRON_PERF_AUTOSCROLL_PT="$pt" SIMCTL_CHILD_MATRON_PERF_DURATION_S=15 \
    SIMCTL_CHILD_MATRON_PERF_OPEN_CONVO=perf-timeline \
    xcrun simctl launch --terminate-running-process "$UDID" chat.matron.app)
  pid=${launched##*: }
  for _ in $(seq 1 160); do [ -f "$DATA/tmp/timeline-perf.started" ] && break; sleep 0.25; done
  [ -f "$DATA/tmp/timeline-perf.started" ] || { echo "probe never started ($VARIANT pt=$pt run=$i)"; exit 1; }
  local sampler=""
  if [[ "$sampled" == "1" ]]; then
    sample "$pid" 15 -file "$OUT/sample-$pt-$i.txt" > /dev/null 2>&1 &
    sampler=$!
  fi
  for _ in $(seq 1 120); do [ -f "$DATA/tmp/timeline-perf.json" ] && break; sleep 0.25; done
  [ -n "$sampler" ] && { wait "$sampler" || true; }
  [ -f "$DATA/tmp/timeline-perf.json" ] || { echo "probe never finished ($VARIANT pt=$pt run=$i)"; exit 1; }
  cp "$DATA/tmp/timeline-perf.json" "$OUT/run-$pt-$i.json"
  echo "$VARIANT pt=$pt run=$i $(cat "$OUT/run-$pt-$i.json")"
}

for pt in 25 150; do
  for i in $(seq 1 "${PERF_RUNS:-3}"); do run "$pt" "$i" "${PERF_SAMPLED_GATE:-0}"; done
  if [[ "${PERF_PROFILE:-1}" == "1" && "${PERF_SAMPLED_GATE:-0}" != "1" ]]; then run "$pt" profile 1; fi
done
xcrun simctl terminate "$UDID" chat.matron.app 2>/dev/null || true

python3 - "$OUT" "$VARIANT" <<'PYEOF'
import glob, json, os, re, sys
out, variant = sys.argv[1], sys.argv[2]
def runs(pt):
    return [json.load(open(p)) for p in sorted(glob.glob(os.path.join(out, f"run-{pt}-*.json")))
            if not p.endswith("-profile.json")]
def main_busy(path):
    # `sample` call graph: the main thread's root line carries its total
    # sample count; the run loop's mach_msg wait (__CFRunLoopServiceMachPort)
    # is idle. Busy = total - idle. `sample` asks for 1 ms but lands ~1.9 ms
    # apart on the simulator, so busy ms = busy share of the 15 s window.
    pat = re.compile(r"^([ +!:|]*)(\d+) (.+?)  \(in ")
    total = idle = None; stack = []
    for line in open(path, errors="replace"):
        if re.match(r"\s*\d+ Thread_\d+", line):
            if total is not None: break
            if "Main Thread" in line or "com.apple.main-thread" in line:
                total, idle = int(line.split()[0]), 0
            continue
        if total is None: continue
        m = pat.match(line)
        if not m: continue
        depth, count, sym = len(m.group(1)), int(m.group(2)), m.group(3)
        while stack and stack[-1][0] >= depth: stack.pop()
        if sym.startswith("__CFRunLoopServiceMachPort") and not any(s.startswith("__CFRunLoopServiceMachPort") for _, s in stack):
            idle += count
        stack.append((depth, sym))
    return None if total is None else (total, total - idle)
for p in sorted(glob.glob(os.path.join(out, "sample-*.txt"))):
    r = main_busy(p)
    if r: print(f"{variant} {os.path.basename(p)}: main-thread samples {r[0]}, busy {r[1]} (~{r[1] / r[0] * 15000:.0f} ms of 15 s)")
slow, fast = runs(25), runs(150)
cpu = sum(r["cpuSeconds"] for r in slow) / len(slow)
slow_hitches = sum(r["hitches"] for r in slow) / len(slow)
slow_rate = sum(r["hitchMilliseconds"] / r["seconds"] for r in slow) / len(slow)
fast_rate = sum(r["hitches"] / r["seconds"] for r in fast) / len(fast)
fast_ms = sum(r["hitchMilliseconds"] / r["seconds"] for r in fast) / len(fast)
fast_cpu = sum(r["cpuSeconds"] for r in fast) / len(fast)
print(f"{variant} 25 pt/frame : mean CPU {cpu:.2f} s (target ≤ 1.00), mean hitches {slow_hitches:.2f} (target 0), {slow_rate:.1f} hitch ms/s")
print(f"{variant} 150 pt/frame: mean {fast_rate:.2f} hitches/s (target ≤ 1.00), {fast_ms:.1f} hitch ms/s, mean CPU {fast_cpu:.2f} s")
for pt in (25, 150):
    p = os.path.join(out, f"run-{pt}-profile.json")
    if os.path.exists(p):
        r = json.load(open(p))
        print(f"{variant} {pt} pt/frame profile run (sampled, not gated): CPU {r['cpuSeconds']:.2f} s, "
              f"{r['hitches']} hitches, {r['hitchMilliseconds'] / r['seconds']:.1f} hitch ms/s")
print(f"main-thread samples: {out}/sample-*.txt")
if variant != "uikit":
    print("BASELINE (not gated)")
    sys.exit(0)
ok = cpu <= 1.0 and slow_hitches == 0 and fast_rate <= 1.0
print("PERF GATE", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PYEOF
