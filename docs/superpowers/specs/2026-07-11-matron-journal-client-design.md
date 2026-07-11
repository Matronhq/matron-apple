# Matron on matron-journal — Client Design

- **Date:** 2026-07-11
- **Status:** Approved (brainstorm 2026-07-11)
- **Owner:** Dan Barker
- **Replaces:** The entire matrix-rust-sdk stack in the Matron Swift client (iOS + Mac)
- **Server counterpart:** `matronhq/matron-journal` PR #1 (`feat/server-v1-core`), spec at
  `matron-journal/docs/superpowers/specs/2026-07-10-matron-protocol-design.md`

## 1. Background & goals

Matron (and the Element X fork) freeze on Matrix: matrix-rust-sdk's sync machinery
dies without resuming and the only recovery is an app restart. The protocol has been
replaced by **matron-journal** — a server-authoritative journal with integer cursors,
where any failure converges to "reconnect and resume from cursor". The server v1 core
exists and is chaos-tested (32/32 green on the PR branch).

This effort switches the Swift app to speak **only** matron-journal and deletes all
Matrix code. Goals:

- Structural immunity to the freeze class: the UI reads a local GRDB mirror; a single
  sync engine keeps the mirror fresh; the cursor advances only after a committed write.
- Views and render models survive; the swap happens at the service seam.
- Media and push client code is kept **dormant** (written against the protocol spec's
  deferred endpoints) — another agent is implementing the server side.

Non-goals: Matrix history import; E2EE; multi-account.

## 2. Architecture

```
Views (SwiftUI, ~unchanged)
   │  TimelineItem / ChatSummary (kept render models)
ViewModels (re-seamed onto 3 slim protocols)
   │
MatronJournal module (NEW, no FFI)
 ├─ JournalAPI     URLSession HTTP: /login, /snapshot, /convo/:id/messages
 │                 (+ dormant: POST /media, GET /media/:id)
 ├─ JournalClient  actor: WebSocket, hello{token,cursor}, frame decode,
 │                 jittered backoff, liveness watchdog, upstream ops
 ├─ JournalStore   GRDB: conversations, events(PK seq), meta(cursor…), FTS5
 └─ SyncEngine     actor: snapshot → connect → apply frames transactionally
```

### JournalClient

- `URLSessionWebSocketTask` to `wss://<server>/ws`. First frame `{op:"hello", token, cursor}`.
- Decodes the three frame kinds: `journal` (durable, advances cursor), `ephemeral`
  (streaming deltas / indicators, never stored), `control` (`hello_ok`, `error`,
  `snapshot_required`).
- Liveness: the server pings every 20 s (URLSession auto-pongs). If **no traffic for
  45 s**, tear down and reconnect with jittered exponential backoff (1 s → 60 s cap).
  Reconnect immediately on scenePhase → active and on network-path change
  (`NWPathMonitor`).
- Upstream ops: `send` (with `local_id`), `prompt_reply`, `read_marker`, `ack`,
  `viewing`, and the proposed `convo_create` (§7).

### JournalStore (GRDB — already a dependency)

Tables:

- `conversation(id TEXT PK, title, session_state, last_seq, snippet, created_at,
  muted BOOLEAN local, unread_count local)` — mirror of snapshot summaries;
  `unread_count` is **computed locally** (see §4), `muted` is a local-only preference.
- `event(seq INTEGER PK, convo_id indexed, ts, sender, type, payload JSON)` — the
  journal mirror. Applying a frame with `seq <= cursor` is a no-op (idempotent replay).
- `meta(key, value)` — cursor, user id, device id, server URL.
- `event_fts` — FTS5 contentless table over text-bearing payloads, fed on ingest and
  on history pagination. Search reads this; all Matrix backfill machinery is deleted.

UI streams come from GRDB `ValueObservation` — the store is the single source of truth.

### SyncEngine

- Cold start (cursor == 0): `GET /snapshot` → upsert conversations → connect WS with
  `cursor = snapshot.seq` → lazy-load history per conversation on open.
