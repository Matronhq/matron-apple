#!/bin/zsh
# Mac timeline perf rig. Offline copy of the live store,
# Release -O + DEBUG hooks, no sandbox. Never a second live client: the copied
# session's homeserverURL points at 127.0.0.1:9.
#   mac-perf.sh store              — back up the live store into $RIG/store
#   mac-perf.sh build <worktree> <appdir>
#   mac-perf.sh launch <appdir> [convo]
#   mac-perf.sh run "<cmd>" ...    — one probe command per arg, prints each result
#     RUN_TIMEOUT_TICKS (default 600, 0.5s each) — per-command wait before
#     printing "TIMEOUT: <cmd>" to stderr and moving on; run exits 1 if any
#     command timed out.
#   mac-perf.sh ab <appdirA> <appdirB> <pairs> — interleaved A/B suite of two
#     builds; a timed out run does not stop the suite
# Env: RIG (work dir, default /tmp/mactable); LONG / OTHER — the two
# conversation ids `launch` opens and `ab` switches between (required for
# `launch` and `ab`: a long room and a short one in the copied store).
set -e
RIG=${RIG:-/tmp/mactable}
LIVE="$HOME/Library/Containers/chat.matron.app/Data/Library/Application Support/chat.matron.app"
LONG=${LONG:-}
OTHER=${OTHER:-}
if [[ $1 == launch || $1 == ab ]] && [[ -z $LONG || -z $OTHER ]]; then
  echo "set LONG and OTHER to two conversation ids in the copied store" >&2; exit 2
fi
case $1 in
store)
  mkdir -p "$RIG/store/journal-store" "$RIG/store/sessions"
  for db in "$LIVE/journal-store/"*.sqlite; do
    sqlite3 "$db" ".backup $RIG/store/journal-store/${db:t}"
  done
  sqlite3 "$LIVE/matron-search.sqlite" ".backup $RIG/store/matron-search.sqlite"
  # A signed install keeps its session in the Keychain, not this file; when
  # the file is missing, put any session JSON at the destination by hand
  # (only its user id matters: the server URL below is unreachable).
  jq '.homeserverURL="https://127.0.0.1:9/"' "$LIVE/sessions/matron.journal.session.json" > "$RIG/store/sessions/matron.journal.session.json" ;;
build)
  cd "$2" && xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Release \
    -derivedDataPath "$RIG/dd" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    OTHER_SWIFT_FLAGS='$(inherited) -DDEBUG' CODE_SIGN_ENTITLEMENTS=MatronMac/App/MatronMac.Debug.entitlements \
    build > "$RIG/build.log" 2>&1 || { grep -E ' error: ' "$RIG/build.log" | head; exit 1; }
  mkdir -p "$3" && rm -rf "$3/MatronMac.app" && ditto "$RIG/dd/Build/Products/Release/MatronMac.app" "$3/MatronMac.app" ;;
launch)
  # Matched on the rig's own launch arguments, not on a path: the app dir
  # need not sit under $RIG, and the live /Applications app never carries
  # `-MatronDebug YES -NSAppSleepDisabled YES`, so it is never matched.
  pkill -f "MatronMac.app/Contents/MacOS/MatronMac -MatronDebug YES -NSAppSleepDisabled YES" || true
  sleep 1; rm -f "$RIG/cmd"
  env MATRON_APP_SUPPORT_OVERRIDE="$RIG/store" MATRON_PERF_CMD_FILE="$RIG/cmd" MATRON_PERF_OUT="$RIG/perf.jsonl" \
    MATRON_DEBUG_OPEN_CONVO="${3:-$LONG}" "$2/MatronMac.app/Contents/MacOS/MatronMac" \
    -MatronDebug YES -NSAppSleepDisabled YES > "$RIG/app.log" 2>&1 &
  sleep 20; $0 run "float on" ;;
run)
  shift; touch "$RIG/perf.jsonl"
  ticks=${RUN_TIMEOUT_TICKS:-600}
  failed=0
  for c in "$@"; do
    n=$(wc -l < "$RIG/perf.jsonl"); echo "$c" > "$RIG/cmd"
    got=0
    for ((i = 1; i <= ticks; i++)); do
      [ $(wc -l < "$RIG/perf.jsonl") -gt $n ] && { got=1; break; }
      sleep 0.5
    done
    if [ $got -eq 1 ]; then tail -1 "$RIG/perf.jsonl"
    else echo "TIMEOUT: $c" >&2; failed=1
    fi
    sleep 2
  done
  exit $failed ;;
ab)
  for p in $(seq 1 "$4"); do for app in "$2" "$3"; do
    echo "== pair $p app $app"; $0 launch "$app" $LONG
    $0 run "idle 5" "open $OTHER" "open $LONG" "open $OTHER" "open $LONG" \
      "bottom" "scroll 25 900" "bottom" "scroll 150 300" "bottom" "stream 150 10" "idle 5" || true
  done; done ;;
esac
