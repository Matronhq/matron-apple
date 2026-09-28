#!/bin/zsh
# Mac timeline perf rig (spec 2026-09-28 §1). Offline copy of the live store,
# Release -O + DEBUG hooks, no sandbox. Never a second live client: the copied
# session's homeserverURL points at 127.0.0.1:9.
#   mac-perf.sh store              — back up the live store into $RIG/store
#   mac-perf.sh build <worktree> <appdir>
#   mac-perf.sh launch <appdir> [convo] [flag on|off]
#   mac-perf.sh run "<cmd>" ...    — one probe command per arg, prints each result
#     RUN_TIMEOUT_TICKS (default 600, 0.5s each) — per-command wait before
#     printing "TIMEOUT: <cmd>" to stderr and moving on; run exits 1 if any
#     command timed out.
#   mac-perf.sh ab <appdir> <pairs> — interleaved flag off/on suite; a timed
#     out run does not stop the suite
set -e
RIG=${RIG:-/tmp/mactable}
LIVE="$HOME/Library/Containers/chat.matron.app/Data/Library/Application Support/chat.matron.app"
LONG=${LONG:-3a258fa0-ee0a-43e2-9f01-a30db5695e39}
OTHER=${OTHER:-5ee1ed62-1b55-4968-b788-a089ff0b0e28}
case $1 in
store)
  mkdir -p $RIG/store/journal-store $RIG/store/sessions
  sqlite3 "$LIVE/journal-store/dan.sqlite" ".backup $RIG/store/journal-store/dan.sqlite"
  sqlite3 "$LIVE/matron-search.sqlite" ".backup $RIG/store/matron-search.sqlite"
  jq '.homeserverURL="https://127.0.0.1:9/"' "$LIVE/sessions/matron.journal.session.json" > $RIG/store/sessions/matron.journal.session.json ;;
build)
  cd $2 && xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Release \
    -derivedDataPath $RIG/dd ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    OTHER_SWIFT_FLAGS='$(inherited) -DDEBUG' CODE_SIGN_ENTITLEMENTS=MatronMac/App/MatronMac.Debug.entitlements \
    build > $RIG/build.log 2>&1 || { grep -E ' error: ' $RIG/build.log | head; exit 1; }
  mkdir -p $3 && rm -rf $3/MatronMac.app && ditto $RIG/dd/Build/Products/Release/MatronMac.app $3/MatronMac.app ;;
launch)
  pkill -f "$RIG/.*/MatronMac.app/Contents/MacOS/MatronMac" || true; sleep 1; rm -f $RIG/cmd
  # Flag by launch argument (NSArgumentDomain), never `defaults write`: with the
  # live app's sandbox container present, `defaults write chat.matron.app`
  # lands in ~/Library/Containers/chat.matron.app/.../Preferences (the LIVE
  # app's plist), while this unsandboxed rig app reads
  # ~/Library/Preferences/chat.matron.app.plist — so the write never reached it.
  if [ "$4" = on ]; then flagarg=YES; else flagarg=NO; fi
  env MATRON_APP_SUPPORT_OVERRIDE=$RIG/store MATRON_PERF_CMD_FILE=$RIG/cmd MATRON_PERF_OUT=$RIG/perf.jsonl \
    MATRON_DEBUG_OPEN_CONVO=${3:-$LONG} $2/MatronMac.app/Contents/MacOS/MatronMac \
    -MatronDebug YES -NSAppSleepDisabled YES -chat.timeline.appkit $flagarg > $RIG/app.log 2>&1 &
  sleep 20; $0 run "float on" ;;
run)
  shift; touch $RIG/perf.jsonl
  ticks=${RUN_TIMEOUT_TICKS:-600}
  failed=0
  for c in "$@"; do
    n=$(wc -l < $RIG/perf.jsonl); echo "$c" > $RIG/cmd
    got=0
    for ((i = 1; i <= ticks; i++)); do
      [ $(wc -l < $RIG/perf.jsonl) -gt $n ] && { got=1; break; }
      sleep 0.5
    done
    if [ $got -eq 1 ]; then tail -1 $RIG/perf.jsonl
    else echo "TIMEOUT: $c" >&2; failed=1
    fi
    sleep 2
  done
  exit $failed ;;
ab)
  for p in $(seq 1 $3); do for flag in off on; do
    echo "== pair $p flag $flag"; $0 launch $2 $LONG $flag
    $0 run "idle 5" "open $OTHER" "open $LONG" "open $OTHER" "open $LONG" \
      "bottom" "scroll 25 900" "bottom" "scroll 150 300" "bottom" "stream 150 10" "idle 5" || true
  done; done ;;
esac
