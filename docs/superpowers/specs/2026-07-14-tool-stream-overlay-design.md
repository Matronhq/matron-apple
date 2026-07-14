# Tool-stream live output overlay (journal handover piece 2)

**Date:** 2026-07-14
**Branch:** `feat/tool-stream-overlay` (stacked on `feat/tool-output-durable-ttl`, PR #20)
**Server contract:** matron-journal `docs/protocol.md` (stream_append / tool_stream
ephemerals) + conformance fixture `13_tool_stream.json`. Server and bridge sides
are already deployed; this spec covers the Apple client only.

## Goal

While an agent command runs, viewing clients receive `tool_stream` ephemerals.
Render them as a live terminal tile at the bottom of the timeline — the same
visual as the legacy `LiveOutputCard` / matron-web's live-output tile — and
retire the tile when the durable `tool_output` row (rendered by piece 1's
`ToolCallCard`) lands.

Approach chosen with Dan (option A): reuse the LiveOutputCard terminal look,
fed by the journal ephemeral stream instead of the legacy viewer WebSocket.
The legacy `LiveOutputEvent`/`LiveOutputSession` path stays untouched.

## Wire contract (what the server sends)

All frames: `{kind:'ephemeral', convo_id, message_ref, tool_stream:{...}}`,
delivered only while this client is `viewing` the conversation.

- `{event:'append', offset, chunk}` — `offset` is the UTF-8 **byte** position
  of `chunk` in the command's output. Consecutive appends coalesce by
  concatenation. **No meta on appends** — a from-the-start viewer doesn't know
  the command string until it obtains a `sync`.
- `{event:'sync', meta:{tool, command}, offset, content, head_truncated}` —
  full scrollback so far, sent per active stream when the client (re-)sends
  `viewing`. `offset` is the byte position of `content[0]`; `head_truncated`
  means the server's 1 MiB ring dropped the beginning.
- `{event:'end', reason:'stale'}` — server idle sweep freed the buffer
  (bridge died). Drop the tile.
- **Normal completion sends no ephemeral**: the durable `tool_output` journal
  event arrives with the same `message_ref` in its payload and retires the
  overlay. A pending append can flush up to **200 ms after** that row —
  ephemerals for an already-retired ref must be ignored, never re-open a tile.
- Gap recovery: clients cannot send `stream_append` (`stream_resync` is a
  server→bridge frame). The client-side resync mechanism is **re-sending
  `viewing`**, which yields a fresh `sync` per active stream.

## Components

### 1. `WireModels.swift` — decode + new update type

New value type:

```swift
public struct ToolStreamUpdate: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case append(offset: Int, chunk: String)
        case sync(tool: String?, command: String?, offset: Int,
                  content: String, headTruncated: Bool)
        case end(reason: String?)
    }
    public let convoID: String
    public let messageRef: String
    public let event: Event
}
```

`ServerFrame` gains `case toolStream(ToolStreamUpdate)`. In `decode`, the
ephemeral branch checks for the `tool_stream` key **before** the existing
`message_ref` text-streaming fallback. Unknown `event` values decode to `nil`
(frame skipped) so the protocol can grow.

**Bug fixed by ordering:** today a `tool_stream` frame carries `message_ref`
and no `text`/`replace_text`, so it decodes as an empty `EphemeralUpdate` and
paints an empty streaming text bubble whenever a command streams. The new
branch captures these frames first.

### 2. `JournalSyncEngine` — fan-out

`toolStreams(convoID:) -> AsyncStream<ToolStreamUpdate>`, a third
continuation registry mirroring `ephemerals(convoID:)` / `activities(convoID:)`,
fed from a new `case .toolStream` in the frame loop. No engine state beyond the
registry — all stream bookkeeping lives in the overlay.

On reconnect the run loop already re-sends `viewing`, so fresh `sync` frames
re-arrive automatically; if the command finished while offline, the journal
replay delivers the durable row, which retires the tile. No extra reconnect
logic needed.

### 3. `JournalTimelineService.OverlayState` — byte bookkeeping

New actor state:

```swift
struct ToolStream {
    var tool: String?
    var command: String?          // nil until a sync supplies meta
    var bytes: [UInt8]            // accumulated output
    var startOffset: Int          // byte offset of bytes[0]
    var headTruncated: Bool
    var updated: Date
}
private(set) var toolStreams: [String: ToolStream] = [:]   // by message_ref
private var retiredToolRefs: [String] = []                  // FIFO, cap 64
```

`applyToolStream(_:) -> Bool` (returns "caller should request resync"):

- Ref in `retiredToolRefs` → ignore entirely (the 200 ms late-flush rule).
- `append` with no existing entry: `offset == 0` → create entry (no meta) and
  **return true** so a `sync` supplies the command string; `offset > 0` →
  don't create, return true (mid-join without sync).
- `append` on existing entry, with `end = startOffset + bytes.count`:
  - `offset == end` → append `chunk`'s UTF-8 bytes.
  - `offset < end` → trim the first `end - offset` bytes of the chunk
    (idempotent retries); if the whole chunk overlaps, drop it.
  - `offset > end` → gap: drop the chunk, return true.
- `sync` → authoritative replace: entry becomes
  `(meta, content bytes, offset, headTruncated)` whether or not one existed.
- `end` → remove the entry.

Resync requests are debounced per-ref inside the actor (min 2 s between
`true` returns for the same ref) so a burst of gapped appends can't loop
`viewing` sends. The consumer task in `items()` reacts to `true` by calling
`engine.setViewing(convoID:)` (idempotent re-send).

**Retirement** extends the existing `reconcile` message_ref sweep: a durable
row whose payload carries `message_ref` removes `toolStreams[ref]` and pushes
the ref onto `retiredToolRefs` (FIFO-capped at 64).

**Staleness:** tool streams are exempt from the 30 s streaming-text cutoff —
a quiet build step legitimately produces nothing for minutes. They use their
own 10-minute cutoff in the same sweep (matches `LiveOutputCard`'s
auto-connect window; the server's own idle sweep is 30 min and emits `end`
when the bridge died, so this is a backstop for missed frames only).

### 4. Mapper + timeline item

New kind on `TimelineItem.Kind`:

```swift
case toolStreamLive(messageRef: String, command: String?,
                    text: String, headTruncated: Bool)
```

`JournalTimelineMapper.toolStreamItem(...)` mirrors `streamingItem`:
id `"toolstream:<ref>"` (stable for list diffing), sender = agent, timestamp
clamped to the last durable row's day bucket. Emitted in `items()` after
streaming-text rows, before echoes and the activity indicator.

Rendering the byte buffer as a string: decode UTF-8 after dropping any
incomplete trailing multibyte sequence (up to 3 bytes) so a chunk boundary
mid-character doesn't flicker a replacement glyph. Display is capped to the
last 64 KiB of the buffer (server caps the buffer at 1 MiB; SwiftUI `Text`
does not enjoy megabyte strings).

### 5. `ToolStreamCard` (DesignSystem)

Sibling of `LiveOutputCard`, reusing its visual vocabulary; the dark
monospace sticky-tail pane is extracted into a shared `TerminalPane` subview
used by both cards (no behavior change to the legacy card).

- Header: `$ <command>` when meta is known, otherwise "live output"; spinner +
  "running…" status; expand/collapse chevron (collapsed ≈ 3 lines, expanded
  bounded at 600 pt) — same as LiveOutputCard.
- `head_truncated` → a dimmed "… earlier output truncated" first line.
- No terminal states: the tile only exists while live; completion is the
  piece-1 `ToolCallCard` replacing it.

ChatView's row switch gains the `toolStreamLive` case on both platforms
(shared rendering code path, same place `.liveOutput` is handled).

## Out of scope (explicitly deferred)

- Suppressing the `activity` indicator row while a tool tile is live (both
  may show; the indicator sits below and clears on idle).
- "View full log" blob fetch on completed cards (piece-1 deferral, unchanged).
- Any change to the legacy viewer-WebSocket path.

## Testing

- **WireModels:** decode append / sync / end frames; tool_stream frames no
  longer decode as empty `EphemeralUpdate` (regression for the empty-bubble
  bug); unknown event → nil.
- **OverlayState (via JournalTimelineServiceTests):** append coalescing;
  overlap trim; gap → chunk dropped + resync requested once per debounce
  window; offset-0 append without meta requests sync; sync replaces content
  and supplies meta; end removes tile; durable row retires tile and late
  append/sync for the ref is ignored; 10-min staleness sweep; 30 s sweep does
  NOT kill a quiet stream.
- **Mapper:** toolStreamItem id/timestamp/kind; trailing-multibyte trim; 64 KiB
  display cap.
- **Snapshots:** ToolStreamCard collapsed/expanded, with and without meta,
  head_truncated variant; existing LiveOutputCard snapshots must not change
  (TerminalPane extraction is invisible).
- Full SPM suite + both app targets build.
