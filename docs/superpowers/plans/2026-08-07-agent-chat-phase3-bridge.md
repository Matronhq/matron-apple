# Agent chat Phase 3 — bridge chat tools (plan)

**Spec:** `docs/superpowers/specs/2026-08-06-agent-to-agent-chat-design.md` — sections
"Bridge changes (matron-bridge)", "Room lifecycle", "Delivery model", "Output routing",
"Error handling", "Testing". The spec governs over this plan on any conflict.

**Repos/branches:**
- matron-bridge: worktree `/tmp/agent-chat-bridge-wt`, branch `feat/agent-chat-tools`
  (already created from `origin/master` = `cd24956`). Open a **non-draft PR after Task 2
  lands** and push after every task so Bugbot reviews incrementally.
- matron-journal: Task 1 only — a separate tiny PR from a fresh worktree
  (`git -C ~/Dev/matron-journal worktree add /tmp/hello-identity-wt -b feat/hello-identity origin/master`).
  NEVER branch-switch `~/Dev/matron-journal` (parked) or `~/Dev/matron-bridge` (live tree, parked).

**Phase 2 protocol (already merged & deployed to dev-2, journal master `656ab90`):** the five
room ops (`agent_invite`, `agent_join`, `agent_invite_ack`, `agent_invite_answer`,
`agent_leave`), the `kind:'invite'` ephemeral frame family (`request`, `join_request`,
`delivered`, `ack`, `answer`, `left`), `GET /roster`, agent-gated `GET /convo/:id/messages`,
`conversations.summary` (≤1000 chars) on `convo_upsert`, error codes `conflict`/`offline`/
`not_ready` + `forbidden`/`not_found`/`bad_request`. Full reference:
`docs/protocol.md` in matron-journal master, sections "Agent chat rooms" and `GET /roster`.
Error frames are `{kind:'control', op:'error', code, ref:<op>, detail?}` (ws.js `fail()`).
Invite frames are ephemeral: no seq, never journaled, never pushed.

## Global constraints (every task)

1. **Fail-open journal discipline**: every new publisher method is try/catch-wrapped,
   never throws to callers, and is ALSO added to `noopPublisher()`
   (`lib/journal-publisher.js:74-97`) — a bridge with no journal configured must not
   `TypeError` on the new calls.
2. **Loopback handler convention**: tool logic lives in an HTTP-agnostic factory in
   `lib/`, takes the parsed POST body, returns `{status, body}`; `index.js` mounts a
   ≤7-line adapter (the `/send-attachment` pattern, `index.js:7151-7157`). Handlers are
   unit-tested directly; the adapter is not.
3. **MCP tool convention** (`ask-user.js`): `server.tool(name, description, zodShape,
   handler)`; errors return `{content:[{type:'text', text:'...'}]}` — never throw; the
   body always carries `roomId: ROOM_ID` (the caller's bridge session key from
   `BRIDGE_ROOM_ID`); JSON-parse the response and surface `data.error` with
   `HTTP ${status}` fallback (the `send_attachment` phrasing, `ask-user.js:127-150`).
4. **Registered lib files**: every new `lib/*.js` is appended to the `check` script in
   `package.json` (explicit `node --check` list) or `npm run ci` won't cover it.
5. **Persistence**: on-disk state uses `atomicWriteFileSync` with injectable
   `load`/`save` seams (the timer-store template, `index.js:6773-6788`).
6. **Rooms are top-level**: room convo ids are fresh UUIDs (`randomUUID()`), never
   `:sub:` ids, never `parent_convo_id` children.
7. **Room content vs invite frames**: room messages (text/file/image) travel as ordinary
   journal publishes into the room convo and arrive as `kind:'journal'` frames; invite
   lifecycle travels ONLY as `kind:'invite'` ephemerals. Don't mix the two.
