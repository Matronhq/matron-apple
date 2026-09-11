# Journal store launch performance — design

**Date:** 2026-09-10
**Tracker:** #208
**Scope:** matron-apple (iOS + Mac). No journal-server or bridge change.

## 1. Problem

The iOS app has become slow to open. The evidence (measured on the Mac's
live store for the same account, tracker #208) points at work the local
journal store does on every launch rather than at raw size alone:

| Cause | Where | Cost on the Mac copy |
|---|---|---|
| Every launch rescans all tool-output events older than 24 h, inside a write transaction, on the main actor, before anything can read the store | `JournalStore.init` → `purgeExpiredToolOutputSnippets()` (`MatronShared/Sources/Journal/JournalStore.swift:265-269`, body 463-494) | 1.5 s SQL + 75,791 row decodes; grows forever |
| First chat-list paint after a day away runs a `MAX(seq)` sub-query on `event` per stale conversation because the TTL memo is cold | `applyReadTimeSnippetTTL` / `newestMessageSeq` (JournalStore.swift:925-962, 496-503) | ~0.4 s for 526 stale conversations |
| The chat-list observation tracks the `event` table (because of those sub-queries), so every applied frame re-runs the whole list fetch | `conversationsStream()` (JournalStore.swift:1362-1387) | throttled only by replay batching |
| Disk: tool-output and diff payloads are kept forever (129 MB), and the search index's `messages` content table holds a second copy of every body (364 MB) | `event` table; `MatronShared/Sources/Search/SearchSchema.swift:18-36` | ~1 GB on disk |

There is no launch-timing or store-size instrumentation, so nothing on the
phone confirms which cost dominates there.

The `event` table has a single index on `convo_id`. Both stores are GRDB
`DatabaseQueue`s (one connection, writes and reads serialised) in WAL mode
with `synchronous = NORMAL`. Schema migrations are a GRDB `DatabaseMigrator`
at v9 today; the missions branch (PR #209) adds v10.

## 2. Goals and non-goals

Goals, in priority order:

1. **A — Nothing proportional to store history runs on the launch path.** The
   snippet TTL sweep becomes incremental (watermark + index) and runs in the
   background after the first paint.
2. **B — The chat list's first paint reads only the `conversation` table.**
   The newest-message facts the TTL needs are maintained on write.
3. **C — The app can tell us what launch costs.** Signposts + a persisted
   last-launch timing and a Storage section in Settings on both platforms.
4. **D — The store stops growing without bound.** Tool-output and diff
   bodies older than a retention window are tombstoned locally, and their
   search-index rows go with them.

Non-goals: changing what the journal server stores; encrypting or moving
the store; VACUUM (see §3.8); Android/web (their stores are separate).

## 3. Design

### 3.1 Schema migration v11

Registered in `JournalStore.migrator()` after the missions migration `v10`
(this work branches from `main` after PR #209 merges; the name is `v11`
regardless).

```sql
CREATE INDEX event_type_ts ON event(type, ts);

ALTER TABLE conversation ADD COLUMN last_message_type TEXT;   -- nullable
ALTER TABLE conversation ADD COLUMN expired_snippet TEXT;     -- nullable
```

Backfill inside the same migration, one conversation at a time using the
existing `convo_id` index:

```
for each conversation id:
  row = SELECT type, payload FROM event
        WHERE convo_id = ? AND type IN (<JournalEventType.messageTypes>)
        ORDER BY seq DESC LIMIT 1
  last_message_type = row.type (or NULL when no message-type event exists)
  expired_snippet   = row.type == tool_output
                      && (payload.live_log == true || payload.expired == true)
                      ? "$ " + payload.command : NULL
```

`expired_snippet` is deliberately NULL for a `tool_output` that is neither a
live log nor already tombstoned. Those payloads (offloaded/legacy) carry a
durable snippet that no TTL applies to — §3.4's 24 h rule covers `live_log`
rows only — so substituting a `$ command` stub over them after 24 h would
hide output the device still holds.

`meta` gains three keys, all written by the maintenance sweep (§3.4), none
by the migration: `snippet_ttl_ts`, `retention_ts`, `maintenance_last_run`.
`wipe()` already clears `meta`, which resets all three.

One-off cost: index build over ~457k rows plus ~6k indexed point lookups,
estimated 2–4 s on the Mac copy, once, at the first launch after update.
The launch timeline (§3.6) records migration time separately so the phone's
number is known.

### 3.2 Write path: keep the new columns current

`JournalStore.applyOne` (JournalStore.swift:647-742) already updates
`snippet`, `lastActivityTS` and `unreadCount` when a message-type event
arrives. It additionally sets:

- `last_message_type = event.type`
- `expired_snippet = event.type == tool_output ? "$ \(command)" : NULL`

`insertHistory` (797-843) already recomputes `unreadCount` per touched
conversation; it recomputes `last_message_type`/`expired_snippet` the same
way (newest message-type row per touched conversation, one indexed query
each).

**Insert-time tombstoning.** Both insert paths apply the two age rules of
§3.4 to each `tool_output`/`diff` row *as it is inserted* when its `ts` is
already past the relevant cutoff. This is what makes the watermarks in §3.4
complete: rows older than a watermark can only enter the table through these
two paths, and they enter already tombstoned. The rule is one pure function,
`EventTombstone.apply(to payload:, type:, ts:, now:) -> [String: Any]?`
(returns the rewritten payload or `nil` when nothing changes), shared by the
insert paths and the sweep.

### 3.3 Read path: column-only TTL

`applyReadTimeSnippetTTL` becomes pure column logic:

```
if last_message_type == tool_output && lastActivityTS + 24 h <= now
   → displayed snippet = expired_snippet ?? snippet
else → snippet
```

Because `expired_snippet` is non-NULL only for a live-log or already-expired
`tool_output` (§3.1), the `??` above falls through to the real snippet for
every other payload, which is what keeps the offloaded/legacy case unchanged.

No `event` read, so `newestMessageSeq(_:convoID:)` and `SnippetTTLMemo`
(964-999) are deleted along with their tests; `conversationsStream()` now
tracks only `conversation`, and the comment at 1381-1385 explaining why it
re-ran on every frame goes with it. The 24 h constant stays the single
`toolLogTTL` already used by `JournalTimelineMapper`.

`purgeExpiredToolOutputSnippets` no longer rewrites `conversation.snippet`
(lines 484-492); the read path covers that case from the columns.

### 3.4 `JournalMaintenance`: one background sweeper, two watermarks

A new actor in `MatronShared/Sources/Journal/JournalMaintenance.swift`,
owned by `JournalSyncEngine`, replaces the call in `JournalStore.init`.

**Sweeps** (each a `JournalStore` method taking `now:` for tests):

1. `purgeExpiredToolOutputSnippets(now:)` — keeps its name and public
   signature. Cutoff `now − 24 h`. Scans `event WHERE type = 'tool_output'
   AND ts > :snippet_ttl_ts AND ts <= :cutoff` (uses `event_type_ts`),
   rewrites `live_log` rows not already `expired`, then sets
   `snippet_ttl_ts = cutoff`. The `live_log` gate is what the shipped sweep
   already applies: a tool output with a durable snippet and no live log has
   no 24 h TTL and is only ever touched by retention below.
   First run after the update has no watermark and scans every tool-output
   row older than 24 h once, in the background.
2. `applyRetention(now:)` — cutoff `now − 30 days` (§4 decision 1). Same
   pattern over `type IN ('tool_output', 'diff')` with watermark
   `retention_ts`. Tombstone rules:
   - `tool_output`: remove `snippet` and `live_log`, set `blob_ref` to JSON
     null (the shipped tombstone shape, which the server also writes and the
     current sweep already produces — an absent `blob_ref` stays absent);
     truncate `command` to its first 200 characters plus `…` when longer; set
     `expired = true`. `exit_code`, `denied`, `truncated`, `message_ref` stay.
   - `diff`: remove `diff` and `snippet`; set `expired = true`; every other
     key stays so the timeline can still name the file(s).
   Returns the `seq`s it tombstoned so the search rows can be removed.
3. Search removal: for every tombstoned seq, `SearchService.remove(eventID:
   String(seq))` (the live feeders key search rows by `String(seq)`,
   `JournalSyncEngine.swift:1259`). Batched through one search write
   transaction per sweep chunk.

Each sweep works in chunks of 500 rows per write transaction so the single
`DatabaseQueue` connection is never held for long and UI reads interleave.

**Scheduling** (`JournalMaintenance.runIfDue(now:)`):
- first run: 10 s after the sync engine starts, or as soon as the first
  catch-up batch has been applied, whichever comes first;
- then every 60 min while the process lives;
- also on app foreground when `maintenance_last_run` is older than 60 min.
It runs at `.utility` priority and never on the main actor. Failures are
logged and retried at the next tick; nothing blocks store open.

**Search feeders stop re-adding what retention removed.** The history
backfill (`SearchBackfillCoordinator`) and backward pagination fetch old
events from the server, which keeps bodies forever. `JournalEvent.
searchableBody` gains a `now:` parameter and returns `nil` for
`tool_output`/`diff` events older than the retention window, so all three
feeders skip them by construction.

### 3.5 Timeline rendering of an expired diff

`JournalTimelineMapper` already renders `tool_output` with `expired: true`
as a command with no captured output. Diff events gain the same treatment:
`payload["expired"] == true` maps to the diff item with an `expired` flag,
and the iOS and Mac diff rows show "Diff no longer stored on this device"
in place of the body. Nothing else in the row changes.

### 3.6 Diagnostics

**`LaunchTimeline`** (`MatronShared/Sources/Models/LaunchTimeline.swift`):
a process-wide recorder using `OSSignposter` (subsystem `chat.matron` /
`chat.matron.mac`, category `launch`) so Instruments sees intervals, and
persisting the last launch's durations to `UserDefaults` key `launch.last`.
Marks:

| Mark | Set by |
|---|---|
| `processStart` | kernel process start time via `sysctl` `kinfo_proc`, so durations are launch-relative |
| `storeOpen` begin/end, with a nested `migration` interval when any migration ran | `AppDependencies.core(for:)` around `JournalStore(...)` on both platforms |
| `firstListPaint` | first `onAppear` of the conversations list (iOS `ChatListView`, Mac sidebar list) |
| `catchUpComplete` | `JournalSyncEngine` when the first replay reaches the live cursor |

Each mark also emits one `os.Logger` info line so `log show` / `devicectl`
on the phone gives the numbers without Instruments.

**`StoreDiagnostics.sizes()`** (`MatronShared/Sources/Journal/`): async,
off the main actor, on demand only. Sums `.sqlite` + `-wal` + `-shm` for the
journal store and the search index via `FileManager.attributesOfItem`, and
runs `SELECT COUNT(*)` on `event` and `conversation`.

**Settings › Storage** section (iOS `DeviceSettingsView`, Mac
`MacDeviceSettingsView`), rows:

- Journal store — `440 MB`
- Search index — `544 MB`
- Events / Conversations — counts
- This launch — `store 1.9 s · first list 2.4 s · catch-up 6.1 s`
  (plus `migration 3.2 s` when one ran). The record is persisted on every
  mark rather than at process exit, so by the time Settings can be opened the
  stored record describes the launch the user is in — which is the useful
  one, and the reason the row does not say "last".
- Last maintenance — relative time, from `meta.maintenance_last_run`

Sizes use `ByteCountFormatter`; the section shows a spinner until the async
read returns.

### 3.7 Store open stays synchronous

`core(for:)` still opens the store synchronously on the main actor. With
the sweep gone from `init`, open is migration + PRAGMA + `grdb_migrations`
check: milliseconds except on the one launch that runs v11. Making open
async would ripple through every `AppDependencies` accessor for no steady-
state gain, so it is out of scope.

### 3.8 No VACUUM

Tombstoning frees pages inside the file; SQLite reuses them, so the file
stops growing but does not shrink. `VACUUM` on a 440 MB store would hold
the only connection for tens of seconds and need double the space
temporarily. Decision: do not vacuum. The Storage rows make the on-disk
size visible; if it matters later, a one-off "Compact store" action is a
separate, small piece of work.

### 3.9 Sequencing

- Branch from `main` after PR #209 (missions, migration v10) merges.
- One PR, tasks in this order so each is reviewable alone: v11 migration →
  write-path columns + column-only read path (B) → insert-time tombstone +
  watermarked TTL sweep (A) → retention sweep + search removal + feeder
  filter (D) → `JournalMaintenance` scheduling and removal of the `init`
  call → expired-diff rendering → `LaunchTimeline` → `StoreDiagnostics` +
  Settings sections (C).

### 3.10 Testing

`JournalTests` (in-memory `makeStore()`, `event(_:convo:sender:type:
payload:)` fixtures; temp-file + `migrate(upTo:)` for migrations):

- v11 migration backfills `last_message_type`/`expired_snippet` from stored
  events; index exists (`PRAGMA index_list`).
- `applyOne`/`insertHistory` maintain the two columns; read-time TTL uses
  only columns (assert the observation does not re-fire when an `event` row
  is rewritten).
- Watermarks: second sweep touches no rows; an older row inserted after the
  watermark arrives tombstoned; `wipe()` resets.
- Retention rewrites exactly the listed keys; chunking; returned seqs.
- `EventTombstone.apply` pure-function table test.
- `JournalMaintenance.runIfDue` with an injected clock: first-run trigger,
  hourly cadence, foreground catch-up.

`SearchTests`: `remove(eventID:)` in batch; `searchableBody(now:)` returns
`nil` past the window; backfill skips them.

`JournalTests` mapper: expired diff maps to the flagged item.

App targets: `LaunchTimeline` mark ordering and persistence; Settings
Storage section snapshot on both platforms.

### 3.11 Risks

- **v11 one-off cost** on first launch after update (estimated 2–4 s on the
  Mac copy, unknown on the phone). Measured by the same PR's timeline.
- **Retention is destructive locally.** Bodies older than 30 days are gone
  from this device; the server still has them and the app already shows
  server-tombstoned tool output, so the UI state is familiar. Not
  recoverable without a wipe + re-sync, which is the existing
  `snapshot_required` path.
- **Search results shrink** for old tool output and diffs by design.

## 4. Decisions (defaults chosen; tracker question lists them)

1. Retention window: **30 days** (alternatives 14, 90).
2. Tool-output command kept after retention: **first 200 characters**.
3. **No VACUUM** (§3.8).
4. Search index: **retention-aligned removal** of tool-output/diff rows;
   text bodies stay duplicated in the content table (67 MB on the Mac copy).
   Alternatives considered: contentless FTS5 (`content=''`) would drop the
   copy entirely but needs `contentless_delete`, which needs SQLite ≥ 3.43
   and is not guaranteed on every supported OS; stopping indexing of tool
   output and diffs altogether loses searchable recent history.
5. Diagnostics live in **Settings › Storage** on both platforms.
