#!/bin/zsh
# Mac timeline perf rig (spec 2026-09-28 §1). Offline copy of the live store,
# Release -O + DEBUG hooks, no sandbox. Never a second live client: the copied
# session's homeserverURL points at 127.0.0.1:9.
#   mac-perf.sh store              — back up the live store into $RIG/store
#   mac-perf.sh build <worktree> <appdir>
#   mac-perf.sh launch <appdir> [convo] [flag on|off]
#   mac-perf.sh run "<cmd>" ...    — one probe command per arg, prints each result
#   mac-perf.sh ab <appdir> <pairs> — interleaved flag off/on suite
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
  if [ "$4" = on ]; then defaults write chat.matron.app chat.timeline.appkit -bool YES
  else defaults write chat.matron.app chat.timeline.appkit -bool NO; fi
  env MATRON_APP_SUPPORT_OVERRIDE=$RIG/store MATRON_PERF_CMD_FILE=$RIG/cmd MATRON_PERF_OUT=$RIG/perf.jsonl \
    MATRON_DEBUG_OPEN_CONVO=${3:-$LONG} $2/MatronMac.app/Contents/MacOS/MatronMac \
    -MatronDebug YES -NSAppSleepDisabled YES > $RIG/app.log 2>&1 &
  sleep 20; $0 run "float on" ;;
run)
  shift; touch $RIG/perf.jsonl
  for c in "$@"; do
    n=$(wc -l < $RIG/perf.jsonl); echo "$c" > $RIG/cmd
    for i in {1..600}; do [ $(wc -l < $RIG/perf.jsonl) -gt $n ] && break; sleep 0.5; done
    tail -1 $RIG/perf.jsonl; sleep 2
  done ;;
ab)
  for p in $(seq 1 $3); do for flag in off on; do
    echo "== pair $p flag $flag"; $0 launch $2 $LONG $flag
    $0 run "idle 5" "open $OTHER" "open $LONG" "open $OTHER" "open $LONG" \
      "bottom" "scroll 25 900" "bottom" "scroll 150 300" "bottom" "stream 150 10" "idle 5"
  done; done ;;
esac
