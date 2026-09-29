# Mac timeline perf rig

Measures the Mac chat timeline (spec `docs/superpowers/specs/2026-09-28-mac-appkit-timeline-design.md`
§1) with an offline, unsandboxed copy of `MatronMac.app` driven by
`MacTimelinePerfProbe` (`MatronMac/App/MacTimelinePerfProbe.swift`, `#if DEBUG`
only). It runs a Release `-O` build compiled with `-DDEBUG` so the probe code
is included, and the Debug entitlements so it can read
`MATRON_APP_SUPPORT_OVERRIDE` and `~/Library/Preferences/chat.matron.app.plist`
without a sandbox.

**Never point this at your live store or a second live client.** `store`
copies the journal/search sqlite files and rewrites the copied session's
`homeserverURL` to `https://127.0.0.1:9/`, so the rig app cannot reach the
real journal even if it tries.

## One-time setup

```
zsh MatronMacUITests/rig/mac-perf.sh store
```

Backs up `~/Library/Containers/chat.matron.app/.../journal-store/dan.sqlite`
and `matron-search.sqlite` into `$RIG/store` (default `RIG=/tmp/mactable`),
and writes a session file pointed at `127.0.0.1:9`. Re-run it whenever you
want a fresher copy of the live data; the rig always reads from `$RIG/store`,
never the live container.

## Build

```
zsh MatronMacUITests/rig/mac-perf.sh build <worktree> <appdir>
```

Builds `MatronMac` Release into `$RIG/dd` (`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`,
`OTHER_SWIFT_FLAGS='$(inherited) -DDEBUG'`, signed with
`MatronMac/App/MatronMac.Debug.entitlements`), then `ditto`s the built
`.app` into `<appdir>`. On failure it greps `error:` lines out of
`$RIG/build.log` and exits 1.

## Launch and run probe commands

```
zsh MatronMacUITests/rig/mac-perf.sh launch <appdir> [convo] [flag on|off]
zsh MatronMacUITests/rig/mac-perf.sh run "<cmd>" "<cmd>" ...
```

`[convo]` defaults to `$LONG`. Two environment variables pick the
conversations the rig drives, both conversation ids from the copied store:

- `LONG` — the long room: `launch` opens it, and the `ab` suite scrolls and
  streams in it (default `3a258fa0-ee0a-43e2-9f01-a30db5695e39`).
- `OTHER` — the second room `ab` switches to and back for the `open`
  measurements (default `5ee1ed62-1b55-4968-b788-a089ff0b0e28`).

The defaults are rooms in Dan's store; set both when running against any
other store, e.g. `LONG=<id> OTHER=<id> zsh MatronMacUITests/rig/mac-perf.sh ab …`.

`launch` kills any running rig copy (matched by the rig's own launch
arguments, so the live app is never touched), launches with
`MATRON_APP_SUPPORT_OVERRIDE=$RIG/store`, the probe's command/output files
wired up and the flag as a launch argument (`-chat.timeline.appkit YES|NO`,
the argument domain, which beats every persistent default), waits 20 s for
startup, then sends `float on` (see below) so the display link keeps running.
Check which timeline came up: the flag-on app logs
`mac timeline controller init room=…` (unified log, subsystem `chat.matron`,
category `ios-chat-timeline`); the flag-off app logs none.