8. **Own-echo safety**: nothing the bridge publishes may re-enter a session as input.
   The router's existing `user:*` guard already drops agent echoes for main convos; the
   new room path must drop frames whose sender matches this bridge's own device name
   (identity from Task 1's `hello_ok`), and must fail CLOSED (drop, warn once) if
   identity is unknown.
9. **Tests green per task**: `npx vitest run <new/touched test files>` green before each
   commit; full `npm test` green at Tasks 6, 8, and 9. Commit with explicit file lists
   (`git add <files>` — never `git add -A`).
10. **No merges/deploys**: open PRs, push, reply to review — but merging either PR and
    any dev-2/bridge deploy is Dan's call.

## Sizing note

Tasks 2, 3, 5 are pure new modules + tests (parallel-safe after Task 1-2 land their
interfaces). Tasks 4, 6, 7 touch `index.js` and must be serialized. Suggested model
mix: sonnet for every implementation task, opus for the final whole-branch review.

---

## Task 1 — journal: identity in `hello_ok` (matron-journal, separate tiny PR)

**Why:** the bridge needs to know its own agent `device_id` and `name` to (a) drop its
own echoes in rooms, (b) exclude itself from the roster it shows the agent, (c) name
itself in room titles. `hello_ok` is currently `{kind:'control', op:'hello_ok', seq}`
(`src/ws.js:237`) and the token is the only identity the bridge holds.

**Change** (`src/ws.js`, the hello handler around line 237): include the authenticated
device's id and name:

```js
ws.send(JSON.stringify({ kind: 'control', op: 'hello_ok', seq: headSeq, device_id: device.id, name: device.name }))
```

(Use whatever local variable the hello path already resolved the device row into —
read the surrounding code first; do not add a second DB lookup if the row is already
in scope. Client devices get their fields too — harmless and symmetric.)

**Tests** (extend the existing hello tests in the journal suite): assert `hello_ok`
carries integer `device_id` and the device's `name` for both an agent and a client
connection. Conformance fixtures: grep `test/fixtures/conformance/` for `hello_ok`
expectations and extend them if any pin the exact frame shape.

**Docs:** one sentence in `docs/protocol.md` where `hello`/`hello_ok` is described.

**Verify:** full journal suite green. Open a small non-draft PR
(`feat/hello-identity`). NOTE for the e2e later: dev-2 runs Phase 2 + this only after
Dan merges/deploys; bridge unit tests stub `hello_ok` and don't depend on the deploy.

---

## Task 2 — publisher: invite ops, invite/error dispatch, identity, roster/messages HTTP, summary field

All in `lib/journal-publisher.js` + `test/journal-publisher.test.js` (new describe
blocks; reuse `startFakeServer`/`FAST_BACKOFF`/`silentLog` helpers) and a new small
describe in the same file for the HTTP GETs via `startFakeHttpServer`.

### 2a. Constructor options

Add to the factory options (`journal-publisher.js:111-158`):
- `onInviteFrame` — callback for inbound `kind:'invite'` frames.
- `onOpError` — callback for inbound `{kind:'control', op:'error'}` frames, invoked
  with `{code, ref, detail}` AFTER the existing warn-once logic (`:433-438`). Both
  optional; both wrapped in try/catch like `onEvent`.

### 2b. Inbound dispatch (the `socket.on('message')` chain, `:420-491`)

Insert a branch modeled on the `rpc` branch (seq-less, no cursor interaction):

```js
      } else if (msg.kind === 'invite' && onInviteFrame) {
        // Ephemeral invite-lifecycle relay (journal protocol.md "Agent chat
        // rooms > Delivery"): no seq, never journaled — so no dedupe/cursor.
        if (typeof msg.event === 'string' && typeof msg.room_id === 'string') {
          try { onInviteFrame(msg); } catch (e) { warn(`[journal-publisher] onInviteFrame handler threw: ${e.message}`); }
        }
      }
```

And in the `op === 'error'` branch, after the warn-once: `if (onOpError) { try { onOpError({ code: msg.code, ref: msg.ref, detail: msg.detail }); } catch { } }`.

### 2c. Identity capture

In the `hello_ok` branch (`:425-432`): `identity = (Number.isInteger(msg.device_id) && typeof msg.name === 'string') ? { deviceId: msg.device_id, name: msg.name } : identity;`
(module-let, initially `null` — a pre-Task-1 journal leaves it null forever and the
room path fails closed). Public method `identity()` returning that object or `null`.

### 2d. Direct-send op surface

```js
    // Room-op sends are deliberately NOT queued: a stale agent_invite delivered
    // minutes after a reconnect would fire a consent prompt nobody asked for.
    // Connected-or-refuse, same stance as the ephemerals.
    sendRoomOp(frame) {
      try {
        if (!connected || !ws || ws.readyState !== 1) return false;
        ws.send(JSON.stringify(frame));
        return true;
      } catch { return false; }
    },
```

(Callers build the exact frames — the invite manager in Task 3 owns shapes.)

### 2e. HTTP GETs (Bearer `token`, base `mediaHttpBaseUrl`, `null` on any failure — the `uploadMedia` convention)

- `fetchRoster()` → `GET /roster` → parsed `{agents, conversations}` or `null`.
- `fetchMessages(convoId, { beforeSeq = null, limit = 50 } = {})` →
  `GET /convo/:id/messages?before_seq&limit` (omit `before_seq` when null) → parsed
  `{events}` or `null`. Both with a 10s `AbortController` timeout (copy the
  `fetchMedia` shape, `:577-613`).

### 2f. `upsertConvo` summary

Add `summary` to the destructure + `if (summary !== undefined) frame.summary = summary;`
(`:619-638`) — same omit-don't-null discipline as `title`.

### 2g. noopPublisher

Add `sendRoomOp: () => false`, `identity: () => null`, `fetchRoster: async () => null`,
`fetchMessages: async () => null` (and nothing for the callbacks — they're options).

**Tests:** fake server pushes `hello_ok` with identity → `identity()` returns it; pushes
`{kind:'invite', event:'request', room_id:'r1', ...}` → `onInviteFrame` sees it; pushes
a malformed invite (no `event`) → ignored; server `onFrame` returns an error frame →
`onOpError` sees `{code, ref}`; `sendRoomOp` returns false before connect, true after,
frame arrives verbatim; roster/messages GETs: 200 happy path (Bearer header asserted),
non-200 → null, network refusal → null; `upsertConvo` with `summary` carries it,
without omits it; noop publisher exposes all four new methods.

**Commit:** `Publisher: room-op send + invite/error dispatch + identity + roster/messages GETs`

---

## Task 3 — `lib/agent-rooms.js`: persisted room registry

New module + `test/agent-rooms.test.js`. Pure, injectable `load`/`save` (timer-store
template); `index.js` will wire `~/.matron-bridge-agent-rooms.json` in Task 6.

```js
// Persisted registry of agent-chat rooms this bridge participates in.
// A "room" here is a journal conversation (top-level UUID) plus this
// bridge's relationship to it: which local session it is bound to, whether
// we created it (owner) or were invited (guest), and where the invite
// lifecycle stands. Survives restarts so room delivery resumes (spec:
// agent chat phase 3, "Room↔session mapping persisted to disk").
export function createAgentRooms({ load, save, log = console } = {}) {
  let rooms = {};
  try { rooms = load?.() || {}; } catch { rooms = {}; }
  if (typeof rooms !== 'object' || rooms === null || Array.isArray(rooms)) rooms = {};

  function persist() {
    try { save?.(rooms); } catch (e) { try { log.warn(`[agent-rooms] persist failed: ${e.message}`); } catch { } }
  }

  return {
    // role: 'owner'|'guest'; state: 'pending'|'joined'|'refused'|'left'|'expired'
    record(roomId, { role, state, sessionRoomId, peerDeviceId = null, peerName = null, topic = null, title = null }) {
      rooms[roomId] = {
        ...rooms[roomId],
        role, state, sessionRoomId,
        peerDeviceId, peerName, topic, title,
        updatedAt: Date.now(),
        createdAt: rooms[roomId]?.createdAt ?? Date.now(),
      };
      persist();
      return rooms[roomId];
    },
    setState(roomId, state) {
      if (!rooms[roomId]) return null;
      rooms[roomId] = { ...rooms[roomId], state, updatedAt: Date.now() };
      persist();
      return rooms[roomId];
    },
    rebindSession(fromSessionRoomId, toSessionRoomId) {
      // Session respawn carry-forward (same reason as queueRelease.carryForward).
      let n = 0;
      for (const [id, r] of Object.entries(rooms)) {
        if (r.sessionRoomId === fromSessionRoomId) { rooms[id] = { ...r, sessionRoomId: toSessionRoomId }; n++; }
      }
      if (n) persist();
      return n;
    },
    get(roomId) { return rooms[roomId] || null; },
    isActive(roomId) {
      const r = rooms[roomId];
      return !!r && (r.state === 'joined' || r.state === 'pending');
    },
    forSession(sessionRoomId) {
      return Object.entries(rooms)
        .filter(([, r]) => r.sessionRoomId === sessionRoomId)
        .map(([id, r]) => ({ roomId: id, ...r }));
    },
    remove(roomId) { if (rooms[roomId]) { delete rooms[roomId]; persist(); } },
    list() { return Object.entries(rooms).map(([id, r]) => ({ roomId: id, ...r })); },
  };
}
```

**Tests** (fakeFs-free — inject `load`/`save` as plain fns recording calls, the
`recent-folders` test style): record/get/list round-trip; corrupt load → `{}`;
`setState` on unknown id → null, no persist; `rebindSession` moves all matching
rooms and persists once per call; `isActive` truth table; save-throw swallowed;
every mutation persists (assert `save` call count).

**Commit:** `agent-rooms: persisted room↔session registry`

---

## Task 4 — `lib/agent-invites.js`: invite lifecycle + correlation

New module + `test/agent-invites.test.js`. Owns (a) building/sending the five room-op
frames, (b) one-shot waiters so tool calls can await `delivered`/`ack`/`answer`, (c)
inbound `kind:'invite'` frame handling → registry updates + request-turn injection.
All side effects injected.

```js
import { randomUUID } from 'crypto';

const DEFAULT_ANSWER_WAIT_MS = 10_000;   // idle peer: wait briefly for the answer
const DEFAULT_DELIVER_WAIT_MS = 5_000;   // delivered/offline/error resolution

// deps:
//   sendRoomOp(frame) -> bool        (publisher, Task 2d)
//   onOpError(cb)                    (wired by index.js from publisher option)
//   rooms                            (agent-rooms registry, Task 3)
//   injectRequestTurn(room, kind, info)  kind: 'invite'|'join_request'
//   notifyRoom(roomId, text)         inject an FYI turn into the bound session
//   log
export function createAgentInvites({ sendRoomOp, rooms, injectRequestTurn, notifyRoom, log = console } = {}) {
  // waiters: roomId -> [{events:Set<string>, resolve, timer}]
  const waiters = new Map();

  function awaitEvent(roomId, events, timeoutMs) {
    return new Promise((resolve) => {
      const entry = { events: new Set(events), resolve, timer: null };
      entry.timer = setTimeout(() => {
        unhook(roomId, entry);
        resolve({ kind: 'timeout' });
      }, timeoutMs);
      entry.timer.unref?.();
      if (!waiters.has(roomId)) waiters.set(roomId, []);
      waiters.get(roomId).push(entry);
    });
  }
  function unhook(roomId, entry) {
    const list = waiters.get(roomId) || [];
    const i = list.indexOf(entry);
    if (i >= 0) list.splice(i, 1);
    if (list.length === 0) waiters.delete(roomId);
  }
  function settle(roomId, key, value) {
    for (const entry of [...(waiters.get(roomId) || [])]) {
      if (entry.events.has(key)) {
        clearTimeout(entry.timer);
        unhook(roomId, entry);
        entry.resolve(value);
      }
    }
  }

  return {
    // ---- outbound (tool-call side) ----
    async invite({ roomId, targetDeviceId, topic, justification }) {
      if (!sendRoomOp({ op: 'agent_invite', room_id: roomId, target_device_id: targetDeviceId, ...(topic ? { topic } : {}), justification })) {
        return { kind: 'error', code: 'journal_unreachable' };
      }
      // Journal answers with EITHER an error frame (ref:'agent_invite') OR
      // {event:'delivered'}; then ack/answer follow on their own schedule.
      const delivered = await awaitEvent(roomId, ['delivered', 'error:agent_invite'], DEFAULT_DELIVER_WAIT_MS);
      if (delivered.kind !== 'delivered') return delivered;
      const outcome = await awaitEvent(roomId, ['ack', 'answer'], DEFAULT_ANSWER_WAIT_MS);
      if (outcome.kind === 'ack' && outcome.sessionState === 'busy') return { kind: 'pending_busy' };
      if (outcome.kind === 'ack') {
        // idle ack — the real answer should be close behind; wait once more
        const answer = await awaitEvent(roomId, ['answer'], DEFAULT_ANSWER_WAIT_MS);
        return answer.kind === 'timeout' ? { kind: 'pending_idle' } : answer;
      }
      if (outcome.kind === 'timeout') return { kind: 'pending_quiet' };
      return outcome; // answer
    },
    async join({ roomId, justification }) {
      if (!sendRoomOp({ op: 'agent_join', room_id: roomId, justification })) {
        return { kind: 'error', code: 'journal_unreachable' };
      }
      const delivered = await awaitEvent(roomId, ['delivered', 'error:agent_join'], DEFAULT_DELIVER_WAIT_MS);
      if (delivered.kind !== 'delivered') return delivered;
      const outcome = await awaitEvent(roomId, ['ack', 'answer'], DEFAULT_ANSWER_WAIT_MS);
      if (outcome.kind === 'ack' && outcome.sessionState === 'busy') return { kind: 'pending_busy' };
      if (outcome.kind === 'ack') {
        const answer = await awaitEvent(roomId, ['answer'], DEFAULT_ANSWER_WAIT_MS);
        return answer.kind === 'timeout' ? { kind: 'pending_idle' } : answer;
      }
      if (outcome.kind === 'timeout') return { kind: 'pending_quiet' };
      return outcome;
    },
    ack({ roomId, peerDeviceId = null, sessionState }) {
      return sendRoomOp({ op: 'agent_invite_ack', room_id: roomId, ...(peerDeviceId != null ? { peer_device_id: peerDeviceId } : {}), session_state: sessionState });
    },
    answer({ roomId, peerDeviceId = null, accept, reason }) {
      return sendRoomOp({ op: 'agent_invite_answer', room_id: roomId, ...(peerDeviceId != null ? { peer_device_id: peerDeviceId } : {}), accept, ...(reason ? { reason } : {}) });
    },
    leave({ roomId }) {
      return sendRoomOp({ op: 'agent_leave', room_id: roomId });
    },

    // ---- inbound (wired as publisher onInviteFrame / onOpError) ----
    onInviteFrame(frame) {
      const { event, room_id: roomId } = frame;
      if (event === 'delivered') { settle(roomId, 'delivered', { kind: 'delivered' }); return; }
      if (event === 'ack') { settle(roomId, 'ack', { kind: 'ack', sessionState: frame.session_state }); return; }
      if (event === 'answer') {
        const value = frame.accept
          ? { kind: 'accepted', peerDeviceId: frame.peer_device_id }
          : { kind: 'refused', reason: frame.reason || (frame.from_device_id == null ? 'expired' : ''), peerDeviceId: frame.peer_device_id };
        const room = rooms.get(roomId);
        if (room) {
          rooms.setState(roomId, frame.accept ? 'joined' : (value.reason === 'expired' ? 'expired' : 'refused'));
          // Late answers (after the tool stopped waiting) surface as a turn.
          if (!settleReturns(roomId, 'answer', value) && notifyRoom) {
            const what = frame.accept ? 'accepted the chat' : `refused the chat${value.reason ? `: ${value.reason}` : ''}`;
            try { notifyRoom(roomId, what); } catch { }
          }
        } else {
          settle(roomId, 'answer', value);
        }
        return;
      }
      if (event === 'request' || event === 'join_request') {
        try { injectRequestTurn(frame); } catch (e) { try { log.warn(`[agent-invites] injectRequestTurn threw: ${e.message}`); } catch { } }
        return;
      }
      if (event === 'left') {
        const room = rooms.get(roomId);
        if (room && notifyRoom) { try { notifyRoom(roomId, 'left the room'); } catch { } }
        return;
      }
    },
    onOpError({ code, ref, detail }) {
      // Correlate op errors back to the newest waiter for that op family.
      // Room ops are serialized per tool call, so ref-level granularity is
      // enough; the roomId isn't in the error frame.
      if (ref !== 'agent_invite' && ref !== 'agent_join') return;
      for (const [roomId] of waiters) {
        settle(roomId, `error:${ref}`, { kind: 'error', code, detail });
      }
    },
  };

  // settle() variant that reports whether anyone was waiting.
  function settleReturns(roomId, key, value) {
    const had = (waiters.get(roomId) || []).some((e) => e.events.has(key));
    settle(roomId, key, value);
    return had;
  }
}
```

**Correctness notes for the implementer (design intent, verify while implementing):**
- The `error:<op>` correlation is coarse (error frames carry `ref` but not `room_id`).
  Room ops are only ever in flight one-at-a-time per tool call, and tool calls
  serialize per session, so this is acceptable for v1. If the implementer finds a
  cleaner correlation (e.g. Task 1 also adding `room_id` to `fail()` for these ops),
  flag it as an **Important finding** rather than changing the journal unilaterally.
- `injectRequestTurn(frame)` and `notifyRoom(roomId, text)` are index.js-side seams
  (Task 6); tests drive them as `vi.fn()`.
- Hoist `settleReturns` above the `return` or convert to a function declaration —
  the sketch above references it before definition; function declarations hoist,
  so declare it as `function settleReturns(...)` INSIDE the factory before `return`.

**Tests:** happy invite path (send → delivered → ack idle → answer accept ⇒
`{kind:'accepted'}` and registry `joined`… registry updates happen in
`onInviteFrame`, so drive frames in the test); busy ack ⇒ `pending_busy`; refusal
with reason; expiry answer (no `from_device_id`) ⇒ reason `'expired'`, state
`'expired'`; offline error frame ⇒ `{kind:'error', code:'offline'}`; timeout ⇒
`pending_quiet`; late answer with no waiter ⇒ `notifyRoom` called; `request` /
`join_request` ⇒ `injectRequestTurn` called with the frame; sendRoomOp false ⇒
`journal_unreachable` without waiting; waiter cleanup (no leaks — `waiters` empty
after each scenario; expose nothing, assert indirectly via double-settle safety).
Use fake timers (`vi.useFakeTimers()`) for the timeout paths.

**Commit:** `agent-invites: room-op lifecycle, correlation waits, inbound invite handling`

---

## Task 5 — `lib/room-delivery.js`: hybrid idle/busy room-message delivery

New module + `test/room-delivery.test.js`. Implements the spec's delivery model:
idle session → one immediate turn per message; busy session → messages accumulate
and flush as ONE coalesced "room update" turn when the turn ends. Pending inbox is
in-memory only (same stance as the router's prompt state — a restart loses pending
room messages, but the room's content is durable in the journal and
`agent_chat_read` recovers it; document this in the module header).

```js
// deps:
//   isBusy(session) -> bool                     (reads session.busy)
//   injectTurn(session, text) -> bool           (sendTextToSession skipJournalMirror)
//   log
export function createRoomDelivery({ isBusy, injectTurn, log = console } = {}) {
  // sessionKey -> [{roomId, roomTitle, from, body, at}]
  const pending = new Map();

  function formatOne(m) {
    return `[room "${m.roomTitle || m.roomId}"] ${m.from}: ${m.body}`;
  }

  return {
    deliver(session, sessionKey, m) {
      if (!session || !session.alive) return false;
      if (isBusy(session)) {
        if (!pending.has(sessionKey)) pending.set(sessionKey, []);
        pending.get(sessionKey).push(m);
        return true;
      }
      return injectTurn(session, formatOne(m));
    },
    // Called from every turn-end seam AFTER session.busy goes false and the
    // ordinary busy-queue flush ran (room updates yield to Dan's queued input).
    flush(session, sessionKey) {
      const list = pending.get(sessionKey);
      if (!list || list.length === 0) return false;
      pending.delete(sessionKey);
      if (!session || !session.alive) return false;
      const byRoom = new Map();
      for (const m of list) {
        if (!byRoom.has(m.roomId)) byRoom.set(m.roomId, []);
        byRoom.get(m.roomId).push(m);
      }
      const sections = [...byRoom.values()].map((ms) =>
        [`[room "${ms[0].roomTitle || ms[0].roomId}"] ${ms.length} message${ms.length === 1 ? '' : 's'} while you were working:`,
          ...ms.map((m) => `  ${m.from}: ${m.body}`)].join('\n'));
      return injectTurn(session, sections.join('\n\n'));
    },
    pendingCount(sessionKey) { return pending.get(sessionKey)?.length || 0; },
    dropSession(sessionKey) { pending.delete(sessionKey); },
    carryForward(fromKey, toKey) {
      const list = pending.get(fromKey);
      if (list) { pending.delete(fromKey); pending.set(toKey, list); }
    },
  };
}
```

**Message shaping (done by the caller, Task 6):** `from` is the attributed sender —
`«name» (agent)` for `agent:<name>` senders, `«username»` for `user:<name>`; `body`
is the text body, or for file/image frames a one-line description
`[sent ${kind} "${name}"${caption ? `: ${caption}` : ''}]` — room attachments are
delivered to sessions as text descriptions in v1 (the room itself renders them for
Dan; the agent can fetch content later if a use case appears).

**Tests:** idle → injectTurn once per message with the `[room "title"] from: body`
shape; busy → accumulates, injectTurn NOT called; flush after busy → exactly one
injectTurn, multi-room messages grouped into sections, pending cleared; flush with
dead session → pending dropped, no inject; deliver to dead session → false;
carryForward moves pending; injectTurn refusal (returns false) on flush → reported
false (messages are NOT re-queued — document: one delivery attempt, journal is the
durable copy).

**Commit:** `room-delivery: hybrid idle/busy coalescing for room messages`

---

## Task 6 — router carve-out + index.js room wiring

The core integration task. Serialized — touches `lib/journal-input-router.js` and
`index.js`.

### 6a. Router carve-out (`lib/journal-input-router.js`)

New injected seams (add BEFORE `log` in the deps destructure — the source-inspection
pins in `test/journal-input-router.test.js:648+` require new seams to appear before
`log: console,` in index.js's call):
- `roomFor(convoId)` → registry record or null (Task 3 `get()` + `isActive` check at
  the call site in index.js).
- `routeRoomFrame(room, frame)` → the room delivery path (index.js glue → Task 5).
- `selfAgentName()` → this bridge's device name or null (publisher `identity()?.name`).

Insert the carve-out ABOVE the `user:*` loop guard (`:311-320`), after the
prompt-bookkeeping block (`:298-309`):

```js
      // Agent-chat room carve-out (spec: agent chat phase 3). Frames in a
      // conversation this bridge participates in as a room are session input
      // even when agent-sent — that's the whole point of a room. Own echoes
      // are dropped by device name; unknown identity fails CLOSED (drop +
      // warn once) rather than risk a self-echo loop.
      const room = typeof roomFor === 'function' ? roomFor(convoId) : null;
      if (room) {
        if (!INPUT_TYPES.has(type) && !MEDIA_TYPES.has(type)) return;
        if (type === 'prompt_reply') return; // prompt flows never route through rooms
        if (typeof sender !== 'string') return;
        if (sender.startsWith('agent:')) {
          const self = typeof selfAgentName === 'function' ? selfAgentName() : null;
          if (!self) {
            warnOnceNoIdentity();
            return;
          }
          if (sender === `agent:${self}`) return; // own echo
        } else if (!sender.startsWith('user:')) {
          return;
        }
        if (typeof routeRoomFrame === 'function') {
          try { routeRoomFrame(room, frame); } catch (e) { warn(`[journal-input] routeRoomFrame threw: ${e.message}`); }
        }
        return;
      }
```

`warnOnceNoIdentity` is a module-level one-shot (`let warnedNoIdentity = false`)
mirroring the publisher's overflow warn pattern.

**Ordering caveat for the implementer:** the prompt-bookkeeping block at `:298-309`
must keep running for room frames too? NO — room convos never carry prompts
(`prompt` frames are bridge-published into its OWN session convo). Place the
carve-out after that block anyway (it's convo-scoped bookkeeping; harmless), and
return before the `user:*` guard so main-convo behavior is untouched.

### 6b. index.js wiring

1. **Stores** (near the timer store, `index.js:6773-6788`):
```js
const AGENT_ROOMS_FILE = path.join(os.homedir(), '.matron-bridge-agent-rooms.json');
const agentRooms = createAgentRooms({
  load: () => (fs.existsSync(AGENT_ROOMS_FILE) ? JSON.parse(fs.readFileSync(AGENT_ROOMS_FILE, 'utf-8')) : null),
  save: (data) => atomicWriteFileSync(AGENT_ROOMS_FILE, JSON.stringify(data, null, 2)),
  log: console,
});
```
   NOTE: module-load order — `createJournalPublisher` runs at `index.js:298`; the
   invites manager must exist before the publisher options reference it. Pattern:
   declare `let agentInvites = null;` before publisher construction, pass
   `onInviteFrame: (f) => agentInvites?.onInviteFrame(f)` and
   `onOpError: (e) => agentInvites?.onOpError(e)` as thunks, construct the manager
   later (where the router consumer is built).

2. **Room delivery instance**:
```js
const roomDelivery = createRoomDelivery({
  isBusy: (session) => !!session.busy,
  injectTurn: (session, text) => sendTextToSession(session, text, { skipJournalMirror: true }),
});
```

3. **Turn-end flush** — all three seams, immediately AFTER the existing
   `flushPendingSessionQueue(session)` calls (`index.js:2016-2019` iv,
   `:3372-3375` print, `:1666` codex):
   `roomDelivery.flush(session, session.roomId);`

4. **routeRoomFrame glue** (new function near `journalOnText`):
```js
function journalOnRoomFrame(room, frame) {
  const session = sessions.get(room.sessionRoomId);
  if (!session || !session.alive) {
    debug(`room frame for ${frame.convo_id} but session ${room.sessionRoomId} not live — dropping (agent_chat_read recovers)`);
    return;
  }
  const sender = frame.sender || '';
  const from = sender.startsWith('agent:') ? `${sender.slice(6)} (agent)` : sender.startsWith('user:') ? sender.slice(5) : sender;
  const payload = frame.payload || {};
  let body;
  if (frame.type === 'text') {
    body = typeof payload.body === 'string' ? payload.body.trim() : '';
  } else {
    const kind = frame.type === 'image' ? 'image' : 'file';
    body = `[sent ${kind} "${payload.name || 'unnamed'}"${payload.caption ? `: ${payload.caption}` : ''}]`;
  }
  if (!body) return;
  roomDelivery.deliver(session, session.roomId, {
    roomId: frame.convo_id, roomTitle: room.title || room.topic || null, from, body, at: frame.ts,
  });
}
```

5. **Router deps** (`index.js:6822-6864`, before `log: console,`):
```js
    roomFor: (convoId) => (agentRooms.isActive(convoId) ? agentRooms.get(convoId) : null),
    routeRoomFrame: journalOnRoomFrame,
    selfAgentName: () => journalPublisher.identity()?.name || null,
```

6. **Invite manager construction + request-turn injection** (near the consumer):
```js
agentInvites = createAgentInvites({
  sendRoomOp: journalPublisher.sendRoomOp,
  rooms: agentRooms,
  injectRequestTurn: journalInjectInviteRequest,
  notifyRoom: journalNotifyRoomEvent,
});

function journalInjectInviteRequest(frame) {
  // request  -> a peer wants THIS bridge's session to join frame.room_id
  // join_request -> a peer asks to join a room THIS bridge owns
  const isJoin = frame.event === 'join_request';
  const room = agentRooms.get(frame.room_id);
  const session = resolveInviteTargetSession(frame, room);
  if (!session) { debug(`invite ${frame.event} for ${frame.room_id} — no live session to ask`); return; }
  agentRooms.record(frame.room_id, {
    role: isJoin ? 'owner' : 'guest',
    state: 'pending',
    sessionRoomId: session.roomId,
    peerDeviceId: frame.from_device_id, peerName: frame.from_name || null,
    topic: frame.topic || null,
    title: room?.title || null,
  });
  agentInvites.ack({ roomId: frame.room_id, peerDeviceId: isJoin ? frame.from_device_id : null, sessionState: session.busy ? 'busy' : 'idle' });
  const who = frame.from_name ? `"${frame.from_name}"` : `device ${frame.from_device_id}`;
  const ask = isJoin
    ? `Agent ${who} asks to join your room ${frame.room_id}: ${frame.justification}`
    : `Agent ${who} requests a chat (room ${frame.room_id})${frame.topic ? ` about "${frame.topic}"` : ''}: ${frame.justification}`;
  const text = `${ask}\nAccept with agent_chat_accept("${frame.room_id}") or refuse with agent_chat_refuse("${frame.room_id}", reason). This is a request from another agent, not from your user.`;
  roomDelivery.deliver(session, session.roomId, { roomId: frame.room_id, roomTitle: room?.title || frame.topic || null, from: 'bridge', body: text, at: Date.now() });
}
```
   `resolveInviteTargetSession(frame, room)`:
   - `join_request` → the session bound to the room we own:
     `room ? sessions.get(room.sessionRoomId) : null`.
   - `request` → the target session is the one the invite is FOR. Phase 2 delivers
     invites per-device, not per-session; v1 rule: a bridge runs sessions, the
     invite carries no session address, so route to the session whose journal
     convo the caller targeted... it did not target one. **v1 decision (spec §Room
     lifecycle step 1: target is "the session behind convo X"): the caller picks a
     target *conversation*; the journal resolves it to the owning device. The
     invite frame does not carry that convo id, so the receiving bridge cannot
     know which of its sessions was meant when it runs more than one.** Handle:
     if exactly one live session exists, use it; otherwise use the most recently
     active live session (`session.lastActivityAt` max) and include the room id in
     the request text (already present) so the agent can hand off. Flag in PR
     description as a known v1 coarseness — fixing it properly means carrying
     `target_convo_id` through `agent_invite`, a small Phase 3.5 journal addition.
   `journalNotifyRoomEvent(roomId, text)`:
```js
function journalNotifyRoomEvent(roomId, text) {
  const room = agentRooms.get(roomId);
  if (!room) return;
  const session = sessions.get(room.sessionRoomId);
  if (!session || !session.alive) return;
  roomDelivery.deliver(session, session.roomId, { roomId, roomTitle: room.title || null, from: 'bridge', body: `Room ${roomId}: the peer ${text}.`, at: Date.now() });
}
```

7. **Session teardown/respawn**: at every terminal teardown that calls
   `journalEvictConvoInput` (`index.js:575, 1277, 1367, 1863, 1974, 4981, 7964`),
   also `roomDelivery.dropSession(session.roomId)`. At the convo-id/room
   carry-forward sites (`index.js:1320, 1910, 7799`) also
   `agentRooms.rebindSession(oldRoomId, newRoomId)` +
   `roomDelivery.carryForward(oldRoomId, newRoomId)` — read each site first;
   rebind keys are bridge session roomIds, which do NOT change at those sites
   (convo ids do). Verify: only rebind where `session.roomId` actually changes
   (agent switch `:7632` region and mode-swap region if they remap; if none do,
   note it in the commit message and skip).

**Tests (Task 6):** router unit tests (new describes in
`test/journal-input-router.test.js`): agent frame in an active room routes to
`routeRoomFrame`; own-echo (`agent:self`) dropped; unknown identity → dropped +
warned once; user frame in active room → `routeRoomFrame` (not
`routeTextToSession`); frame in inactive (refused) room → falls through to normal
guard (agent frame dropped); prompt_reply in a room convo → dropped; non-room
convos completely unaffected (existing tests stay green — the
`['prompt','tool_output',...]` enumeration test at `:105-113` needs no change
because those frames still drop). Source-inspection pin updates if the wiring
regexes require the new seams. `node --check index.js` + full `npm test`.

**Commit:** `Router room carve-out + hybrid delivery wiring + invite request turns`

---

## Task 7 — `lib/agent-chat.js`: the eight tool handlers (loopback side)

New module + `test/agent-chat.test.js`. One factory returning all handlers, each
`async (data) => ({status, body})` (Global constraint 2). `send_attachment` gains
`room_id` in the same task (small edit to `lib/send-attachment.js`).

```js
import { randomUUID } from 'crypto';

const ROOM_TITLE_MAX = 120;
const WAIT_SECONDS_CAP = 60;

// deps: sessions, publisher, rooms, invites, journalConvoIdFor,
//       awaitRoomMessage(chatRoomId, ms) -> Promise<{from, body}|null>,
//       serverLabel (bridge host label, e.g. '2'), log
export function createAgentChatHandlers({ sessions, publisher, rooms, invites, journalConvoIdFor, awaitRoomMessage = async () => null, serverLabel = '', log = console } = {}) {

  function callerSession(data) {
    const { roomId } = data || {};
    if (!roomId || typeof roomId !== 'string') return { err: { status: 400, body: { error: 'roomId is required' } } };
    const session = sessions.get(roomId);
    if (!session) return { err: { status: 404, body: { error: `no active session for chat ${roomId}` } } };
    return { session, sessionKey: roomId };
  }

  function boundRoom(chatRoomId, sessionKey, { mustBeJoined = true } = {}) {
    if (!chatRoomId || typeof chatRoomId !== 'string') return { err: { status: 400, body: { error: 'room_id is required' } } };
    const room = rooms.get(chatRoomId);
    if (!room || room.sessionRoomId !== sessionKey) return { err: { status: 404, body: { error: `not a participant of room ${chatRoomId}` } } };
    if (mustBeJoined && room.state !== 'joined' && room.role !== 'owner') {
      return { err: { status: 409, body: { error: `room ${chatRoomId} is ${room.state} — not joined` } } };
    }
    return { room };
  }

  return {
    async roster(data) {
      const { err } = callerSession(data);
      if (err) return err;
      const r = await publisher.fetchRoster();
      if (!r) return { status: 502, body: { error: 'journal unreachable' } };
      const self = publisher.identity();
      return { status: 200, body: {
        self: self ? { device_id: self.deviceId, name: self.name } : null,
        agents: (r.agents || []).filter((a) => !self || a.device_id !== self.deviceId),
        conversations: (r.conversations || []).map((c) => ({
          id: c.id, title: c.title, session_state: c.session_state,
          summary: c.summary || '', agent_device_id: c.agent_device_id, last_ts: c.last_ts,
        })),
      } };
    },

    async chatStart(data) {
      const { sessionKey, err } = callerSession(data);
      if (err) return err;
      const { target_convo_id: targetConvoId, topic, justification, message } = data;
      if (!targetConvoId || typeof targetConvoId !== 'string') return { status: 400, body: { error: 'target_convo_id is required — pick one from agent_roster' } };
      if (!justification || typeof justification !== 'string') return { status: 400, body: { error: 'justification is required' } };
      if (!message || typeof message !== 'string') return { status: 400, body: { error: 'message is required — the opening message for the room' } };
      const r = await publisher.fetchRoster();
      if (!r) return { status: 502, body: { error: 'journal unreachable' } };
      const target = (r.conversations || []).find((c) => c.id === targetConvoId);
      if (!target) return { status: 404, body: { error: `no conversation ${targetConvoId} in the roster` } };
      if (!Number.isInteger(target.agent_device_id)) return { status: 409, body: { error: 'that conversation has no owning agent to invite' } };
      const self = publisher.identity();
      if (self && target.agent_device_id === self.deviceId) return { status: 400, body: { error: 'that conversation is on this bridge — talk to it directly' } };

      const chatRoomId = randomUUID();
      const targetAgent = (r.agents || []).find((a) => a.device_id === target.agent_device_id);
      const title = `${self?.name || serverLabel || 'agent'} ↔ ${targetAgent?.name || `device ${target.agent_device_id}`}${topic ? ` — ${topic}` : ''}`.slice(0, ROOM_TITLE_MAX);
      publisher.upsertConvo(chatRoomId, { title, sessionState: 'running' });
      publisher.publishText(chatRoomId, { body: message, from: 'agent' });
      rooms.record(chatRoomId, { role: 'owner', state: 'pending', sessionRoomId: sessionKey, peerDeviceId: target.agent_device_id, peerName: targetAgent?.name || null, topic: topic || null, title });

      const outcome = await invites.invite({ roomId: chatRoomId, targetDeviceId: target.agent_device_id, topic, justification });
      return mapStartOutcome(chatRoomId, outcome);
    },

    async chatSend(data) {
      const { sessionKey, err } = callerSession(data);
      if (err) return err;
      const { room_id: chatRoomId, message, wait_seconds: waitSeconds } = data;
      const b = boundRoom(chatRoomId, sessionKey);
      if (b.err) return b.err;
      if (b.room.role !== 'owner' && b.room.state !== 'joined') return { status: 409, body: { error: `room ${chatRoomId} is ${b.room.state}` } };
      if (!message || typeof message !== 'string') return { status: 400, body: { error: 'message is required' } };
      publisher.publishText(chatRoomId, { body: message, from: 'agent' });
      // Optional short reply wait: purely convenience — replies always arrive
      // as turns regardless, so a timeout here loses nothing.
      const wait = Math.min(Math.max(Number(waitSeconds) || 0, 0), WAIT_SECONDS_CAP);
      if (wait > 0) {
        const reply = await awaitRoomMessage(chatRoomId, wait * 1000);
        if (reply) return { status: 200, body: { ok: true, reply } };
      }
      return { status: 200, body: { ok: true, note: 'sent — any reply will arrive as a later turn' } };
    },

    async chatAccept(data)  { return answerInvite(data, true); },
    async chatRefuse(data)  { return answerInvite(data, false); },

    async chatJoin(data) {
      const { sessionKey, err } = callerSession(data);
      if (err) return err;
      const { room_id: chatRoomId, justification } = data;
      if (!chatRoomId || typeof chatRoomId !== 'string') return { status: 400, body: { error: 'room_id is required' } };
      if (!justification || typeof justification !== 'string') return { status: 400, body: { error: 'justification is required' } };
      rooms.record(chatRoomId, { role: 'guest', state: 'pending', sessionRoomId: sessionKey });
      const outcome = await invites.join({ roomId: chatRoomId, justification });
      return mapStartOutcome(chatRoomId, outcome);
    },

    async chatLeave(data) {
      const { sessionKey, err } = callerSession(data);
      if (err) return err;
      const { room_id: chatRoomId } = data;
      const b = boundRoom(chatRoomId, sessionKey, { mustBeJoined: false });
      if (b.err) return b.err;
      invites.leave({ roomId: chatRoomId });
      rooms.setState(chatRoomId, 'left');
      return { status: 200, body: { ok: true } };
    },

    async chatRead(data) {
      const { sessionKey, err } = callerSession(data);
      if (err) return err;
      const { room_id: chatRoomId, limit } = data;
      const b = boundRoom(chatRoomId, sessionKey, { mustBeJoined: false });
      if (b.err) return b.err;
      const res = await publisher.fetchMessages(chatRoomId, { limit: Math.min(Math.max(Number(limit) || 50, 1), 200) });
      if (!res) return { status: 502, body: { error: 'journal unreachable or read refused' } };
      const messages = (res.events || [])
        .filter((e) => e.type === 'text' || e.type === 'file' || e.type === 'image')
        .map((e) => ({ sender: e.sender, type: e.type, ts: e.ts,
          body: e.type === 'text' ? e.payload?.body : `[${e.type} "${e.payload?.name || 'unnamed'}"]`,
          ...(e.payload?.caption ? { caption: e.payload.caption } : {}) }));
      return { status: 200, body: { room_id: chatRoomId, messages } };
    },
  };

  function mapStartOutcome(chatRoomId, outcome) {
    switch (outcome.kind) {
      case 'accepted':      return { status: 200, body: { room_id: chatRoomId, status: 'accepted' } };
      case 'refused':       return { status: 200, body: { room_id: chatRoomId, status: 'refused', reason: outcome.reason || '' } };
      case 'pending_busy':  return { status: 200, body: { room_id: chatRoomId, status: 'pending_busy', note: 'peer is mid-turn; continue your own work — the answer arrives as a later turn' } };
      case 'pending_idle':
      case 'pending_quiet': return { status: 200, body: { room_id: chatRoomId, status: 'pending', note: 'no answer yet; continue your own work — the answer arrives as a later turn' } };
      case 'error':
        if (outcome.code === 'offline') return { status: 200, body: { room_id: chatRoomId, status: 'offline', error: 'target bridge is offline' } };
        if (outcome.code === 'conflict') return { status: 409, body: { room_id: chatRoomId, error: outcome.detail || 'conflicting invite state' } };
        return { status: 502, body: { room_id: chatRoomId, error: outcome.detail || outcome.code || 'journal error' } };
      default:              return { status: 502, body: { room_id: chatRoomId, error: 'unexpected invite outcome' } };
    }
  }

  async function answerInvite(data, accept) {
    const { sessionKey, err } = callerSession(data);
    if (err) return err;
    const { room_id: chatRoomId, reason } = data;
    const room = rooms.get(chatRoomId);
    if (!room || room.sessionRoomId !== sessionKey) return { status: 404, body: { error: `no pending invite for room ${chatRoomId}` } };
    if (room.state !== 'pending') return { status: 409, body: { error: `room ${chatRoomId} is ${room.state} — nothing to answer` } };
    const ok = invites.answer({
      roomId: chatRoomId,
      // Owner answering a join_request names the requester; a guest answering
      // an invite addressed to itself omits peer_device_id (protocol.md).
      peerDeviceId: room.role === 'owner' ? room.peerDeviceId : null,
      accept, reason,
    });
    if (!ok) return { status: 502, body: { error: 'journal unreachable' } };
    rooms.setState(chatRoomId, accept ? 'joined' : 'refused');
    return { status: 200, body: { ok: true, room_id: chatRoomId, ...(accept ? {} : { refused: true }) } };
  }
}
```

**`awaitRoomMessage(chatRoomId, ms)`** is an injected dep provided by index.js in
Task 8: a tiny per-room once-listener registry fed from `journalOnRoomFrame`
(register before the timeout, resolve `{from, body}` on the first inbound room
message for that room, `null` on timeout, always unhook). This keeps the handler
module free of journal frame knowledge. Tests drive it as an injected fake. Note
`mapStartOutcome`/`answerInvite` are function declarations placed after the
factory's `return` — hoisting makes that legal; keep them as `function` declarations.

**`send_attachment` room param** (`lib/send-attachment.js` + `ask-user.js`): add
optional `chat_room_id` tool param; handler dep gains `rooms`; when present, validate
via the same `boundRoom` logic (joined-or-owner) and publish into that convo instead
of the session's own; error strings follow the existing table style.

**Tests** (fake `publisher` recording calls + canned `fetchRoster`/`fetchMessages`,
fake `invites` returning scripted outcomes, real `createAgentRooms` with in-memory
load/save, `sessions` = real Map with `{busy:false, alive:true}` literals — the
`send-attachment.test.js` style): per handler — happy path + each validation error;
`chatStart`: roster miss, self-target rejection, offline, busy, refused-with-reason,
accepted (assert upsert title + opening publish + registry record ORDER: upsert
before publish before invite); `chatSend`: not-joined 409, wait-reply path with fake
`awaitRoomMessage`; accept/refuse: direction rule (owner names peer, guest omits);
`chatRead`: event filtering + caption carry; roster: self excluded, `self` block
present.

**Commit:** `agent-chat: loopback handlers for the eight room tools (+ send_attachment room target)`

---

## Task 8 — index.js routes + ask-user.js MCP tools + guidance

### 8a. Loopback routes (`index.js`, standalone `if` blocks before `:7260`, the
`/send-attachment` shape)

Instantiate once near `handleSendAttachment` (`index.js:7045-7049`):
```js
const agentChatHandlers = createAgentChatHandlers({
  sessions, publisher: journalPublisher, rooms: agentRooms, invites: agentInvites,
  journalConvoIdFor, serverLabel: SERVER_LABEL,
});
```
Routes (each ≤7 lines, one `debug()` line each):
`POST /agent-roster` → `roster`; `POST /agent-chat-start` → `chatStart`;
`POST /agent-chat-send` → `chatSend`; `POST /agent-chat-accept` → `chatAccept`;
`POST /agent-chat-refuse` → `chatRefuse`; `POST /agent-chat-join` → `chatJoin`;
`POST /agent-chat-leave` → `chatLeave`; `POST /agent-chat-read` → `chatRead`.

### 8b. MCP tools (`ask-user.js`)

Eight `server.tool(...)` declarations following the `send_attachment` body shape
(POST, parse JSON, `data.error` fallback). Tool descriptions are product surface —
write them to the spec's etiquette:

- `agent_roster` — "List this user's other agent sessions (boxes, conversation
  titles, states, rolling summaries) so you can pick a target for agent_chat_start.
  Excludes yourself."
- `agent_chat_start(target_convo_id, topic?, justification, message)` — description
  MUST include: "If the result is pending or pending_busy, do NOT wait or poll:
  continue your own work — the answer and any replies arrive automatically as later
  turns." Params via zod: `target_convo_id` string, `topic` optional string,
  `justification` string, `message` string.
- `agent_chat_send(room_id, message, wait_seconds?)` — "Send a message into an agent
  chat room. Keep room messages concise and coordination-focused: outcomes,
  questions, decisions — not running commentary. Optional wait_seconds (max 60)
  briefly waits for a quick reply when the peer is idle; replies always arrive as
  later turns regardless, so never poll."
- `agent_chat_accept(room_id)` / `agent_chat_refuse(room_id, reason?)` — "Answer a
  chat request another agent sent you." Refuse: reason is relayed to the caller.
- `agent_chat_join(room_id, justification)` — "Ask to join an existing room by id
  (e.g. one your user handed you)."
- `agent_chat_leave(room_id)` — "Leave a room. The room and its history remain
  visible to your user."
- `agent_chat_read(room_id, limit?)` — "Read recent messages from a room you
  participate in — inbox-style catch-up mid-turn."

Success text per tool = short English from the body (e.g. chatStart:
`Room ${body.room_id}: ${body.status}${body.reason ? ` — ${body.reason}` : ''}${body.note ? `. ${body.note}` : ''}`).

### 8c. `BRIDGE_CLAUDE.md`

Add a short "Agent-to-agent chat" section after the existing tool list
(`BRIDGE_CLAUDE.md:25-27`): what rooms are, the no-polling rule, the etiquette
line, and that room working-output stays in the agent's own conversation (only
`agent_chat_send`/`send_attachment` post to the room). ≤15 lines.

### 8d. package.json

Append `node --check` entries for `lib/agent-rooms.js`, `lib/agent-invites.js`,
`lib/room-delivery.js`, `lib/agent-chat.js`.

**Tests:** `test/mcp-config.test.js` frozen fixtures unaffected (no mcp-config.json
change — ask-user server already registered). Add a source-inspection test in
`test/agent-chat.test.js` asserting all eight routes exist in `index.js`
(`readFileSync` + regex per route path — the `:648` pin style) and that
`ask-user.js` declares all eight tool names. Full `npm test` + `npm run check`.

**Commit:** `Agent chat MCP tools: routes, tool declarations, agent guidance`

---

## Task 9 — Gemini rolling summary → journal `summary`

Extend the existing title pass so the roster gains real summaries (spec: "the
existing title-generation pass additionally maintains a 2-3 sentence rolling
summary per conversation, upserted with the same don't-clobber discipline").

### 9a. Extract + extend the response parser

New export in `lib/journal-title-seed.js`:
```js
// Parses the Gemini title-pass response. ROSTER is the 2-3 sentence rolling
// conversation summary published to the journal (roster targeting metadata) —
// distinct from the bullet-list pinned summary the bridge keeps locally.
export function parseTitlePassResponse(text) {
  const t = typeof text === 'string' ? text : '';
  const title = t.match(/TITLE:\s*(.+)/i)?.[1]?.trim() || null;
  const summary = t.match(/SUMMARY:\s*(.+)/i)?.[1]?.trim() || null;
  const added = t.match(/NEW:\s*(.+)/i)?.[1]?.trim() || null;
  const roster = t.match(/ROSTER:\s*([\s\S]*?)(?:\n[A-Z]+:|$)/)?.[1]?.trim() || null;
  return { title, summary, added, roster };
}
```

### 9b. `maybeUpdatePinnedSummary` (`index.js:4647-4727`)

- Both prompt variants gain one more numbered item and one more format line:
  `ROSTER: <2-3 sentences describing what this session is working on right now,
  for other agents deciding whether to contact it>`. ROSTER must be the LAST
  format line in the prompt — the parser's multi-line capture stops at the next
  `KEY:` or end-of-text, so a field after it would be swallowed.
- Replace the three inline regexes with `parseTitlePassResponse(text)`.
- After the title emit:
```js
      if (parsed.roster) {
        journalUpsertConvo(session, { summary: parsed.roster.slice(0, 1000) });
      }
```
  Don't-clobber analysis (document in a comment): the journal's COALESCE keeps the
  existing summary whenever the field is omitted, and `journalUpsertConvo` only
  carries `summary` when the pass actually produced one. The seed path
  (`journal-title-seed.js:72`), the state-only path (`index.js:703`), and the
  hint-replay paths (`index.js:644`, `:1029`) never carry `summary` — Task 2f's
  omit-don't-null makes that automatic. No fallback summary when Gemini is off:
  roster shows `''`, honest.
- NOTE: `journalUpsertConvo` (`index.js:663-666`) sets `_journalTitleHint` only for
  `title` — no change needed, but the implementer must verify `summary` passes
  through `journalPublish` → `upsertConvo` unmodified.

**Tests:** `parseTitlePassResponse` unit tests in `test/journal-title-seed.test.js`
(all four fields; ROSTER multi-line capture stopping at the next `KEY:`; absent
fields → null; garbage → all null). Gemini itself stays untested (established
repo stance) — but add a source-inspection pin that `index.js` calls
`parseTitlePassResponse` and includes `ROSTER:` in the prompt string.

**Commit:** `Title pass: rolling ROSTER summary upserted to the journal`

---

## Task 10 — final review, PR polish, e2e notes

1. Full `npm run ci` (lint + check + test + audit) green. Known pre-existing macOS
   failure: `test/pre-trust.test.js` (`/var` vs `/private/var` realpath) — confirm
   it is the ONLY failure and note it, as Phase 1 did.
2. Whole-branch review (opus, code-reviewer agent): spec conformance sweep against
   "Bridge changes" + "Room lifecycle" + "Error handling"; loop-safety audit (can
   any published frame re-enter as input? own-echo guard coverage incl. identity-
   null); busy/idle race audit (message arriving in the gap between busy=false and
   flush); ONE fix wave + ONE scoped re-review.
3. PR description: task list, the v1 coarsenesses called out explicitly —
   (a) invite→session resolution when multiple sessions live (Task 6b),
   (b) coarse error-frame correlation (Task 4), (c) pending room inbox is
   in-memory, (d) room attachments delivered to sessions as text descriptions,
   (e) codex sessions get no MCP tools (pre-existing; rooms are Claude-only v1).
4. E2E (manual, after Dan merges + deploys journal Task 1 to dev-2): two bridges
   (this Mac + dev-2 or a second local bridge with a second agent token), scripted:
   roster → chat_start → accept → send both ways → send_attachment into room →
   Dan message fans to both → leave. Record transcript in the PR. DO NOT deploy
   anything to run this — coordinate with Dan.

**Deliverable: both PRs open (journal Task 1 + bridge), everything pushed, review
clean, merge/deploy awaiting Dan.**


