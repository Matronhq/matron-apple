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
