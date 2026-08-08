# Matron

Matron turns the [Claude Code](https://claude.com/claude-code) and Codex sessions running on your machines into chats you can follow from anywhere. This repo is the **iPhone and Mac client** — native SwiftUI, one shared Swift package behind both apps.

Watch an agent work in real time: streaming replies, tool-call and diff cards, live terminal output, and inline prompts you can answer from the lock screen. Talk back with messages, slash commands (with autocomplete), file and photo attachments, and voice notes. Search your whole history, follow sub-agents in their own sub-chats, and keep an eye on context and usage meters.

Learn more at [matron.chat](https://matron.chat).

## Part of the Matron ecosystem

| Project | Description |
| --- | --- |
| **matron-apple** | iPhone + Mac client (this repo) |
| [matron-journal](https://github.com/Matronhq/matron-journal) | Self-hosted sync server (Node + SQLite) |
| [matron-bridge](https://github.com/Matronhq/matron-bridge) | Runs beside your agent CLI and publishes to the journal |
| [matron-android](https://github.com/Matronhq/matron-android) | Android client (Kotlin + Compose) |
| [matron-desktop](https://github.com/Matronhq/matron-desktop) | Windows / Linux desktop client |
| [matron-web](https://github.com/Matronhq/matron-web) | Browser client |
| [dev-boxer](https://github.com/Matronhq/dev-boxer) | One-command Ubuntu 24.04 agent box |

## Status

Beta. Both apps (v1.0.3) are in TestFlight — see [matron.chat](https://matron.chat) to join. There is no hosted Matron service: you point the app at your own matron-journal server.

## Requirements

- macOS 15+ (the Mac app's deployment floor; also the build host)
- Xcode 16+
- iOS 18+ iPhone or simulator (iPad is not a supported device family in v1)
- A matron-journal server you run yourself — see
  [matron-journal](https://github.com/Matronhq/matron-journal), or a local
  checkout for development (below).

## Building

```bash
xcodegen generate
open Matron.xcodeproj
```

- For iPhone: select the `Matron` scheme, choose an iOS 18+ simulator or device, build & run.
- For macOS: select the `MatronMac` scheme, build & run on the host (macOS 15+).

Both apps share the bundle ID `chat.matron.app` (one App Store Connect
record via universal purchase, one APNs topic). To ship a TestFlight
build of either or both apps, run `scripts/testflight-upload.sh ios|mac|all`
— see the script header for App Store Connect API-key auth and how build
numbers are derived.

## Signing in

On your first device, enter your server URL, username, and password — an
admin creates the account on the server with `matron-admin user add` (see
"Local dev server" below).

Additional devices don't need the password. On a signed-in device, open
Settings → Link a Device to show a QR code and a short link code. On the
new device, choose "Scan QR code", or tap "Have a link code?" and type the
code (pasting the full `matron://link?…` link works too). Approve the
request on the signed-in device to finish. Review and revoke devices under
Settings → Manage Devices.

## Local dev server

Clone `matron-journal` as a sibling checkout, then run it against a scratch
database:

```bash
cd .. && git clone https://github.com/matronhq/matron-journal.git
cd matron-journal && npm install
MATRON_DB=/tmp/matron-dev.sqlite MATRON_PORT=9810 node src/server.js
```

In another shell, create a user (and, if you want the bridge to have
something to post as, an agent):

```bash
echo 'a-password' | MATRON_DB=/tmp/matron-dev.sqlite node bin/matron-admin.js user add dan --password-stdin
MATRON_DB=/tmp/matron-dev.sqlite node bin/matron-admin.js agent add dan dev-2
```

Then sign in from the app with that username/password against
`http://127.0.0.1:9810`.

## Tests

```bash
# SPM unit suite (MatronJournal, store, sync engine, view models, etc.).
# The env var skips pixel-comparison snapshot tests — they're meant for
# local visual review, and CI skips them too (.github/workflows/ci.yml).
MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared

# iOS build — the destination CI uses; any installed iOS 18+ simulator name works
xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# Mac unit tests (snapshot tests need a locally-committed baseline; skip them
# in CI/headless runs with TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1)
TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests

# Integration scenario: boots a real matron-journal server subprocess and
# drives sign-in → snapshot → live send/receive against it
tests/integration/scenarios/journal-live-sdk.sh
```

The integration scenario resolves the server checkout at `$HOME/Dev/matron-journal`
by default; override with `MATRON_JOURNAL_PATH=/path/to/checkout`. It resolves
`node` via the shell's PATH first; override with `MATRON_NODE_PATH=/path/to/node`
if that fails (e.g. a non-interactive shell without nvm sourced).

## Architecture & reliability model

The app keeps a local GRDB mirror of the journal and renders entirely from
it; a single sync engine applies server frames to the mirror behind an
integer cursor that only advances after a committed write. Every failure
mode — dropped socket, backgrounded app, server restart — converges the same
way: reconnect and resume from the stored cursor. The app never gets stuck
in a state that needs a restart to recover.

## Debugging

Verbose diagnostic logs (timeline snapshots, paginate lifecycle, scroll triggers, etc.) are gated behind `MatronDebug.enabled` so they stay in the source as living documentation of the data flow but cost nothing in shipped builds. Call sites use `Logger.diag(...)` instead of `Logger.notice(...)`. To turn them on for a session:

```bash
defaults write chat.matron.app MatronDebug -bool YES   # domain = bundle id, same on iOS sim and Mac
# then relaunch the app
```

Then read with `log show --last 5m --predicate 'subsystem == "chat.matron"' --style compact`. See `MatronShared/Sources/Models/MatronDebug.swift` for the helper and toggle internals.

## Push notifications

The client registers its APNs token with the server (`POST /push/register`,
`JournalPushService`/`JournalAPI.registerPush`) and unregisters
(`apns_token: null`) on sign-out. The `environment` field is derived from the
build configuration, not hand-picked: Debug builds register as `sandbox`
(Xcode-run builds always use the sandbox APNs environment), release builds
register as `prod`.

## License

AGPL-3.0 with commercial licensing available by arrangement. See `LICENSE`, `NOTICE`, and `CONTRIBUTING.md`.

## Contributing

External contributions require a signed CLA — see `CONTRIBUTING.md` and `.cla.md`. The `cla-assistant` GitHub bot prompts for signature on first PR.

## Documentation

- Client design spec: `docs/superpowers/specs/2026-07-11-matron-journal-client-design.md`
- Server protocol spec: [matron-protocol-design.md](https://github.com/Matronhq/matron-journal/blob/master/docs/superpowers/specs/2026-07-10-matron-protocol-design.md) (matron-journal repo)
- Matrix-era history lives in `docs/superpowers/plans/`.
