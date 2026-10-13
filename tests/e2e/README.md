# iOS smoke tests (tester.army e2e)

AI-assisted smoke tests for the iPhone app, run on a simulator before each
App Store submission. They use [e2e](https://e2e.tester.army/docs/) (tester.army),
which mixes deterministic locators with model-driven steps (`agent.act`,
`agent.assert`) and replays passing agent steps from a local cache.

The Mac app is not covered: e2e drives iOS simulators and Android emulators
only. MatronMacUITests stays the route for the Mac.

## Run

```bash
scripts/e2e-smoke.sh                  # build, rebuild the rig, run everything
scripts/e2e-smoke.sh --grep Projects  # one test
E2E_SKIP_BUILD=1 scripts/e2e-smoke.sh # reuse the last simulator build
```

Needs Node 22.12+, Xcode with an iOS simulator runtime, a `matron-journal`
checkout at `~/Dev/matron-journal` (override with `E2E_JOURNAL`, run
`npm install` in it once), and an Anthropic API key in `ANTHROPIC_API_KEY`
or `~/.config/matron-e2e/anthropic.key`. The model defaults to
`claude-sonnet-5-5`; set `E2E_MODEL` to change it.

Results land in `tests/e2e/.e2e/` (`summary.md`, `junit.xml`, per-attempt
screenshots under `artifacts/`). Each run also appends a line to
`~/Library/Caches/matron-e2e/runs.tsv`: time, commit, exit status,
passed/total, retried tests and model token usage.

## What it covers

`tests/smoke.e2e.ts`:

1. Sign in with server URL, username and password (no model calls).
2. The Projects tab lists projects and is titled Projects, not Missions.
3. An item thread inside a project shows its image attachment, with no
   "unsupported event" row.
4. Record a voice note in a chat and send it; the journal receives the audio.
5. Tap Send now on a queued-message card; the journal receives the release.

## The rig

`rig/rig.sh` builds a throwaway journal and simulator state for every run:

- a matron-journal on `127.0.0.1:9820` with its database under
  `~/Library/Caches/matron-e2e/rig` (it stops only its own server, by pid);
- user `e2e` and agent `e2e-box`, seeded by `rig/seed.mjs` with a chat, a
  busy chat holding a queued message, a project with a mission, and an item
  whose thread carries an image;
- a fresh install on the dedicated `Matron e2e` simulator, with a
  signed-in session written into the app group.

It is separate from `MatronUITests/rig` (port 9810, `/tmp/matron-demo`) so
both can run on one machine.

## Writing tests

Prefer exact locators (`screen.getByTestId`, `screen.getByText`) and
checks against the rig's database (`query()` in `tests/rig.ts`); use
`agent.act` for navigation the cache can replay and `agent.assert` for what
only a look at the screen can tell. Every `agent.assert` calls the model on
every run; replayed `agent.act` steps don't.