- Warm start: connect WS with stored cursor; replayed frames apply idempotently.
- Every reconnect also refreshes `/snapshot` conversation summaries (stopgap for
  title-only `convo_upsert` not reaching live devices — see §7).
- Frame apply is one transaction: insert event, update conversation summary
  (snippet/last_seq/session_state/unread), advance cursor. `ack` sent batched
  (every 50 frames or 2 s).
- `snapshot_required` → wipe store, re-snapshot, reconnect. Automatic, bounded.
- Connection state machine `connecting → replaying → live → backoff(nextRetry)`
  published for the existing `ConnectionStatusBanner`.

### Event model

`JournalEvent` decodes every spec §7 type into a typed payload enum: `text`, `prompt`,
`prompt_reply`, `tool_output`, `diff`, `permission_request`, `session_status`,
`file`, `image`, `read_marker`, `edit`, plus `unknown(type, rawJSON)`. Unknown types
render as a labeled fallback card so the protocol can grow without lockstep upgrades.

Mapping to the kept `TimelineItem.Kind`:

| journal type | TimelineItem.Kind |
|---|---|
| `text` | `.text` |
| `tool_output` | `.toolCall` (ToolCallCard) |
| `prompt` | `.askUser` (existing sheet UI) |
| `prompt_reply` | `.askUserAnswer` |
| `diff` | `.toolCall`-style card (new case `.diff`) |
| `permission_request` | `.askUser` variant |
| `session_status` | chat header state (not a row) |
| `file`/`image` | `.file`/`.image` (dormant until /media) |
| `read_marker`/`edit` | not rendered; applied to state |

## 3. Service seams (replacing the Matrix five)

- **`SessionController`** — `signIn(serverURL, username, password, deviceName)` →
  `POST /login`, token stored via existing `KeychainStore`; `signOut()` (clear token,
  wipe store); published session state. Sign-in screen defaults the server field to
  `https://chat.example.com` (editable).
- **`ConversationListService`** — `AsyncStream<[ChatSummary]>` from store observation;
  `setMuted(convoID:)` local; `createConversation(title:)` via `convo_create` (§7).
  `ChatSummary` keeps its shape (roomID field carries the convo id; name carries title;
  gains a session-state badge).
- **`ConversationService`** (per open conversation) — timeline
  `AsyncStream<[TimelineItem]>` (store rows + ephemeral overlay), `send(text:)`,
  `promptReply(targetSeq:choice:text:)`, `markRead(upToSeq:)`,
  `loadOlder()` (HTTP pagination → insert into store → FTS), `setViewing(Bool)`.

### Streaming overlay & local echo

- Ephemeral `{convo_id, message_ref, text_delta | replace_text}` frames update an
  in-memory overlay row in `ChatViewModel` keyed by `message_ref`; never stored.
- The overlay row is removed when a journal row arrives whose
  `payload.message_ref` matches (bridge convention, §7), with a 30 s staleness
  timeout fallback. Lost ephemerals are harmless by design.
- Sends are optimistic: a pending `TimelineItem` keyed by `local_id`
  (`TimelineSendState` reused) is reconciled against the echoed journal row
  (matched by sender + payload; `local_id` echo is a server ask, §7). Retries reuse
  the same `local_id` — the server's idempotency key makes them safe.

## 4. Unread & read state

