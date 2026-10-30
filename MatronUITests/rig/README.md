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

Fleet shots (projects, a mission page, a For you question, routines,
memories): add `seed-fleet.mjs` to the copy, rebuild with `RIG_FLEET=1`
(it also sets a Coordinator, which adds a tab), and run
`-only-testing:MatronUITests/MarketingScreenshots/testCaptureFleet`. On an
iPhone 17 Pro Max the PNGs come out at 1320 × 2868, the size the site uses.
`RIG_DD` points the rig at another derived-data folder.

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

## Item thread rig (native item thread UI tests)

The same steps as the timeline rig, with `seed-item.mjs` copied too and
`RIG_ITEM=1` on `rebuild-rig.sh`. It files one long question on the demo
journal: paragraphs, nested and numbered lists, wide tables, a code block,
pictures, a reply from the user and a comment with buttons.

```bash
cp seed.mjs seed-item.mjs responder.mjs rebuild-rig.sh /tmp/matron-demo/
RIG_ITEM=1 RIG_UDID=$RIG_UDID /tmp/matron-demo/rebuild-rig.sh
xcodebuild test-without-building -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd \
  -only-testing:MatronUITests/ItemThreadUITests
```

`test_captureBothThreads` writes pictures of the same steps in the native
thread and the SwiftUI one to `SCREENSHOT_DIR` (default
`/tmp/matron-item-thread`), to compare by eye.

## Image viewer rig (fullscreen viewer swipe UI tests)

The same steps again, with `seed-photos.mjs` copied too and `RIG_PHOTOS=1`
on `rebuild-rig.sh`. It adds one chat, "Photo swipe check", holding four
pictures.

```bash
cp seed.mjs seed-photos.mjs responder.mjs rebuild-rig.sh /tmp/matron-demo/
RIG_PHOTOS=1 RIG_UDID=$RIG_UDID /tmp/matron-demo/rebuild-rig.sh
xcodebuild test-without-building -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd \
  -only-testing:MatronUITests/ImageViewerUITests
```

The tests drag with `press(forDuration:thenDragTo:withVelocity:...)`
rather than `swipeLeft()`: `swipeLeft()` always travels half the screen,
so it never exercises the short thumb flick the viewer has to accept.

## Coordinator rig (Back out of the Coordinator UI tests)

The same steps again, with `seed-coordinator.mjs` copied too and
`RIG_COORDINATOR=1` on `rebuild-rig.sh`. It adds a Coordinator
conversation, sets it as the demo user's Coordinator, and links to it from
"Fix the flaky upload test". The tests skip unless
`TEST_RUNNER_RIG_COORDINATOR=1` says this seed is there.

```bash
cp seed.mjs seed-coordinator.mjs responder.mjs rebuild-rig.sh /tmp/matron-demo/
RIG_COORDINATOR=1 RIG_UDID=$RIG_UDID /tmp/matron-demo/rebuild-rig.sh
TEST_RUNNER_RIG_COORDINATOR=1 xcodebuild test-without-building -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd \
  -only-testing:MatronUITests/CoordinatorBackUITests
```

To run beside another rig, serve the journal on another port
(`MATRON_PORT`) from copies of the scripts with the port changed, and pass
`TEST_RUNNER_RIG_PORT=<port>`.

## For you rig (scroll smoothness)

The same steps again, with `seed-foryou.mjs` copied too and `RIG_FORYOU=1`
on `rebuild-rig.sh`. It files 80 items that need the user and 240 closed
ones across the demo conversations; every third body is a long report of
about 10 KB.

The simulator reports no hitch metrics, so the app counts them itself:
build Release with the perf probe and install it in place of the test
build's app, then run one test at a time and read the totals from the
app's data container.

```bash
cp seed.mjs seed-foryou.mjs responder.mjs rebuild-rig.sh /tmp/matron-demo/
xcodebuild build -project Matron.xcodeproj -scheme Matron -configuration Release \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd ARCHS=arm64 \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MATRON_PERF_PROBE'
xcodebuild build-for-testing -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd
# Replace the Debug app (a plain cp -R would merge into it).
rm -rf /tmp/matron-dd/Build/Products/Debug-iphonesimulator/Matron.app
cp -R /tmp/matron-dd/Build/Products/Release-iphonesimulator/Matron.app \
  /tmp/matron-dd/Build/Products/Debug-iphonesimulator/
RIG_FORYOU=1 RIG_UDID=$RIG_UDID /tmp/matron-demo/rebuild-rig.sh
TEST_RUNNER_FORYOU_FLICKS=2 xcodebuild test-without-building -project Matron.xcodeproj -scheme Matron \
  -destination "id=$RIG_UDID" -derivedDataPath /tmp/matron-dd \
  -only-testing:MatronUITests/ForYouScrollPerfUITests/test_needsYouFlicksInApp
cat "$(xcrun simctl get_app_container "$RIG_UDID" chat.matron.app data)/tmp/scroll-frames.json"
```

`test_needsYouFlicksInApp` has the app flick the list itself while the
runner sleeps; it is the steadier number. `test_needsYouScroll` and
`test_doneScroll` swipe with the runner, which also covers the shell's
swipe-between-tabs gesture, but the runner's element queries between
swipes stall the main thread too, so compare those runs only with each
other. `xcodebuild` sometimes hangs after the test passes; the totals are
written by then.
