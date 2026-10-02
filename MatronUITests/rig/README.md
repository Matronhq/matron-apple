# Marketing screenshot rig

Seeds a throwaway local matron-journal with demo conversations and drives
`MarketingScreenshots.swift` against it. Everything disposable lives in
`/tmp/matron-demo`; these are the master copies (the /tmp ones vanish on
reboot — copy them out before running).

```bash
mkdir -p /tmp/matron-demo
cp seed.mjs responder.mjs rebuild-rig.sh /tmp/matron-demo/
ln -sf <a node_modules containing 'ws'> /tmp/matron-demo/node_modules
# Build the iOS app for testing first (rebuild-rig.sh installs it):
#   xcodebuild build-for-testing -project Matron.xcodeproj -scheme Matron \
#     -destination 'id=<sim udid>' -derivedDataPath /tmp/matron-dd
/tmp/matron-demo/rebuild-rig.sh
xcrun simctl ui <sim udid> appearance dark
xcrun simctl status_bar <sim udid> override --time "9:41" --batteryState charged --batteryLevel 100
xcodebuild test-without-building ... -only-testing:MatronUITests/MarketingScreenshots
```

Notes that cost time to learn:
- Agent `publish` types are enumerated server-side ('rich' no longer exists);
  text payloads use `{body}` not `{text}`.
- `session_state` must be running|waiting|done|archived.
- The agent-chat consent card cannot be forged via publish — seed a real
  `agent_invite` (server-minted card, which is what the shot should show).
- Chat rows bake the tag letter into the a11y label; match titles by suffix.
- The Mac app self-captures via MATRON_DEBUG_SNAPSHOT_AFTER (DEBUG builds,
  no TCC), but macOS 26 glass chrome renders as undefined layer content —
  full-window Mac shots still need a manual ⇧⌘4 capture of the staged app:
  MATRON_APP_SUPPORT_OVERRIDE=/tmp/matron-demo-home \
  MATRON_DEBUG_OPEN_CONVO=demo-fix-flaky-upload \
  <Debug MatronMac binary> -MatronAppearance dark

## Marketing rig (App Store screenshots, 1.2.0 onwards)

`rig/marketing/` is the current screenshot rig: a throwaway local journal
with invented web-app work for a demo user, the iOS app signed in to it on
an iPhone 17 Pro Max simulator (1320×2868), and the Debug Mac app pointed
at a demo home. `MarketingScreenshots.swift` drives the iOS set.

```bash
RIG_UDID=$(xcrun simctl list devices available | grep -m1 -E '^ +iPhone 17 Pro Max \(' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
# A journal checkout on master with node_modules (npm ci); ~/Dev/matron-journal
# may be parked on a branch — export master to /tmp and npm ci there.
export RIG_JOURNAL=/tmp/matron-journal-master
xcodebuild build-for-testing -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-shots-dd
xcodebuild build -project Matron.xcodeproj -scheme MatronMac -configuration Debug \
  -derivedDataPath /tmp/matron-shots-mac-dd
RIG_UDID=$RIG_UDID MatronUITests/rig/marketing/rig.sh          # seed + install + sign in
xcodebuild test-without-building -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-shots-dd \
  -only-testing:MatronUITests/MarketingScreenshots            # → /tmp/shots-out (~7 min)
# (TEST_RUNNER_SCREENSHOT_DIR=<dir> on that command redirects the PNGs.)
MatronUITests/rig/marketing/mac-shots.sh /tmp/shots-out-mac   # → 2560×1600 PNGs
```

- `RIG_CLOCK` (default `9:41`): the status-bar time; `backdate.py` places
  every message, item and milestone before it. By the afternoon the
  relative labels ("7h ago") grow; `RIG_CLOCK=now` uses the real clock
  instead so both agree.
- The journal runs on 9810 and is tracked by `$DEMO/journal.pid`; the rig
  never `pkill`s by name (other local journals share this machine). Stop it
  with `kill $(cat /tmp/shots-demo/journal.pid /tmp/shots-demo/responder.pid)`.
- Mac captures: `DebugSnapshot.swift` (DEBUG only) sizes the window
  (`MATRON_DEBUG_WINDOW_SIZE`) and captures it through the window server
  (`CGWindowListCreateImage` on its own window, no TCC grant) after
  `MATRON_DEBUG_SNAPSHOT_AFTER` seconds; `MATRON_DEBUG_OPEN_CONVO` /
  `MATRON_DEBUG_OPEN_NAV` / `MATRON_DEBUG_OPEN_MISSION` /
  `MATRON_DEBUG_OPEN_ITEM` pick the pane. Launch through `open -n --env …`:
  a binary started straight from a shell gets no windows on macOS 26.
- `MATRON_DEBUG_OPEN_PROJECT=<project id>` lands on a project page.
- Known product gaps visible in the set (flagged to Dan 2026-10-02):
  find-in-chat does not highlight the matched word; the iOS mission page
  title is only "#N"; raw model ids ("claude-fable-5-1") show in the
  session sheet footer and under a sub-chat title.

## Timeline rig (UIKit timeline UI tests + perf gate)

```bash
cp seed.mjs seed-timeline.mjs responder.mjs rebuild-rig.sh /tmp/matron-demo/
cp perf-gate.sh /tmp/matron-demo/ 2>/dev/null || true   # perf gate (plan Task 29)
ln -sfn ~/Dev/matron-journal/node_modules /tmp/matron-demo/node_modules   # provides 'ws'
RIG_UDID=$(xcrun simctl list devices available | grep -m1 -E '^ +iPhone 17 \(' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
xcrun simctl boot "$RIG_UDID" || true
# Signed (the default): CODE_SIGNING_ALLOWED=NO drops the app-group
# entitlement, so rebuild-rig.sh finds no group container to inject into.
xcodebuild build-for-testing -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd
# If ~/Dev/matron-journal is parked on a feature branch, export master:
#   git -C ~/Dev/matron-journal archive origin/master | tar -x -C /tmp/matron-journal-rig
#   ln -s ~/Dev/matron-journal/node_modules /tmp/matron-journal-rig/node_modules
# and add RIG_JOURNAL=/tmp/matron-journal-rig below.
RIG_TIMELINE=1 RIG_UDID=$RIG_UDID /tmp/matron-demo/rebuild-rig.sh
export TEST_RUNNER_RIG_AGENT_TOKEN=$(sed -n 's/.*token: *\([^ ]*\).*/\1/p' /tmp/matron-demo/agent-mac-studio.txt | head -1)
xcodebuild test-without-building -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd \
  -only-testing:MatronUITests/ChatTimelineUITests
```

Rebuild before every UI-test run: the tests send messages and stream
replies, and the jump test assumes message 180 is the newest own message.
Run with `test-without-building` against the rig's own build: a plain
`xcodebuild test` (or `scripts/ios-test.sh`, which passes
`CODE_SIGNING_ALLOWED=NO`) reinstalls an app without the app group, and
the injected session is gone. With the rig down every test skips.
Perf gate (spec §4): after `rebuild-rig.sh`, from the repo
`RIG_UDID=$RIG_UDID MatronUITests/rig/perf-gate.sh` (Release + probe,
signed, 3 × 15 s at 25 and 150 pt/frame, then one sampled profile run per
speed). Results land in `/tmp/matron-perf-uikit`. There is no SwiftUI
baseline to measure any more: that timeline was removed on 2026-09-28, and
its numbers are in the spec, section 1.
Stop the rig afterwards: `pkill -f 'node src/server.js'; pkill -f 'node responder.mjs'`.
