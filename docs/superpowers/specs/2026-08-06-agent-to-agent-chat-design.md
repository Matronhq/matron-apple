# Agent-to-agent chat rooms + agent-sent attachments — design

**Date:** 2026-08-06
**Status:** Approved by Dan (chat session), pending written review
**Repos touched:** matron-journal, matron-bridge, matron-apple (small), matron-android (later parity)

## Motivation

Two agents on different boxes were working on different aspects of the same
issue and Dan had to hand-carry messages between them. Agents need a way to
talk to each other directly — in a room Dan can see and join — and the future
shape is role-based agents coordinating among themselves. Separately, agents
need a way to send images and files (screenshots, PDFs, plots) back into any
chat, including these shared rooms.

A related bug motivates a security tightening: an agent once posted a message
into the wrong conversation. Journal write auth for agents is currently
user-scoped (`authorize()` in matron-journal `src/auth.js` checks only
`owner_user_id`), so any agent device can write into any of the user's
conversations. This design closes that.

## Requirements (from brainstorming)

- Mixed use: delegation and genuine multi-turn collaboration; Dan observes and
  participates in the same room.
- All boxes' bridges connect to **one** journal server (Dan's dev-2). No
  multi-journal federation.
- The responding agent is the **existing session** Dan already chats with on
  the target box — context is the whole point. (Fresh-session calls are a
  possible later extension.)
- Free rein: no human approval gates on starting or continuing agent chats.
  Session limits (context, usage) are the hard stop; no artificial exchange
  caps.
- Consent between agents: an agent may not write into another agent's
  conversations. Cross-agent contact starts with a server-mediated **call**
  carrying a justification; the target accepts or refuses.
- Callers get fast, honest status: "target offline" immediately; "delivered,
  session mid-turn" immediately (a turn can exceed any reasonable timeout).
  Callers are instructed **not** to block waiting on a busy peer — carry on,
  the reply arrives as a later turn.
- Agents can see roster metadata for targeting: boxes, sessions, titles,
  activity, and a short rolling summary of each conversation (extending the
  existing Gemini title pass). No transcript read access between agents in v1.
- Attachments: images and arbitrary files (PDFs, logs), sendable into the
  agent's own chat and into shared rooms.

## Architecture overview

A side room is an ordinary **top-level** journal conversation on the shared
journal server. Both bridges publish into it and both receive its frames; Dan's
apps see it in the chat list like any chat, with working unread counts and
push (push/unread suppression only applies to `parent_convo_id` children —
side rooms deliberately are not children and do not use the `:sub:` id
convention, which the engine and server both silence).

Everything downstream — timeline rendering, image events, streaming, search,
pagination, push threading (`thread-id` = `convo_id`) — works unchanged
because the room is a normal conversation.

The one new server primitive is a **participants set** for conversations,
which serves double duty:

1. **Delivery**: journal fan-out and replay currently deliver a conversation's
   frames only to its single owning `agent_device_id` (`hub.broadcastJournal`).
   Participants extend delivery to joined agent devices.
2. **Write authorization**: agent writes are restricted to conversations they
   own or have joined. This is the tightening that makes the
   wrong-conversation bug impossible rather than unlikely.

## Security model

- **Client (user) devices: unchanged.** User-scoped everything. Dan sees every
  room, can post into any room, and his messages fan out to all participant
  bridges.
- **Agent devices: writes require ownership or joined participation.** The
  server rejects other agent writes with an explicit error frame (no silent
  acceptance). Applies to `publish`, `finalize`, ephemerals (`stream`,
  `stream_append`, `activity`, `status`), and `convo_upsert`.
- **The only cross-boundary primitive is the invite.** It is not a message
  into anyone's conversation; it is a server-mediated frame delivered to the
  target bridge. It carries the room id, the caller's identity, a topic, and a
  justification.
- **Consent:** the target session accepts or refuses via MCP tool. Accept →
  server records the participant as `joined`; only then can the target bridge
  write to (and receive) the room. Refuse → recorded, caller notified with the
  reason, room accepts no further agent writes from the target.
- **Reads:** agents get roster metadata only (devices, conversations with
  titles/state/last-activity/summary) — no cross-agent transcript reads in
  v1. A future grants extension can add read sharing if a use case demands it.
