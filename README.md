# Matron

Native client for iOS and macOS that turns a Claude bridge session into a chat
app: sign in, watch an agent's conversations arrive and update live, answer
its prompts inline. Bot-first, App Store distributable on both platforms.
Speaks **matron-journal**, a purpose-built server protocol — no Matrix
dependency.

Part of the [Matron](https://github.com/matronhq) ecosystem.

## Status

Journal-protocol client, live against a real server. Server:
[matronhq/matron-journal](https://github.com/matronhq/matron-journal), running
at `https://chat.example.com` (the Claude bridge dual-posts real agent
traffic there). See `docs/superpowers/specs/2026-07-11-matron-journal-client-design.md`
for the client architecture and `docs/superpowers/plans/` for implementation
history.

## Requirements

- macOS 14+
- Xcode 16+
- A matron-journal server — the hosted one at `https://chat.example.com`, or
  a local checkout for development (see below).

## Architecture & reliability model

The app keeps a local GRDB mirror of the journal and renders entirely from
it; a single sync engine applies server frames to the mirror behind an
integer cursor that only advances after a committed write. Every failure
mode — dropped socket, backgrounded app, server restart — converges the same
way: reconnect and resume from the stored cursor, with no wedge states and no
required app restart.

## Building

```bash
xcodegen generate
open Matron.xcodeproj
```

- For iPhone/iPad: select the `Matron` scheme, choose an iOS 17+ simulator or device, build & run.
- For macOS: select the `MatronMac` scheme, build & run on the host (macOS 14+).

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
MATRON_DB=/tmp/matron-dev.sqlite node bin/matron-admin.js user add dan --password '...'
MATRON_DB=/tmp/matron-dev.sqlite node bin/matron-admin.js agent add dan dev-2
```

Then sign in from the app with that username/password against
`http://127.0.0.1:9810`.

## Tests

```bash
# SPM unit suite (MatronJournal, store, sync engine, view models, etc.)
swift test --package-path MatronShared

# iOS build
xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17'

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

## Debugging

Verbose diagnostic logs (timeline snapshots, paginate lifecycle, scroll triggers, etc.) are gated behind `MatronDebug.enabled` so they stay in the source as living documentation of the data flow but cost nothing in shipped builds. Call sites use `Logger.diag(...)` instead of `Logger.notice(...)`. To turn them on for a session:

```bash
defaults write chat.matron.MatronMac MatronDebug -bool YES   # Mac
defaults write chat.matron.app MatronDebug -bool YES         # iOS sim
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

- Current design spec (matron-journal client): `docs/superpowers/specs/2026-07-11-matron-journal-client-design.md`
- Server protocol spec: `matron-journal/docs/superpowers/specs/2026-07-10-matron-protocol-design.md` (sibling repo)
- Implementation plans, including the Matrix-era history and the journal swap: `docs/superpowers/plans/`
- Earlier Matrix-era design spec (historical, superseded): `docs/superpowers/specs/2026-05-02-matron-ios-design.md`