The server's `unread_count` is known-buggy (own sends increment it — flagged in the
server BACKLOG) and is **ignored**. The client computes unread per conversation as:
message-class events (`text`, `tool_output`, `diff`, `prompt`, `permission_request`,
`file`, `image` — the server's `MESSAGE_TYPES`) with `seq >` the latest
`read_marker.up_to_seq` for that convo, excluding events whose sender is the current
user. `markRead` sends the `read_marker`
op; the resulting journal row converges all devices (and re-zeros the local count).

## 5. Feature disposition

| Feature | Fate |
|---|---|
| Sign-in | Reworked: server URL + username/password → device token |
| Verification, SAS, recovery key, banners (iOS+Mac) | **Deleted** |
| Sliding sync, RoomListSubscription, SDKTracing | **Deleted** |
| New Chat / BotProfile | **Kept**, wired to `convo_create` (§7) |
| Attachments/media UI | Kept, disabled behind `mediaAvailable` flag; `MediaService` reimplemented against spec `/media`, dormant |
| Push + NSE | Targets kept; `PushService` = journal device registration (dormant); NSE reduced to plaintext passthrough; Matrix `PushDecoder` deleted |
| Search | Kept; FTS fed on ingest + pagination; Matrix backfill deleted |
| Mute | Local-only preference |
| Device settings | Stripped to sign-out + local device info |
| Drafts, scroll memory, slash commands, ask-user sheets, timestamps | Untouched |

## 6. Deletion map

- Dependency `matrix-rust-components-swift` removed from `MatronShared/Package.swift`
  and `project.yml`.
- Deleted wholesale: `Sources/Sync/*`, `Sources/Verification/*`,
  `Sources/Auth/{AuthServiceLive,SDKTracing}`, `Sources/Chat/{ChatServiceLive,
  TimelineServiceLive,TimelinePagerLive,MediaServiceLive,RoomListSubscription}`,
  `Sources/Push/{PushDecoder,PushBootstrap,PushServiceLive,…}` (Matrix parts),
  `Sources/Search/{BackfillCoordinator,BackfillRunner,TimelinePager}`,
  Verification UI in `Matron/` and `MatronMac/`, Matrix-coupled tests.
- Old Matrix session-store directory deleted on first launch after update.
- Reshaped in place: `AuthService` protocol → `SessionController`; `ChatService`/
  `TimelineService` protocols → `ConversationListService`/`ConversationService`;
  NSE `NotificationService.swift` (plaintext passthrough).

## 7. Server / bridge asks (filed for the agent building v1-completion)

1. **`convo_create` client op** — client-initiated conversation (New Chat with a bot);
   bridge picks it up to spawn a session. Until it lands, the client surfaces a
   graceful "server doesn't support this yet" error.
2. **`message_ref` echoed in the finalize journal payload** — today it exists only in
   the idem key, so clients can't correlate stream → durable row without convention.
3. **`local_id` echoed on send fan-out** — exact local-echo reconciliation instead of
   payload matching.
4. **`convo_meta` live sync** — title-only `convo_upsert` currently reaches other
   devices only via `/snapshot` (client stopgap: snapshot refresh on reconnect).
5. **Fix or drop server `unread_count`** (client ignores it).
6. `/media` + APNs per the server backlog (client code is written and dormant).

## 8. Reliability & testing

- **Unit (SPM):** JournalStore apply idempotence (frames ≤ cursor are no-ops; replay
  convergence), frame decode goldens (all §7 types + unknown), TimelineItem mapping,
  unread computation, backoff/liveness state machine with a fake clock.
- **Integration:** `MatronIntegrationTests` boots the real node server from a sibling
  checkout (`MATRON_JOURNAL_PATH` env var; suite skips if absent): sign-in → snapshot
  → live send/receive round-trip, and a client-side **chaos resume test** — kill the
  socket mid-replay/mid-stream repeatedly, assert the GRDB mirror converges to an
  exact prefix of the journal. Same headline property as the server's chaos test.
- **Snapshot tests:** existing DesignSystem suites unaffected; new snapshots for the
  unknown-event fallback card and diff card.
- **Manual:** daily-drive against real bridge traffic once the bridge's publisher
  lands (per the protocol spec's migration plan).

## 9. Plumbing

- Branch `feat/matron-journal` off `main` (`diag-live-update` is throwaway Matrix
  diagnostics; superseded by this work).
- `project.yml`: remove the MatrixRustSDK package; keep NSE target; regenerate with
  `xcodegen generate`.
- `MatronShared/Package.swift`: remove matrix dep; remove `MatronSync`/
  `MatronVerification` targets; add `MatronJournal`; `MatronAuth` reshaped (Keychain +
  SessionController, no SDK).
