# Matron

Native Matrix client for iOS and macOS, bot-first, App Store distributable on both platforms. Built on [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk).

Part of the [Matron](https://github.com/matronhq) ecosystem.

## Status

Pre-alpha. Phase 1 (foundation) in progress — see `docs/superpowers/plans/`.

## Requirements

- macOS 14+
- Xcode 16+
- A Matrix homeserver — recommend [matron-server](https://github.com/matronhq/matron-server) provisioned via [dev-boxer](https://github.com/matronhq/dev-boxer).

## Building

```bash
xcodegen generate
open Matron.xcodeproj
```

- For iPhone/iPad: select the `Matron` scheme, choose an iOS 17+ simulator or device, build & run.
- For macOS: select the `MatronMac` scheme, build & run on the host (macOS 14+).

## Tests

```bash
# iOS
xcodebuild test -workspace Matron.xcworkspace -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 15'

# macOS
xcodebuild test -workspace Matron.xcworkspace -scheme MatronMac -destination 'platform=macOS'
```

## Debugging

Verbose diagnostic logs (timeline snapshots, paginate lifecycle, scroll triggers, etc.) are gated behind `MatronDebug.enabled` so they stay in the source as living documentation of the data flow but cost nothing in shipped builds. Call sites use `Logger.diag(...)` instead of `Logger.notice(...)`. To turn them on for a session:

```bash
defaults write chat.matron.MatronMac MatronDebug -bool YES   # Mac
defaults write chat.matron.app MatronDebug -bool YES         # iOS sim
# then relaunch the app
```

Then read with `log show --last 5m --predicate 'subsystem == "chat.matron"' --style compact`. SDK-side Rust traces (matrix-rust-sdk's own logs) live at `~/Library/Caches/matron-sdk-trace/` on Mac and inside the iOS sim's app data dir. See `MatronShared/Sources/Models/MatronDebug.swift` for the helper and toggle internals.

## License

AGPL-3.0 with commercial licensing available by arrangement. See `LICENSE`, `NOTICE`, and `CONTRIBUTING.md`.

## Contributing

External contributions require a signed CLA — see `CONTRIBUTING.md` and `.cla.md`. The `cla-assistant` GitHub bot prompts for signature on first PR.

## Documentation

- Design spec: `docs/superpowers/specs/2026-05-02-matron-ios-design.md`
- Implementation plans: `docs/superpowers/plans/`