- **Legacy:** conversations with `agent_device_id IS NULL` retain current
  broadcast behavior during migration.

## Room lifecycle

1. Agent A calls `agent_chat_start(target, topic, justification, message)`.
   Target is chosen from the roster — canonically a specific conversation
   (i.e. "the session behind convo X"); a bare device target resolves to that
   box's most recently active session.
2. Bridge A mints a room id (UUID, top-level), upserts the conversation with
   title `«boxA» ↔ «boxB» — «topic»`, publishes the opening message, and sends
   the invite through the journal.
3. Server checks the target bridge's connection: offline → `agent_chat_start`
   returns "target offline" immediately.
4. Target bridge acks instantly with session state: `idle` (answer coming) or
   `busy` (invite queued as the session's next turn). The caller's tool
   returns the room id plus that status; on `busy` it does **not** block — the
   tool result tells the caller to continue its own work and expect the
   answer as a later turn.
5. The target session sees a clearly-marked request turn ("Agent «name»
   requests a chat: «justification». Accept or refuse.") and answers via
   `agent_chat_accept` / `agent_chat_refuse(reason)`.
6. On accept the server adds the `joined` participant row; the opening message
   is delivered to the target session as a turn; from then on each agent's
   room messages become turns for the other, and Dan's messages become turns
   for both.
7. Manual flow: Dan can hand any agent a room id; `agent_chat_join(room_id)`
   sends the same invite in reverse — the room's creator session receives the
   request turn and accepts or refuses on behalf of the room.
8. `agent_chat_leave(room_id)` removes participation; the room and its history
   remain visible to Dan.

The room appears in Dan's chat list the moment it is created, with the pending
state visible (title suffix until accepted, e.g. "… (inviting dev-2)").

## Server changes (matron-journal)

- **`convo_agents` table**: `(convo_id, agent_device_id, state
  'invited'|'joined'|'refused'|'left', justification, created_at,
  answered_at)`. This is the grants table the code already anticipates
  (`src/auth.js` comment, BACKLOG).
- **Fan-out**: `hub.broadcastJournal` and the hello-replay predicate deliver a
  conversation's frames to the owning device plus `joined` participants.
- **Write auth split**: new `authorizeAgentWrite(db, deviceId, convoId)` =
  owner or joined participant (legacy `NULL` owner allowed). Client writes
  keep the user-scoped check. Violations return an error frame.
- **`convo_upsert` semantics**: creator stamps ownership as today, but an
  upsert from a non-owner participant must not steal `agent_device_id`
  (fixes the last-writer-wins ownership flap).
- **Invite ops**: `agent_invite {room_id, target_device_id, topic,
  justification}` → validates, stores `invited` row, delivers to the target
  bridge if connected (else error to caller: offline). `agent_invite_ack
  {room_id, session_state}` relayed to the caller. `agent_invite_answer
  {room_id, accept, reason?}` → flips row state, notifies caller. Unanswered
  invites expire server-side (fallback for a connected-but-dead bridge;
  default 30 min, generous because busy is reported honestly and separately).
- **`summary` column** on conversations: writable via the existing upsert
  path by the owning bridge, returned in `/snapshot` and the roster payload.
- **Roster**: agents can already see `GET /devices`; add conversation
  metadata (id, title, state, last activity, summary, agent_device_id) to an
  agent-accessible endpoint or RPC for targeting.

## Bridge changes (matron-bridge)

- **MCP tools** (same pattern as ask-user tools: thin stdio MCP process
  calling the bridge's loopback API on port 9802, scoped by `BRIDGE_ROOM_ID`):
  - `agent_roster()` — boxes, sessions, titles, states, summaries.
  - `agent_chat_start(target, topic, justification, message)` — returns
    room id + status (`accepted`/`refused(reason)`/`pending_busy`/`offline`).
    Blocks only briefly when the target is idle; never blocks on `busy`.
    Tool description explicitly instructs: if the peer is busy, continue your
    own work; the answer/reply will arrive as a future turn.
  - `agent_chat_send(room_id, message, wait_seconds?)` — publishes to the
    room; optional short wait for a quick reply when the peer acks `idle`;
    returns immediately with `pending_busy` otherwise. Late replies arrive as
    turns regardless — nothing is lost by not waiting.
  - `agent_chat_accept(room_id)` / `agent_chat_refuse(room_id, reason)` /
    `agent_chat_join(room_id)` / `agent_chat_leave(room_id)`.
  - `send_attachment(path, caption?, room_id?)` — uploads via the existing
    agent-token `POST /media` (50 MB cap), publishes `image` (for image
    content types) or `file` events with `{blob_ref, name, content_type,
    size, caption}` into the current chat or the named room. The journal
    publish whitelist and the apps' renderer already support this
    sender-agnostically; zero server or app changes.
- **Input router carve-out**: today the router drops every frame whose sender
  is not `user:*` (its loop guard). New rule, in order: (1) own-echo guard —
  drop frames from this bridge's own agent sender name; (2) frames in rooms
  this bridge has **joined** become turns for the mapped session, attributed
  as "«agent name» (agent, room «title»)"; (3) `user:*` frames in joined
  rooms are normal user input to the mapped session; (4) everything else
  drops exactly as today.
- **Invite handling**: incoming invite → instant ack with session idle/busy →
  inject request turn → answer via tool → journal answer op.
- **Room↔session mapping** persisted to disk (same pattern as the journal
  cursor file) so restarts resume rooms.
- **Gemini summaries**: the existing title-generation pass additionally
  maintains a 2–3 sentence rolling summary per conversation, upserted with
  the same don't-clobber discipline as the July title-revert fix.

## Apps changes (matron-apple, small)

- **Sender labels**: in a conversation with more than one distinct non-user
  sender, render the sender's display name above non-own bubbles.
  `TimelineItem.sender` already carries the wire sender; the change is
  widening `MessageBubble` (currently exactly `.bot`/`.me`, name deliberately
  hidden) plus its ~8 call sites, and deriving the multi-agent condition from
  distinct senders in the store.
- Everything else works unchanged (room = normal conversation).
- Not v1: per-agent tint, participant list in the header, ephemeral/streaming
  sender attribution (protocol gap: `stream`/`activity` frames carry no
  sender and the activity row has a single stable id — acceptable because
  ephemerals only render for the focused conversation anyway).

## Error handling

- Target offline → immediate error from `agent_chat_start`.
- Busy is not failure: instant `pending_busy` ack; caller carries on.
- Refusal returns the reason to the caller; recorded server-side.
- `agent_chat_send` never loses replies: late responses arrive as new turns.
- Loops bounded structurally: each inbound room message is one queued turn;
  sessions have their normal context/usage limits (the agreed hard stop);
  ending a turn without `agent_chat_send` simply ends the exchange — no
  reply obligation exists anywhere.
- Wrong-conversation agent writes rejected server-side with an error frame.
- Oversized attachments (>50 MB) return a clear tool error.
- Bridge restart: persisted room mappings + journal cursor resume delivery;
  missed room frames replay through the normal cursor mechanism.

## Testing

- **Journal (extends existing suite)**: write-auth split (foreign-convo write
  rejected; allowed after join; legacy NULL-owner allowed), invite lifecycle
  (offline / idle-accept / busy-queue / refuse / expiry), multi-participant
  fan-out and replay, ownership not stolen by participant upsert, summary
  round-trip.
- **Bridge**: router carve-out (peer frame → turn; own echo dropped;
  non-participant agent frame dropped; user frame in joined room → turn),
  MCP tool round-trips against a stub journal, invite injection formatting,
  mapping persistence across restart, attachment upload/publish (image vs
  file classification, cap error).
- **Apps**: mapper/store tests for the multi-sender condition; snapshot test
  for the labelled bubble.
- **End-to-end**: two local bridges + one local journal; scripted call →
  accept → exchange → attachment → user message fanning to both.

## Phasing

1. **Phase 1 — `send_attachment`** (bridge only). Smallest, immediately
   useful, zero dependencies.
2. **Phase 2 — journal**: participants table, write tightening, invite ops,
   summary field. Deployable alone; the tightening is a safety win before
   rooms exist.
3. **Phase 3 — bridge**: MCP chat tools, router carve-out, invite handling,
   Gemini summaries. Rooms usable end-to-end here (apps already render the
   messages; labels follow).
4. **Phase 4 — apps**: sender labels + polish. Android parity later.
