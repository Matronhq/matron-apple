# Matron

Matron is a chat system for talking to [Claude Code](https://claude.com/claude-code) agents from your phone, desktop, or browser. This repo is the **iOS and macOS client** — a native, bot-first Matrix client, App Store distributable on both platforms, built on [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk). The "bots" it chats with are Claude Code sessions: [claude-matrix-bridge](https://github.com/Matronhq/claude-matrix-bridge) runs them on your dev box and bridges them to Matrix.

## Part of the Matron ecosystem

| Project | Description |
| --- | --- |
| **matron-iOS-app** | iOS + macOS client (this repo) |
| [matron-journal](https://github.com/Matronhq/matron-journal) | Sync server |
| [claude-matrix-bridge](https://github.com/Matronhq/claude-matrix-bridge) | Runs Claude Code sessions and bridges them |
| [matron-desktop](https://github.com/Matronhq/matron-desktop) | Desktop client |
| [matron-web](https://github.com/Matronhq/matron-web) | Web client |
| [matron-server](https://github.com/Matronhq/matron-server) | Matrix homeserver distribution |
| [dev-boxer](https://github.com/Matronhq/dev-boxer) | One-command dev environment setup |

## Status

Pre-alpha. Phase 1 (foundation) in progress — see `docs/superpowers/plans/`.

## Requirements

- macOS 14+
- Xcode 16+
- A Matrix homeserver — recommend [matron-server](https://github.com/Matronhq/matron-server) provisioned via [dev-boxer](https://github.com/Matronhq/dev-boxer).

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