Why not `defaults write`: it does not reach the rig app. Because the live
app's sandbox container exists, `defaults write chat.matron.app …` is
redirected by cfprefsd into
`~/Library/Containers/chat.matron.app/Data/Library/Preferences/chat.matron.app.plist`
(the live app's preferences), while the unsandboxed rig app reads
`~/Library/Preferences/chat.matron.app.plist`. The old script's writes
therefore changed the live app's setting and left the rig on its build
default (on, because the rig is compiled with `-DDEBUG`), so every
"off" run before 2026-09-28 was really "on".

`run` writes one command at a time to `$RIG/cmd`, waits (up to 5 min) for a
new line in `$RIG/perf.jsonl`, and prints it. Commands, from
`MacTimelinePerfProbe`:

- `open <convoID>` — select the conversation; reports `rowsReadyMs` (time
  until the timeline was handed the room's rows) and `firstFrameMs` (first
  frame after that), plus hitch time in the following 5 s.
- `scroll <pt> <steps>` — a fixed workload: `steps` synthetic trackpad
  scroll-wheel events of `pt` points each, sent straight to the timeline's
  `NSScrollView` (never posted to the system), bouncing between the ends of
  the history window. Fixed *amount of work*, not fixed duration, so a
  slower timeline doing the same work is directly CPU-comparable.
- `stream <deltas> <hz>` — grows a synthetic `eph:` streaming reply through
  the view model's real snapshot path, `deltas` steps at `hz` per second.
- `idle <seconds>` — the instrument's own noise floor: no workload, just
  frames and hitches counted.
- `float [off]` — floating level, 2% opacity, mouse-transparent (or back to
  normal with `off`). See "Occlusion" below; `launch` calls this for you.
- `snap <path>` — PNG of the rig window (default `/tmp/matron-mac-perf.png`).
- `bottom` — jump to the bottom and re-arm follow-tail.

Every result line in `$RIG/perf.jsonl` carries `cpuS` (getrusage), `hitches`/
`hitchMs` (frames later than 1.5x the frame duration), `maxGapMs`,
`footprintMB` (physical footprint) and `load` (1-minute load average), so the
SwiftUI and AppKit timelines are measured by the same instrument.

## A/B suite

```
zsh MatronMacUITests/rig/mac-perf.sh ab <appdir> <pairs>
```

Runs `<pairs>` rounds of flag-off then flag-on, each round: `launch`, then
`idle 5`, four conversation switches between `$LONG` and `$OTHER`, and the
`scroll`/`stream` workloads from the spec's §1 table, each preceded by
`bottom` to reset position. Use this, not a single flag-on run, to draw any
before/after conclusion — see "Interleave, don't trust a single run" below.

## Caveats (spec §1)

- **Occlusion.** A `CADisplayLink` on a fully occluded window barely fires
  at all, which silently starves every workload of frames. The rig window is
  kept floating at 2% opacity and mouse-transparent (the `float` command)
  specifically so it stays un-occluded — and thus its display link keeps
  running at the display rate — while staying invisible and click-through on
  a Mac someone is actively using. If a run looks unexpectedly idle, check
  `float` was sent (`launch` does this automatically after its 20 s wait).
- **Machine load.** This rig has been run on a Mac under heavy load from
  other builds and VMs (load average 330–780 during the original baseline).
  Absolute CPU-seconds and hitch counts are inflated by that contention and
  are not meaningful on their own — every result line reports `load` so you
  can tell whether a number is trustworthy.
- **Interleave, don't trust a single run.** Because absolute numbers move
  with machine load, draw conclusions only from *interleaved* flag-off vs
  flag-on pairs in the same binary, run back to back (`ab`), never from a
  flag-on run compared against a flag-off run from a different time or
  session. Use ≥3 pairs.
- **Never a second live client.** The rig always runs against the offline
  copy made by `store`, whose session file has `homeserverURL` rewritten to
  `127.0.0.1:9`. Do not point `MATRON_APP_SUPPORT_OVERRIDE` at the live
  container, and do not skip the `store` step — a rig instance talking to
  the real journal alongside your own live Mac app is a second client on the
  same account.
- **Unsandboxed.** The rig app is built and signed with the Debug
  entitlements (no App Sandbox), which is why it can honor
  `MATRON_APP_SUPPORT_OVERRIDE`. It reads its preferences from
  `~/Library/Preferences/chat.matron.app.plist`, but `defaults write
  chat.matron.app` from a shell writes the live app's container plist
  instead, so set the flag with `launch`'s argument, never `defaults`.
- **Display asleep or locked.** The probe measures on the display link,
  which does not tick while the display sleeps or the screen is locked; every
  command then prints `TIMEOUT`. Hold the display awake for the run
  (`caffeinate -d -u -t 3600 &`) and check with a cheap `run "idle 2"` first
  (it should report ~240 frames at 120 Hz). A locked screen cannot be fixed
  from the shell.
- **Rig logs.** `$RIG/app.log` has stderr only (NSLog, e.g.
  `MacTimeline REENTRANT-GUARD`) and is truncated on every `launch`.
  Timeline breadcrumbs go to the unified log (see above) and to
  `~/Documents/matron-diag.log`, which rotates at 2 MB, so read the unified
  log for a whole A/B.
