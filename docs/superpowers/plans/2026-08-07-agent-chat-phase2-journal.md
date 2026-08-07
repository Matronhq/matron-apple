# Agent Chat Phase 2 — Journal Rooms Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the participants table, agent write tightening, invite/join lifecycle ops, invite expiry, the `summary` column, and the agent-accessible `/roster` endpoint to matron-journal, per the Phase 2 section of `docs/superpowers/specs/2026-08-06-agent-to-agent-chat-design.md` (matron-apple, branch `docs/agent-chat-spec`).

**Architecture:** A side room is an ordinary top-level conversation. One new table, `convo_agents`, records which agent devices are invited/joined/refused/left/expired per conversation and who initiated each invite. It drives two things: (1) delivery — `hub.broadcastJournal` and hello replay fan a conversation's frames to the owning agent device *plus* joined participants; (2) write authorization — a new `authorizeAgentWrite` gate (owner or joined participant; legacy NULL owner allowed) enforced on every agent write op. Invite/join/answer/leave are new WS ops relayed device-to-device through the hub (never journaled). `summary` rides the existing `convo_upsert` path and surfaces in `/snapshot` and the new `GET /roster`.

**Tech Stack:** Node ≥20 ESM, better-sqlite3, `ws`, `node:test` (`npm test`). No new dependencies.

**Repo / worktree:** Implementation happens in **matron-journal**. The local clone `~/Dev/matron-journal` is PARKED on `feat/preapproved-link-persistence` — NEVER switch its branch. Create a worktree instead:

```bash
git -C ~/Dev/matron-journal fetch origin
git -C ~/Dev/matron-journal worktree add /tmp/agent-chat-journal-wt -b feat/agent-chat-rooms origin/master
cd /tmp/agent-chat-journal-wt && npm install
```

## Global Constraints

- All schema changes are additive and in-place (`CREATE TABLE IF NOT EXISTS` in the `SCHEMA` const, or guarded `ALTER TABLE` in `openDb`) — the live dev-2 DB must migrate on next restart with zero manual steps, exactly like `apns_env`/`parent_convo_id` did.
- `convo_agents` has **no foreign keys** — same rationale as `conversations.agent_device_id` (see the comment in `src/db.js`): device revocation is a bare DELETE on `devices` and must never be blocked; a dangling device id simply matches no live connection.
- Legacy behavior preserved: a conversation with `agent_device_id IS NULL` keeps broadcast-to-all-agents delivery AND accepts writes from any of the user's agent devices.
- Error frames use the existing `fail(code, detail)` convention in `handleOp`. Codes reused: `forbidden`, `bad_request`, `not_found`, `not_ready` (RPC precedent). New codes: `conflict`, `offline`.
- Named caps (new consts in `src/ws.js`): `INVITE_TOPIC_MAX_CHARS = 200`, `INVITE_TEXT_MAX_CHARS = 1000` (justification and refusal reason), `SUMMARY_MAX_CHARS = 1000`. Invite TTL default: 30 minutes (`DEFAULT_INVITE_TTL_MS = 1800000`).
- Invite-lifecycle frames (`kind: 'invite'`) are ephemeral relays — never appended to the journal, never pushed (APNs), never sent to client devices.
- Everything stays scoped to the token's user (`who.userId` / `conn.userId`) like every existing endpoint — no new cross-user surface.
- Tests: `node:test` via `npm test`; integration tests use `startTestServer`/`makeWsClient` from `test/helpers.js`. The full suite must be green at the end of every task.
- Commit at the end of every task, from the worktree, with the file list explicit (`git add <files>`), message style matching repo history (`feat: …` / `test: …`).

---

### Task 1: `convo_agents` table + participants module

**Files:**
- Modify: `src/db.js` (add table to the `SCHEMA` const, after `link_preapprovals`)
- Create: `src/participants.js`
- Test: `test/participants.test.js`

**Interfaces:**
- Consumes: `openDb` from `src/db.js`.
- Produces (used by Tasks 2–8):
  - `inviteParticipant(db, { convoId, agentDeviceId, initiatorDeviceId, justification }) -> { ok: true } | { ok: false, state: string }`
  - `answerInvite(db, { convoId, agentDeviceId, accept, now? }) -> boolean`
  - `leaveConvo(db, { convoId, agentDeviceId, now? }) -> boolean`
  - `removeParticipant(db, convoId, agentDeviceId) -> void`
  - `joinedAgentIds(db, convoId) -> number[]`
  - `getParticipant(db, convoId, agentDeviceId) -> { state, initiator_device_id, justification, created_at, answered_at } | null`
  - `isParticipant(db, convoId, agentDeviceId) -> boolean` (any state)
  - `expireInvites(db, ttlMs, now?) -> Array<{ convo_id, agent_device_id, initiator_device_id }>`

- [ ] **Step 1: Add the table to the schema**

In `src/db.js`, append to the `SCHEMA` template string (after the `link_preapprovals` block, before the closing backtick):

```sql
CREATE TABLE IF NOT EXISTS convo_agents(
  convo_id TEXT NOT NULL,
  agent_device_id INTEGER NOT NULL,
  initiator_device_id INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('invited','joined','refused','left','expired')),
  justification TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  answered_at INTEGER,
  PRIMARY KEY(convo_id, agent_device_id)
);
```

Deliberately no foreign keys (see Global Constraints). `initiator_device_id` records who started this invite: the room owner (normal invite) or the participant itself (join request) — the *other* party is the one entitled to ack/answer it (Task 7).

- [ ] **Step 2: Write the failing tests**

Create `test/participants.test.js`:

```js
import test from 'node:test'
import assert from 'node:assert/strict'
import { openDb } from '../src/db.js'
import {
  inviteParticipant, answerInvite, leaveConvo, removeParticipant,
  joinedAgentIds, getParticipant, isParticipant, expireInvites,
} from '../src/participants.js'

const db = () => openDb(':memory:')

test('inviteParticipant creates a pending row', () => {
  const d = db()
  const r = inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'help me' })
  assert.deepEqual(r, { ok: true })
  const row = getParticipant(d, 'room', 2)
  assert.equal(row.state, 'invited')
  assert.equal(row.initiator_device_id, 1)
  assert.equal(row.justification, 'help me')
  assert.equal(row.answered_at, null)
})

test('inviteParticipant refuses while invited or joined, renews after refused/left/expired', () => {
  const d = db()
  inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'x' })
  assert.deepEqual(inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'y' }), { ok: false, state: 'invited' })
  answerInvite(d, { convoId: 'room', agentDeviceId: 2, accept: true })
  assert.deepEqual(inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'y' }), { ok: false, state: 'joined' })
  leaveConvo(d, { convoId: 'room', agentDeviceId: 2 })
  const renewed = inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 2, justification: 'again' })
  assert.deepEqual(renewed, { ok: true })
  const row = getParticipant(d, 'room', 2)
  assert.equal(row.state, 'invited')
  assert.equal(row.initiator_device_id, 2)
  assert.equal(row.justification, 'again')
  assert.equal(row.answered_at, null)
})

test('answerInvite flips only a pending row', () => {
  const d = db()
  inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'x' })
  assert.equal(answerInvite(d, { convoId: 'room', agentDeviceId: 2, accept: false }), true)
  assert.equal(getParticipant(d, 'room', 2).state, 'refused')
  assert.ok(getParticipant(d, 'room', 2).answered_at != null)
  // Already answered — a second answer is a no-op false.
  assert.equal(answerInvite(d, { convoId: 'room', agentDeviceId: 2, accept: true }), false)
  // No row at all.
  assert.equal(answerInvite(d, { convoId: 'room', agentDeviceId: 99, accept: true }), false)
})

test('leaveConvo flips only a joined row', () => {
  const d = db()
  inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'x' })
  assert.equal(leaveConvo(d, { convoId: 'room', agentDeviceId: 2 }), false, 'invited is not joined')
  answerInvite(d, { convoId: 'room', agentDeviceId: 2, accept: true })
  assert.equal(leaveConvo(d, { convoId: 'room', agentDeviceId: 2 }), true)
  assert.equal(getParticipant(d, 'room', 2).state, 'left')
})

test('joinedAgentIds returns only joined participants of that convo', () => {
  const d = db()
  inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'x' })
  inviteParticipant(d, { convoId: 'room', agentDeviceId: 3, initiatorDeviceId: 1, justification: 'x' })
  inviteParticipant(d, { convoId: 'other', agentDeviceId: 4, initiatorDeviceId: 1, justification: 'x' })
  answerInvite(d, { convoId: 'room', agentDeviceId: 3, accept: true })
  answerInvite(d, { convoId: 'other', agentDeviceId: 4, accept: true })
  assert.deepEqual(joinedAgentIds(d, 'room'), [3])
})

test('isParticipant is true for any state, removeParticipant deletes the row', () => {
  const d = db()
  inviteParticipant(d, { convoId: 'room', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'x' })
  answerInvite(d, { convoId: 'room', agentDeviceId: 2, accept: false })
  assert.equal(isParticipant(d, 'room', 2), true)
  assert.equal(isParticipant(d, 'room', 3), false)
  removeParticipant(d, 'room', 2)
  assert.equal(isParticipant(d, 'room', 2), false)
  assert.equal(getParticipant(d, 'room', 2), null)
})

test('expireInvites flips only stale pending rows and returns them', () => {
  const d = db()
  const now = Date.now()
  inviteParticipant(d, { convoId: 'stale', agentDeviceId: 2, initiatorDeviceId: 1, justification: 'x' })
  d.prepare('UPDATE convo_agents SET created_at=? WHERE convo_id=?').run(now - 10000, 'stale')
  inviteParticipant(d, { convoId: 'fresh', agentDeviceId: 3, initiatorDeviceId: 1, justification: 'x' })
  inviteParticipant(d, { convoId: 'done', agentDeviceId: 4, initiatorDeviceId: 1, justification: 'x' })
  answerInvite(d, { convoId: 'done', agentDeviceId: 4, accept: true })
  const expired = expireInvites(d, 5000, now)
  assert.deepEqual(expired, [{ convo_id: 'stale', agent_device_id: 2, initiator_device_id: 1 }])
  assert.equal(getParticipant(d, 'stale', 2).state, 'expired')
  assert.equal(getParticipant(d, 'fresh', 3).state, 'invited')
  assert.equal(getParticipant(d, 'done', 4).state, 'joined')
  // Second sweep finds nothing.
  assert.deepEqual(expireInvites(d, 5000, now), [])
})
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `node --test test/participants.test.js`
Expected: FAIL — `Cannot find module '../src/participants.js'`.

- [ ] **Step 4: Implement `src/participants.js`**

```js
// Participants ("grants") for agent chat rooms — the convo_agents table
// (spec: 2026-08-06 agent-to-agent chat design, Phase 2). A row means this
// agent device has been drawn into this conversation's lifecycle; only
// state='joined' confers delivery and write rights (see authorizeAgentWrite
// in auth.js and the fan-out in ws.js). initiator_device_id records who
// started the invite — the room owner (invite) or the participant itself
// (join request) — because the OTHER party is the one entitled to answer.

// Renewable states: an old outcome must not block a fresh invite, but a
// pending or accepted row must (double-invite is a caller bug worth
// surfacing, not silently resetting).
const RENEWABLE = new Set(['refused', 'left', 'expired'])

export function inviteParticipant(db, { convoId, agentDeviceId, initiatorDeviceId, justification = '' }) {
  const existing = db.prepare(
    'SELECT state FROM convo_agents WHERE convo_id=? AND agent_device_id=?'
  ).get(convoId, agentDeviceId)
  if (existing && !RENEWABLE.has(existing.state)) return { ok: false, state: existing.state }
  db.prepare(`
    INSERT INTO convo_agents(convo_id, agent_device_id, initiator_device_id, state, justification, created_at, answered_at)
    VALUES(?,?,?,'invited',?,?,NULL)
    ON CONFLICT(convo_id, agent_device_id) DO UPDATE SET
      initiator_device_id=excluded.initiator_device_id,
      state='invited',
      justification=excluded.justification,
      created_at=excluded.created_at,
      answered_at=NULL
  `).run(convoId, agentDeviceId, initiatorDeviceId, justification, Date.now())
  return { ok: true }
}

export function answerInvite(db, { convoId, agentDeviceId, accept, now = Date.now() }) {
  return db.prepare(
    "UPDATE convo_agents SET state=?, answered_at=? WHERE convo_id=? AND agent_device_id=? AND state='invited'"
  ).run(accept ? 'joined' : 'refused', now, convoId, agentDeviceId).changes > 0
}

export function leaveConvo(db, { convoId, agentDeviceId, now = Date.now() }) {
  return db.prepare(
    "UPDATE convo_agents SET state='left', answered_at=? WHERE convo_id=? AND agent_device_id=? AND state='joined'"
  ).run(now, convoId, agentDeviceId).changes > 0
}

// Undo of a just-created invite whose delivery failed (the target had no
// live socket when the request frame was sent) — the caller sees `offline`
// and the table must not keep a pending row nobody was told about.
export function removeParticipant(db, convoId, agentDeviceId) {
  db.prepare('DELETE FROM convo_agents WHERE convo_id=? AND agent_device_id=?').run(convoId, agentDeviceId)
}

export function joinedAgentIds(db, convoId) {
  return db.prepare(
    "SELECT agent_device_id FROM convo_agents WHERE convo_id=? AND state='joined'"
  ).all(convoId).map((r) => r.agent_device_id)
}

export function getParticipant(db, convoId, agentDeviceId) {
  return db.prepare(
    'SELECT state, initiator_device_id, justification, created_at, answered_at FROM convo_agents WHERE convo_id=? AND agent_device_id=?'
  ).get(convoId, agentDeviceId) ?? null
}

export function isParticipant(db, convoId, agentDeviceId) {
  return !!db.prepare(
    'SELECT 1 FROM convo_agents WHERE convo_id=? AND agent_device_id=?'
  ).get(convoId, agentDeviceId)
}

// Sweep half of invite expiry (ws.js owns the timer and the caller
// notification): flip stale pending rows and report them. RETURNING keeps
// flip-and-report atomic — no separate SELECT that a concurrent answer
// could race.
export function expireInvites(db, ttlMs, now = Date.now()) {
  return db.prepare(
    "UPDATE convo_agents SET state='expired', answered_at=? WHERE state='invited' AND created_at<=? RETURNING convo_id, agent_device_id, initiator_device_id"
  ).all(now, now - ttlMs)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `node --test test/participants.test.js`
Expected: PASS (8 tests).

- [ ] **Step 6: Run the full suite, then commit**

Run: `npm test` — must be green (the schema addition is additive; nothing else reads the table yet).

```bash
git add src/db.js src/participants.js test/participants.test.js
git commit -m "feat: convo_agents participants table + module (agent chat phase 2)"
```

---

### Task 2: `authorizeAgentWrite` in auth.js

**Files:**
- Modify: `src/auth.js` (add next to `authorize`, ~line 105)
- Test: `test/agent-write-auth.test.js`

**Interfaces:**
- Consumes: `convo_agents` rows (Task 1), `conversations` rows (created via `upsertConversation` from `src/journal.js`).
- Produces (used by Tasks 3, 7): `authorizeAgentWrite(db, userId, deviceId, convoId) -> boolean`.

- [ ] **Step 1: Write the failing tests**

Create `test/agent-write-auth.test.js`:

```js
import test from 'node:test'
import assert from 'node:assert/strict'
import { openDb } from '../src/db.js'
import { createUser, createAgent, authorizeAgentWrite } from '../src/auth.js'
import { upsertConversation } from '../src/journal.js'
import { inviteParticipant, answerInvite, leaveConvo } from '../src/participants.js'

async function fixture() {
  const db = openDb(':memory:')
  const dan = await createUser(db, 'dan', 'pw')
  const other = await createUser(db, 'eve', 'pw')
  const owner = createAgent(db, dan.id, 'dev-a')
  const peer = createAgent(db, dan.id, 'dev-b')
  const stranger = createAgent(db, other.id, 'dev-x')
  upsertConversation(db, { id: 'room', ownerUserId: dan.id, title: 'room', sessionState: 'running', agentDeviceId: owner.deviceId })
  return { db, dan, other, owner, peer, stranger }
}

test('owner device may write; a foreign agent device may not', async () => {
  const { db, dan, owner, peer } = await fixture()
  assert.equal(authorizeAgentWrite(db, dan.id, owner.deviceId, 'room'), true)
  assert.equal(authorizeAgentWrite(db, dan.id, peer.deviceId, 'room'), false)
})

test('joined participant may write; every other participant state may not', async () => {
  const { db, dan, peer, owner } = await fixture()
  inviteParticipant(db, { convoId: 'room', agentDeviceId: peer.deviceId, initiatorDeviceId: owner.deviceId, justification: 'x' })
  assert.equal(authorizeAgentWrite(db, dan.id, peer.deviceId, 'room'), false, 'invited is not joined')
  answerInvite(db, { convoId: 'room', agentDeviceId: peer.deviceId, accept: true })
  assert.equal(authorizeAgentWrite(db, dan.id, peer.deviceId, 'room'), true)
  leaveConvo(db, { convoId: 'room', agentDeviceId: peer.deviceId })
  assert.equal(authorizeAgentWrite(db, dan.id, peer.deviceId, 'room'), false, 'left loses write access')
})

test('legacy NULL-owner conversation accepts any of the user devices', async () => {
  const { db, dan, peer } = await fixture()
  db.prepare(
    'INSERT INTO conversations(id, owner_user_id, title, session_state, created_at) VALUES(?,?,?,?,?)'
  ).run('legacy', dan.id, 'old', 'running', Date.now())
  assert.equal(authorizeAgentWrite(db, dan.id, peer.deviceId, 'legacy'), true)
})

test('missing convo and cross-user convo both fail closed', async () => {
  const { db, dan, other, owner, stranger } = await fixture()
  assert.equal(authorizeAgentWrite(db, dan.id, owner.deviceId, 'nope'), false)
  assert.equal(authorizeAgentWrite(db, other.id, stranger.deviceId, 'room'), false)
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test test/agent-write-auth.test.js`
Expected: FAIL — `authorizeAgentWrite` is not exported.

- [ ] **Step 3: Implement**

In `src/auth.js`, directly below `authorize` (keep both — client paths keep the user-scoped check):

```js
// Agent write gate (spec: agent chat phase 2, the wrong-conversation
// tightening). An agent device may write into a conversation iff it is the
// recorded managing device (conversations.agent_device_id), a joined
// participant (convo_agents), or the conversation predates ownership
// recording (agent_device_id IS NULL — legacy broadcast rows). User scoping
// comes first, same as authorize(). Inline SQL rather than importing
// participants.js — auth.js stays dependency-free below argon2/crypto.
export function authorizeAgentWrite(db, userId, deviceId, convoId) {
  const row = db.prepare('SELECT owner_user_id, agent_device_id FROM conversations WHERE id=?').get(convoId)
  if (!row || row.owner_user_id !== userId) return false
  if (row.agent_device_id == null || row.agent_device_id === deviceId) return true
  return !!db.prepare(
    "SELECT 1 FROM convo_agents WHERE convo_id=? AND agent_device_id=? AND state='joined'"
  ).get(convoId, deviceId)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/agent-write-auth.test.js` — PASS (4 tests). Then `npm test` — green (nothing calls it yet).

- [ ] **Step 5: Commit**

```bash
git add src/auth.js test/agent-write-auth.test.js
git commit -m "feat: authorizeAgentWrite — owner or joined participant, legacy NULL allowed"
```

---

### Task 3: Enforce agent write auth on publish/finalize and the four ephemerals

**Files:**
- Modify: `src/ws.js` (`publish`, `finalize`, `stream`, `stream_append`, `activity`, `status` cases in `handleOp`)
- Test: `test/write-auth-ws.test.js`

**Interfaces:**
- Consumes: `authorizeAgentWrite` (Task 2), participants module (Task 1, tests only).
- Produces: agent write ops now answer `{kind:'control', op:'error', code:'forbidden', ref:<op>, detail:'not a participant of this conversation'}` for non-owner non-joined devices. Client ops unchanged.

- [ ] **Step 1: Write the failing tests**

Create `test/write-auth-ws.test.js` (fleet fixture copied from `test/agent-scoped-delivery.test.js` — implementers may not read other tasks, so it is repeated here):

```js
import test from 'node:test'
import assert from 'node:assert/strict'
import { startTestServer, makeWsClient } from './helpers.js'
import { createUser, createAgent } from '../src/auth.js'
import { inviteParticipant, answerInvite, leaveConvo } from '../src/participants.js'

const settle = (ms = 150) => new Promise((r) => setTimeout(r, ms))

async function fleet(t) {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'pw')
  const agA = createAgent(s.db, dan.id, 'dev-a')
  const agB = createAgent(s.db, dan.id, 'dev-b')
  const a = await makeWsClient(s.base, { token: agA.token, cursor: null })
  const b = await makeWsClient(s.base, { token: agB.token, cursor: null })
  await a.waitFor((f) => f.op === 'hello_ok')
  await b.waitFor((f) => f.op === 'hello_ok')
  t.after(() => { a.close(); b.close() })
  // A owns the room.
  a.send({ op: 'convo_upsert', convo_id: 'room', title: 'room', session_state: 'running' })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'session_status')
  return { s, dan, agA, agB, a, b }
}

const joinB = (s, agA, agB) => {
  inviteParticipant(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, initiatorDeviceId: agA.deviceId, justification: 'x' })
  answerInvite(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, accept: true })
}

test('publish into a foreign convo is rejected; allowed after join; blocked again after leave', async (t) => {
  const { s, agA, agB, a, b } = await fleet(t)
  b.send({ op: 'publish', convo_id: 'room', type: 'text', payload: { body: 'sneak' } })
  const err = await b.waitFor((f) => f.op === 'error' && f.ref === 'publish')
  assert.equal(err.code, 'forbidden')

  joinB(s, agA, agB)
  b.send({ op: 'publish', convo_id: 'room', type: 'text', payload: { body: 'hello room' } })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'hello room')

  leaveConvo(s.db, { convoId: 'room', agentDeviceId: agB.deviceId })
  b.send({ op: 'publish', convo_id: 'room', type: 'text', payload: { body: 'sneak2' } })
  const err2 = await b.waitFor((f) => f.op === 'error' && f.ref === 'publish' && f.code === 'forbidden')
  assert.ok(err2)
})

test('finalize, stream, stream_append, activity, status all reject a foreign convo', async (t) => {
  const { b } = await fleet(t)
  const cases = [
    { op: 'finalize', convo_id: 'room', message_ref: 'm1', type: 'text', payload: { body: 'x' } },
    { op: 'stream', convo_id: 'room', message_ref: 'm1', text: 'x' },
    { op: 'stream_append', convo_id: 'room', message_ref: 'm1', offset: 0, chunk: 'x', meta: { command: 'ls' } },
    { op: 'activity', convo_id: 'room', state: 'thinking' },
    { op: 'status', convo_id: 'room', status: { model: 'x' } },
  ]
  for (const msg of cases) {
    b.send(msg)
    const err = await b.waitFor((f) => f.op === 'error' && f.ref === msg.op)
    assert.equal(err.code, 'forbidden', `${msg.op} must be forbidden`)
  }
})

test('joined participant can finalize and stream ephemerals', async (t) => {
  const { s, agA, agB, a, b } = await fleet(t)
  joinB(s, agA, agB)
  b.send({ op: 'finalize', convo_id: 'room', message_ref: 'm1', type: 'text', payload: { body: 'done' } })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'done')
  // Ephemerals: no error frame back is the pass signal (delivery is
  // viewing-scoped, so nothing arrives anywhere — absence of `forbidden`
  // is what we assert).
  b.send({ op: 'activity', convo_id: 'room', state: 'thinking' })
  await settle()
  assert.deepEqual(b.frames.filter((f) => f.op === 'error' && f.ref === 'activity'), [])
})

test('legacy NULL-owner convo still accepts any agent write', async (t) => {
  const { s, dan, b } = await fleet(t)
  s.db.prepare(
    'INSERT INTO conversations(id, owner_user_id, title, session_state, created_at) VALUES(?,?,?,?,?)'
  ).run('legacy', dan.id, 'old', 'running', Date.now())
  b.send({ op: 'publish', convo_id: 'legacy', type: 'text', payload: { body: 'ok' } })
  await b.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'ok')
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test test/write-auth-ws.test.js`
Expected: the "rejected" tests FAIL (today the publish lands or times out waiting for the error frame); the joined/legacy tests may pass by accident.

- [ ] **Step 3: Implement the guards**

In `src/ws.js`:

1. Extend the import from `./auth.js`: `import { authToken, authorize, authorizeAgentWrite } from './auth.js'`.
2. In `case 'publish'`, after the type/payload validation and the `fin:` idem-key check, insert:

```js
        // Wrong-conversation tightening (spec: agent chat phase 2): an agent
        // device writes only into conversations it manages or has joined.
        // append() would reject a cross-USER convo anyway; this closes the
        // same-user cross-DEVICE hole with an explicit error frame.
        if (!authorizeAgentWrite(db, conn.userId, conn.deviceId, msg.convo_id)) {
          return fail('forbidden', 'not a participant of this conversation')
        }
```

3. In `case 'finalize'`, after the type/payload validation, insert the same guard block.
4. In `case 'stream'`, `case 'stream_append'`, `case 'activity'`, `case 'status'`: replace each `if (!authorize(db, conn.userId, msg.convo_id)) return fail('forbidden')` with:

```js
        if (!authorizeAgentWrite(db, conn.userId, conn.deviceId, msg.convo_id)) return fail('forbidden')
```

(`authorize` stays imported — `messagesBefore` in journal.js and other client paths still use it.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/write-auth-ws.test.js` — PASS.

- [ ] **Step 5: Run the full suite**

Run: `npm test`. Watch specifically `test/agent.test.js`, `test/activity.test.js`, `test/status.test.js`, `test/tool-stream-ws.test.js`, `test/conformance.test.js`: every existing agent-write test publishes into a convo its own connection upserted (owner) or a legacy row (allowed), so they must stay green. If one fails, read it — it will be a fixture publishing into a convo owned by a *different* device; fix the fixture to upsert from the writing connection, not the assertion.

- [ ] **Step 6: Commit**

```bash
git add src/ws.js test/write-auth-ws.test.js
git commit -m "feat: enforce authorizeAgentWrite on publish/finalize and all agent ephemerals"
```

---

### Task 4: `convo_upsert` must not let a participant steal ownership

**Files:**
- Modify: `src/journal.js` (`upsertConversation`, update path)
- Test: `test/journal.test.js` (append two tests)

**Interfaces:**
- Consumes: `convo_agents` rows (Task 1).
- Produces: unchanged signature; behavior change only.

- [ ] **Step 1: Write the failing test**

Append to `test/journal.test.js` (match its existing import style; add `inviteParticipant` from `../src/participants.js` and whatever user/agent fixture helpers the file already uses — if it builds raw rows, do the same):

```js
test('a participant upsert never steals agent_device_id; a non-participant still takes over', async () => {
  const db = openDb(':memory:')
  const dan = await createUser(db, 'dan', 'pw')
  const owner = createAgent(db, dan.id, 'dev-a')
  const guest = createAgent(db, dan.id, 'dev-b')
  const fresh = createAgent(db, dan.id, 'dev-c')
  upsertConversation(db, { id: 'room', ownerUserId: dan.id, title: 'room', sessionState: 'running', agentDeviceId: owner.deviceId })
  // Guest is a participant in ANY state (invited is enough — being invited
  // makes you categorically a guest).
  inviteParticipant(db, { convoId: 'room', agentDeviceId: guest.deviceId, initiatorDeviceId: owner.deviceId, justification: 'x' })
  upsertConversation(db, { id: 'room', ownerUserId: dan.id, sessionState: 'running', agentDeviceId: guest.deviceId })
  assert.equal(db.prepare('SELECT agent_device_id FROM conversations WHERE id=?').get('room').agent_device_id, owner.deviceId)
  // A device with no participant row keeps the last-writer-wins takeover
  // (bridge re-pair reclaiming its own sessions under a new device id).
  upsertConversation(db, { id: 'room', ownerUserId: dan.id, sessionState: 'running', agentDeviceId: fresh.deviceId })
  assert.equal(db.prepare('SELECT agent_device_id FROM conversations WHERE id=?').get('room').agent_device_id, fresh.deviceId)
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test test/journal.test.js`
Expected: FAIL — the guest upsert currently steals ownership (`agent_device_id` becomes guest's).

- [ ] **Step 3: Implement**

In `upsertConversation`'s existing-row branch, before the `UPDATE`:

```js
    // Ownership no-steal (spec: agent chat phase 2, the "last-writer-wins
    // ownership flap" fix): a device that appears in convo_agents for this
    // conversation — any state — is categorically a guest; its upsert keeps
    // title/state fresh but never reassigns delivery ownership. A device
    // with NO participant row keeps the takeover behavior (a re-paired
    // bridge gets a new device id and must be able to reclaim its own
    // sessions).
    const guest = agentDeviceId != null
      && existing.agent_device_id != null
      && existing.agent_device_id !== agentDeviceId
      && !!db.prepare('SELECT 1 FROM convo_agents WHERE convo_id=? AND agent_device_id=?').get(id, agentDeviceId)
```

…and in the `UPDATE`'s `.run(...)`, replace the third bind `agentDeviceId ?? null` with `guest ? null : (agentDeviceId ?? null)` (COALESCE then keeps the existing owner).

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/journal.test.js` — PASS. Then `node --test test/agent-scoped-delivery.test.js` — the "later convo_upsert by another device takes over delivery" test must still pass (that device has no participant row).

- [ ] **Step 5: Full suite + commit**

Run: `npm test` — green.

```bash
git add src/journal.js test/journal.test.js
git commit -m "feat: convo_upsert from a participant no longer steals ownership"
```

---

### Task 5: hub — target-set delivery + `sendToDevice`

**Files:**
- Modify: `src/hub.js` (`broadcastJournal`, add `sendToDevice`, refactor `sendRpcResponse`)
- Modify: `src/ws.js` (`fanOut` — wrap the owner id in a Set)
- Test: `test/hub.test.js` (append tests)

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Tasks 6–8):
  - `hub.broadcastJournal(userId, frame, agentTargets = null)` — third param is now `null` (legacy broadcast to every agent) or a `Set<number>` of agent device ids that may receive the frame. Client connections always receive.
  - `hub.sendToDevice(userId, deviceId, frame) -> void` — multicast to every live socket of one device (exact body of today's `sendRpcResponse`).

- [ ] **Step 1: Write the failing tests**

Append to `test/hub.test.js`, following its existing fake-conn pattern (it builds `{userId, kind, deviceId, ws: {readyState: 1, send}}` objects — read the top of the file and reuse its helpers):

```js
test('broadcastJournal with a target set delivers to clients and only the named agents', () => {
  const hub = makeHub()
  const sent = []
  const conn = (kind, deviceId) => ({ userId: 1, kind, deviceId, ws: { readyState: 1, send: (d) => sent.push([deviceId, JSON.parse(d)]) } })
  const client = conn('client', 10)
  const agentA = conn('agent', 1)
  const agentB = conn('agent', 2)
  const agentC = conn('agent', 3)
  for (const c of [client, agentA, agentB, agentC]) hub.register(c)
  hub.broadcastJournal(1, { kind: 'journal', seq: 1 }, new Set([1, 3]))
  const got = sent.map(([id]) => id).sort()
  assert.deepEqual(got, [1, 3, 10])
})

test('broadcastJournal with null targets keeps legacy broadcast to every agent', () => {
  const hub = makeHub()
  const sent = []
  const conn = (kind, deviceId) => ({ userId: 1, kind, deviceId, ws: { readyState: 1, send: (d) => sent.push(deviceId) } })
  for (const c of [conn('client', 10), conn('agent', 1), conn('agent', 2)]) hub.register(c)
  hub.broadcastJournal(1, { kind: 'journal', seq: 1 }, null)
  assert.deepEqual(sent.sort(), [1, 2, 10])
})

test('sendToDevice multicasts to every live socket of exactly that device', () => {
  const hub = makeHub()
  const sent = []
  const conn = (deviceId, ready = 1) => ({ userId: 1, kind: 'agent', deviceId, ws: { readyState: ready, send: (d) => sent.push(deviceId) } })
  hub.register(conn(1))
  hub.register(conn(1))
  hub.register(conn(2))
  hub.register(conn(1, 3)) // closed socket — skipped
  hub.sendToDevice(1, 1, { kind: 'invite' })
  assert.deepEqual(sent, [1, 1])
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `node --test test/hub.test.js`
Expected: FAIL — `broadcastJournal` treats the Set as a device id (delivers to no agent or wrong ones); `sendToDevice` is not a function.

- [ ] **Step 3: Implement**

In `src/hub.js`:

1. Replace `broadcastJournal`:

```js
    // agentTargets scopes delivery to agent connections: client devices
    // always receive every frame, but an agent device only receives frames
    // for conversations it manages or has joined (spec: agent chat phase 2
    // room fan-out). null means "owner unknown" — legacy rows and
    // convo-less frames keep the old broadcast-to-everyone behavior. The
    // caller (ws.js fanOut / hello replay) computes the set: recorded
    // owner + joined participants.
    broadcastJournal(userId, frame, agentTargets = null) {
      for (const c of byUser.get(userId) || []) {
        if (c.kind === 'agent' && agentTargets != null && !agentTargets.has(c.deviceId)) continue
        if (c.ws.readyState === 1) c.ws.send(JSON.stringify(frame))
      }
    },
```

2. Add `sendToDevice` and make `sendRpcResponse` delegate to it:

```js
    // Multicast to every live socket of one device — the generic form of
    // what sendRpcResponse has always done (responses carry no side
    // effects; a mid-reconnect device briefly has two sockets and both may
    // hear). Also carries invite-lifecycle frames (agent chat phase 2).
    sendToDevice(userId, deviceId, frame) {
      for (const c of byUser.get(userId) || []) {
        if (c.deviceId === deviceId && c.ws.readyState === 1) c.ws.send(JSON.stringify(frame))
      }
    },
    sendRpcResponse(userId, deviceId, frame) {
      this.sendToDevice(userId, deviceId, frame)
    },
```

3. In `src/ws.js` `fanOut`, adapt the call site to the new signature (behavior identical for now — Task 6 adds participants):

```js
  const fanOut = (frame, pushHint) => {
    const owner = db.prepare('SELECT agent_device_id FROM conversations WHERE id=?').get(frame.convo_id)
    const ownerId = owner ? owner.agent_device_id : null
    hub.broadcastJournal(conn.userId, frame, ownerId == null ? null : new Set([ownerId]))
    // …push pipeline call unchanged…
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/hub.test.js` — PASS. Note: `sendRpcResponse` delegating via `this` works because the hub methods live on the returned object literal; verify `test/rpc.test.js` still passes.

- [ ] **Step 5: Full suite + commit**

Run: `npm test` — green (delivery semantics unchanged: a lone owner id in a Set behaves exactly like the old scalar).

```bash
git add src/hub.js src/ws.js test/hub.test.js
git commit -m "feat: hub target-set journal delivery + sendToDevice"
```

---

### Task 6: Fan out and replay to joined participants

**Files:**
- Modify: `src/ws.js` (`fanOut`, hello-replay `replaysTo`)
- Test: `test/room-delivery.test.js`

**Interfaces:**
- Consumes: `joinedAgentIds` (Task 1), `hub.broadcastJournal` target sets (Task 5).
- Produces: a conversation's journal frames now reach owner + joined participants, live and on replay.

- [ ] **Step 1: Write the failing tests**

Create `test/room-delivery.test.js`:

```js
import test from 'node:test'
import assert from 'node:assert/strict'
import { startTestServer, makeWsClient } from './helpers.js'
import { createUser, createAgent } from '../src/auth.js'
import { inviteParticipant, answerInvite } from '../src/participants.js'

const settle = (ms = 150) => new Promise((r) => setTimeout(r, ms))

async function fleet(t) {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'pw')
  const agA = createAgent(s.db, dan.id, 'dev-a')
  const agB = createAgent(s.db, dan.id, 'dev-b')
  const agC = createAgent(s.db, dan.id, 'dev-c')
  const login = await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'pw', device_name: 'mac' } })
  const a = await makeWsClient(s.base, { token: agA.token, cursor: null })
  const b = await makeWsClient(s.base, { token: agB.token, cursor: null })
  const c = await makeWsClient(s.base, { token: agC.token, cursor: null })
  const client = await makeWsClient(s.base, { token: login.json.token, cursor: 0 })
  for (const w of [a, b, c, client]) await w.waitFor((f) => f.op === 'hello_ok')
  t.after(() => { a.close(); b.close(); c.close(); client.close() })
  a.send({ op: 'convo_upsert', convo_id: 'room', title: 'room', session_state: 'running' })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'session_status')
  return { s, dan, agA, agB, agC, a, b, c, client }
}

test('live frames fan to owner + joined participants, not to invited/stranger agents', async (t) => {
  const { s, agA, agB, agC, a, b, c, client } = await fleet(t)
  inviteParticipant(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, initiatorDeviceId: agA.deviceId, justification: 'x' })
  answerInvite(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, accept: true })
  inviteParticipant(s.db, { convoId: 'room', agentDeviceId: agC.deviceId, initiatorDeviceId: agA.deviceId, justification: 'x' })
  // C stays merely invited.

  client.send({ op: 'send', convo_id: 'room', payload: { body: 'hi both' } })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'hi both')
  await b.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'hi both')
  await settle()
  assert.deepEqual(c.journal().filter((f) => f.convo_id === 'room'), [], 'invited-but-not-joined receives nothing')
})

test("a joined participant's own publish reaches the owner and the client", async (t) => {
  const { s, agA, agB, a, b, client } = await fleet(t)
  inviteParticipant(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, initiatorDeviceId: agA.deviceId, justification: 'x' })
  answerInvite(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, accept: true })
  b.send({ op: 'publish', convo_id: 'room', type: 'text', payload: { body: 'from b' } })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'from b')
  await client.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'from b')
})

test('hello replay delivers room history to joined participants and skips strangers', async (t) => {
  const { s, agA, agB, agC, a, client } = await fleet(t)
  inviteParticipant(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, initiatorDeviceId: agA.deviceId, justification: 'x' })
  answerInvite(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, accept: true })
  client.send({ op: 'send', convo_id: 'room', payload: { body: 'history' } })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'text')

  // Reconnect B from cursor 0 — replay must include the room history.
  const b2 = await makeWsClient(s.base, { token: agB.token, cursor: 0 })
  await b2.waitFor((f) => f.kind === 'journal' && f.type === 'text' && f.payload.body === 'history')
  b2.close()

  const c2 = await makeWsClient(s.base, { token: agC.token, cursor: 0 })
  await c2.waitFor((f) => f.op === 'hello_ok')
  await settle()
  assert.deepEqual(c2.journal().filter((f) => f.convo_id === 'room'), [])
  c2.close()
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `node --test test/room-delivery.test.js`
Expected: FAIL — B never receives room frames (delivery is owner-only after Task 5).

- [ ] **Step 3: Implement**

In `src/ws.js`:

1. Import: `import { joinedAgentIds } from './participants.js'`.
2. In `fanOut`, replace the owner lookup + broadcast with:

```js
    // Delivery targets: recorded owner + joined participants (spec: agent
    // chat phase 2 room fan-out). null owner = legacy broadcast. The convo
    // row is already hot from append()'s own authorization read; the
    // participant lookup is a primary-key-prefix seek on convo_agents.
    const ownerId = db.prepare('SELECT agent_device_id FROM conversations WHERE id=?').get(frame.convo_id)?.agent_device_id ?? null
    const targets = ownerId == null ? null : new Set([ownerId, ...joinedAgentIds(db, frame.convo_id)])
    hub.broadcastJournal(conn.userId, frame, targets)
```

3. In the hello-replay block, replace `replaysTo` (the cache now stores the *decision* for this device, not the owner id — rename the map accordingly):

```js
            // Agent connections replay only frames for conversations they
            // manage or have joined — the same scoping hub.broadcastJournal
            // applies to live traffic (NULL owner = legacy broadcast).
            // Decision cached per convo for the duration of this replay;
            // membership changing mid-replay is indistinguishable from it
            // changing right after and is harmless.
            const decisionCache = who.kind === 'agent' ? new Map() : null
            const replaysTo = (convoId) => {
              let d = decisionCache.get(convoId)
              if (d === undefined) {
                const owner = db.prepare('SELECT agent_device_id FROM conversations WHERE id=?').get(convoId)?.agent_device_id ?? null
                d = owner == null || owner === who.deviceId
                  || !!db.prepare("SELECT 1 FROM convo_agents WHERE convo_id=? AND agent_device_id=? AND state='joined'").get(convoId, who.deviceId)
                decisionCache.set(convoId, d)
              }
              return d
            }
```

…and update the loop guard `if (ownerCache && !replaysTo(e.convo_id)) continue` to `if (decisionCache && !replaysTo(e.convo_id)) continue`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/room-delivery.test.js` — PASS. Then `node --test test/agent-scoped-delivery.test.js` — must stay green (no participants there → identical behavior).

- [ ] **Step 5: Full suite + commit**

Run: `npm test` — green.

```bash
git add src/ws.js test/room-delivery.test.js
git commit -m "feat: journal fan-out and hello replay include joined participants"
```

---

### Task 7: Invite lifecycle ops — `agent_invite`, `agent_join`, `agent_invite_ack`, `agent_invite_answer`, `agent_leave`

**Files:**
- Modify: `src/ws.js` (five new cases in `handleOp`, new consts)
- Test: `test/invites.test.js`

**Interfaces:**
- Consumes: participants module (Task 1), `hub.sendRpcRequest` (existing — single newest socket), `hub.sendToDevice` (Task 5).
- Produces — wire protocol (Phase 3 bridge consumes exactly this):
  - Inbound ops (agent connections only, all require `conn.registered`):
    - `{op:'agent_invite', room_id, target_device_id, topic?, justification}`
    - `{op:'agent_join', room_id, justification}`
    - `{op:'agent_invite_ack', room_id, session_state:'idle'|'busy', peer_device_id?}`
    - `{op:'agent_invite_answer', room_id, accept:boolean, reason?, peer_device_id?}`
    - `{op:'agent_leave', room_id}`
  - Outbound frames (`kind:'invite'`, delivered via `sendRpcRequest`/`sendToDevice`, never journaled):
    - to invite target: `{kind:'invite', event:'request', room_id, from_device_id, from_name, topic, justification}`
    - to room owner (join): `{kind:'invite', event:'join_request', room_id, from_device_id, from_name, justification}`
    - to the initiator's own socket, synchronously: `{kind:'invite', event:'delivered', room_id, target_device_id}`
    - to the initiator: `{kind:'invite', event:'ack', room_id, from_device_id, session_state}`
    - to the initiator: `{kind:'invite', event:'answer', room_id, peer_device_id, accept, reason?}` (`reason:'expired'` reserved for Task 8)
    - to the room owner: `{kind:'invite', event:'left', room_id, from_device_id}`
  - Error codes: `bad_request`, `not_found`, `forbidden`, `not_ready`, `conflict` (already invited/joined, or no pending invite to answer), `offline` (target has no live socket).

**Direction rule (the crux):** each `convo_agents` row names the non-owner participant; `initiator_device_id` says who started it. The party entitled to ack/answer is always the NON-initiator: for an owner-initiated invite that is the participant itself (no `peer_device_id` needed — the row is keyed by the answering connection); for a peer-initiated join it is the room owner, who must name the row via `peer_device_id`.

- [ ] **Step 1: Write the failing tests**

Create `test/invites.test.js`:

```js
import test from 'node:test'
import assert from 'node:assert/strict'
import { startTestServer, makeWsClient } from './helpers.js'
import { createUser, createAgent } from '../src/auth.js'
import { getParticipant, inviteParticipant, answerInvite } from '../src/participants.js'

async function fleet(t) {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'pw')
  const agA = createAgent(s.db, dan.id, 'dev-a')
  const agB = createAgent(s.db, dan.id, 'dev-b')
  const a = await makeWsClient(s.base, { token: agA.token, cursor: null })
  const b = await makeWsClient(s.base, { token: agB.token, cursor: null })
  await a.waitFor((f) => f.op === 'hello_ok')
  await b.waitFor((f) => f.op === 'hello_ok')
  t.after(() => { a.close(); b.close() })
  a.send({ op: 'convo_upsert', convo_id: 'room', title: 'room', session_state: 'running' })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'session_status')
  return { s, dan, agA, agB, a, b }
}

test('full invite happy path: request → delivered → ack → answer(accept) → joined', async (t) => {
  const { s, agB, a, b } = await fleet(t)
  a.send({ op: 'agent_invite', room_id: 'room', target_device_id: agB.deviceId, topic: 'ci', justification: 'need your logs' })

  const req = await b.waitFor((f) => f.kind === 'invite' && f.event === 'request')
  assert.equal(req.room_id, 'room')
  assert.equal(req.from_name, 'dev-a')
  assert.equal(req.topic, 'ci')
  assert.equal(req.justification, 'need your logs')

  await a.waitFor((f) => f.kind === 'invite' && f.event === 'delivered' && f.target_device_id === agB.deviceId)

  b.send({ op: 'agent_invite_ack', room_id: 'room', session_state: 'idle' })
  const ack = await a.waitFor((f) => f.kind === 'invite' && f.event === 'ack')
  assert.equal(ack.session_state, 'idle')
  assert.equal(ack.from_device_id, agB.deviceId)

  b.send({ op: 'agent_invite_answer', room_id: 'room', accept: true })
  const ans = await a.waitFor((f) => f.kind === 'invite' && f.event === 'answer')
  assert.equal(ans.accept, true)
  assert.equal(ans.peer_device_id, agB.deviceId)
  assert.equal(getParticipant(s.db, 'room', agB.deviceId).state, 'joined')
})

test('refusal carries the reason back and blocks the room for the target', async (t) => {
  const { s, agB, a, b } = await fleet(t)
  a.send({ op: 'agent_invite', room_id: 'room', target_device_id: agB.deviceId, justification: 'x' })
  await b.waitFor((f) => f.kind === 'invite' && f.event === 'request')
  b.send({ op: 'agent_invite_answer', room_id: 'room', accept: false, reason: 'mid-release, no' })
  const ans = await a.waitFor((f) => f.kind === 'invite' && f.event === 'answer')
  assert.equal(ans.accept, false)
  assert.equal(ans.reason, 'mid-release, no')
  assert.equal(getParticipant(s.db, 'room', agB.deviceId).state, 'refused')
  // Refused device cannot write (ties into Task 3's gate).
  b.send({ op: 'publish', convo_id: 'room', type: 'text', payload: { body: 'sneak' } })
  const err = await b.waitFor((f) => f.op === 'error' && f.ref === 'publish')
  assert.equal(err.code, 'forbidden')
})

test('join flow: peer asks, owner acks busy and accepts via peer_device_id', async (t) => {
  const { s, agA, agB, a, b } = await fleet(t)
  b.send({ op: 'agent_join', room_id: 'room', justification: 'I have context on this bug' })
  const jr = await a.waitFor((f) => f.kind === 'invite' && f.event === 'join_request')
  assert.equal(jr.from_device_id, agB.deviceId)
  assert.equal(jr.from_name, 'dev-b')
  await b.waitFor((f) => f.kind === 'invite' && f.event === 'delivered' && f.target_device_id === agA.deviceId)

  a.send({ op: 'agent_invite_ack', room_id: 'room', session_state: 'busy', peer_device_id: agB.deviceId })
  const ack = await b.waitFor((f) => f.kind === 'invite' && f.event === 'ack')
  assert.equal(ack.session_state, 'busy')

  a.send({ op: 'agent_invite_answer', room_id: 'room', accept: true, peer_device_id: agB.deviceId })
  const ans = await b.waitFor((f) => f.kind === 'invite' && f.event === 'answer')
  assert.equal(ans.accept, true)
  assert.equal(getParticipant(s.db, 'room', agB.deviceId).state, 'joined')
})

test('validation and authorization failures', async (t) => {
  const { s, dan, agA, agB, a, b } = await fleet(t)
  const expectErr = async (w, msg, code) => {
    w.send(msg)
    const err = await w.waitFor((f) => f.op === 'error' && f.ref === msg.op)
    assert.equal(err.code, code, `${msg.op} -> ${code}`)
    // Drain so the next waitFor doesn't match this frame again.
    w.frames.length = 0
  }
  // Non-owner cannot invite into A's room.
  await expectErr(b, { op: 'agent_invite', room_id: 'room', target_device_id: agA.deviceId, justification: 'x' }, 'forbidden')
  // Owner cannot invite itself.
  await expectErr(a, { op: 'agent_invite', room_id: 'room', target_device_id: agA.deviceId, justification: 'x' }, 'bad_request')
  // Missing justification.
  await expectErr(a, { op: 'agent_invite', room_id: 'room', target_device_id: agB.deviceId }, 'bad_request')
  // Unknown room.
  await expectErr(a, { op: 'agent_invite', room_id: 'nope', target_device_id: agB.deviceId, justification: 'x' }, 'not_found')
  // Target that is a client device is indistinguishable from missing.
  const login = await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'pw', device_name: 'mac' } })
  const clientDeviceId = s.db.prepare("SELECT id FROM devices WHERE kind='client' ORDER BY id DESC LIMIT 1").get().id
  await expectErr(a, { op: 'agent_invite', room_id: 'room', target_device_id: clientDeviceId, justification: 'x' }, 'not_found')
  // Double-invite: first goes through, second conflicts.
  a.send({ op: 'agent_invite', room_id: 'room', target_device_id: agB.deviceId, justification: 'x' })
  await b.waitFor((f) => f.kind === 'invite' && f.event === 'request')
  await expectErr(a, { op: 'agent_invite', room_id: 'room', target_device_id: agB.deviceId, justification: 'x' }, 'conflict')
  // Answer without a pending invite (already answered).
  b.send({ op: 'agent_invite_answer', room_id: 'room', accept: true })
  await a.waitFor((f) => f.kind === 'invite' && f.event === 'answer')
  await expectErr(b, { op: 'agent_invite_answer', room_id: 'room', accept: true }, 'conflict')
  // Owner joining its own room is a bad_request.
  await expectErr(a, { op: 'agent_join', room_id: 'room', justification: 'x' }, 'bad_request')
  // Client connections may not use invite ops at all.
  const c = await makeWsClient(s.base, { token: login.json.token, cursor: null })
  await c.waitFor((f) => f.op === 'hello_ok')
  t.after(() => c.close())
  await expectErr(c, { op: 'agent_invite', room_id: 'room', target_device_id: agB.deviceId, justification: 'x' }, 'forbidden')
})

test('inviting an offline device fails with offline and leaves no row', async (t) => {
  const { s, dan, a } = await fleet(t)
  const ghost = createAgent(s.db, dan.id, 'dev-ghost') // never connects
  a.send({ op: 'agent_invite', room_id: 'room', target_device_id: ghost.deviceId, justification: 'x' })
  const err = await a.waitFor((f) => f.op === 'error' && f.ref === 'agent_invite')
  assert.equal(err.code, 'offline')
  assert.equal(getParticipant(s.db, 'room', ghost.deviceId), null)
})

test('agent_leave flips joined to left and notifies the owner', async (t) => {
  const { s, agA, agB, a, b } = await fleet(t)
  inviteParticipant(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, initiatorDeviceId: agA.deviceId, justification: 'x' })
  answerInvite(s.db, { convoId: 'room', agentDeviceId: agB.deviceId, accept: true })
  b.send({ op: 'agent_leave', room_id: 'room' })
  const left = await a.waitFor((f) => f.kind === 'invite' && f.event === 'left')
  assert.equal(left.from_device_id, agB.deviceId)
  assert.equal(getParticipant(s.db, 'room', agB.deviceId).state, 'left')
  // Leaving twice conflicts.
  b.send({ op: 'agent_leave', room_id: 'room' })
  const err = await b.waitFor((f) => f.op === 'error' && f.ref === 'agent_leave')
  assert.equal(err.code, 'conflict')
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `node --test test/invites.test.js`
Expected: FAIL — unknown ops fall through `handleOp`'s `default:` silently, so every `waitFor` times out.

- [ ] **Step 3: Implement the five cases**

In `src/ws.js`:

1. New consts near the other caps:

```js
// Invite lifecycle (spec: agent chat phase 2). Topic is a title fragment;
// justification/reason are one-paragraph human text — capped so a row/frame
// stays small, same defensive stance as ACTIVITY_DETAIL_MAX_CHARS.
const INVITE_TOPIC_MAX_CHARS = 200
const INVITE_TEXT_MAX_CHARS = 1000
const SESSION_ACK_STATES = new Set(['idle', 'busy'])
```

2. Extend the participants import (Task 6 added it): `import { joinedAgentIds, inviteParticipant, answerInvite, leaveConvo, removeParticipant, getParticipant } from './participants.js'`.

3. Add the cases to `handleOp`'s switch (after `case 'agent_response'`, keeping RPC and invite relays adjacent). Shared helper first, defined next to `fail` at the top of `handleOp`:

```js
  // Invite ops: validate a room id + load the row. Rooms are top-level
  // conversations of this conn's user; children (sub-chats) are silenced
  // conversations and can never be rooms.
  const loadRoom = (roomId) => {
    if (typeof roomId !== 'string' || !roomId || roomId.length > CONVO_ID_MAX_CHARS) return { err: ['bad_request', 'bad room_id'] }
    const room = db.prepare('SELECT owner_user_id, agent_device_id, parent_convo_id FROM conversations WHERE id=?').get(roomId)
    if (!room || room.owner_user_id !== conn.userId) return { err: ['not_found'] }
    if (room.parent_convo_id != null) return { err: ['bad_request', 'child conversations cannot be rooms'] }
    return { room }
  }
```

Then the cases:

```js
      case 'agent_invite': {
        if (conn.kind !== 'agent') return fail('forbidden')
        // Replies (delivered/ack/answer) are found by a hub scan of this
        // device's sockets — mid-replay this socket is invisible there, so
        // reject like agent_request does rather than lose the reply.
        if (!conn.registered) return fail('not_ready')
        const { room, err } = loadRoom(msg.room_id)
        if (err) return fail(...err)
        if (room.agent_device_id !== conn.deviceId) return fail('forbidden', 'only the room owner may invite')
        if (!Number.isInteger(msg.target_device_id)) return fail('bad_request', 'bad target_device_id')
        if (msg.target_device_id === conn.deviceId) return fail('bad_request', 'cannot invite self')
        if (msg.topic != null && (typeof msg.topic !== 'string' || msg.topic.length > INVITE_TOPIC_MAX_CHARS)) return fail('bad_request', 'bad topic')
        if (typeof msg.justification !== 'string' || !msg.justification || msg.justification.length > INVITE_TEXT_MAX_CHARS) return fail('bad_request', 'bad justification')
        // Unknown id, another user's device, and a client device are
        // indistinguishable — anti-enumeration, same stance as agent_request.
        const target = db.prepare('SELECT user_id, kind FROM devices WHERE id=?').get(msg.target_device_id)
        if (!target || target.user_id !== conn.userId || target.kind !== 'agent') return fail('not_found')
        const r = inviteParticipant(db, {
          convoId: msg.room_id, agentDeviceId: msg.target_device_id,
          initiatorDeviceId: conn.deviceId, justification: msg.justification,
        })
        if (!r.ok) return fail('conflict', `already ${r.state}`)
        // Single-socket delivery (sendRpcRequest): a request turn must not
        // double-inject on a mid-reconnect bridge. false = offline — undo
        // the row so no pending invite exists that nobody was told about,
        // and the caller hears it immediately (spec: honest fast status).
        const delivered = hub.sendRpcRequest(conn.userId, msg.target_device_id, {
          kind: 'invite', event: 'request', room_id: msg.room_id,
          from_device_id: conn.deviceId, from_name: conn.name,
          topic: msg.topic || '', justification: msg.justification,
        })
        if (!delivered) {
          removeParticipant(db, msg.room_id, msg.target_device_id)
          return fail('offline')
        }
        conn.ws.send(JSON.stringify({ kind: 'invite', event: 'delivered', room_id: msg.room_id, target_device_id: msg.target_device_id }))
        break
      }
      case 'agent_join': {
        if (conn.kind !== 'agent') return fail('forbidden')
        if (!conn.registered) return fail('not_ready')
        const { room, err } = loadRoom(msg.room_id)
        if (err) return fail(...err)
        if (typeof msg.justification !== 'string' || !msg.justification || msg.justification.length > INVITE_TEXT_MAX_CHARS) return fail('bad_request', 'bad justification')
        if (room.agent_device_id == null) return fail('conflict', 'room has no recorded owner to ask')
        if (room.agent_device_id === conn.deviceId) return fail('bad_request', 'cannot join own room')
        const r = inviteParticipant(db, {
          convoId: msg.room_id, agentDeviceId: conn.deviceId,
          initiatorDeviceId: conn.deviceId, justification: msg.justification,
        })
        if (!r.ok) return fail('conflict', `already ${r.state}`)
        const delivered = hub.sendRpcRequest(conn.userId, room.agent_device_id, {
          kind: 'invite', event: 'join_request', room_id: msg.room_id,
          from_device_id: conn.deviceId, from_name: conn.name,
          justification: msg.justification,
        })
        if (!delivered) {
          removeParticipant(db, msg.room_id, conn.deviceId)
          return fail('offline')
        }
        conn.ws.send(JSON.stringify({ kind: 'invite', event: 'delivered', room_id: msg.room_id, target_device_id: room.agent_device_id }))
        break
      }
      case 'agent_invite_ack':
      case 'agent_invite_answer': {
        if (conn.kind !== 'agent') return fail('forbidden')
        const { room, err } = loadRoom(msg.room_id)
        if (err) return fail(...err)
        // Direction rule: the row names the non-owner participant;
        // initiator_device_id says who started it; the NON-initiator acks/
        // answers. peer_device_id present = the owner acting on a join
        // request; absent = the participant acting on an owner invite.
        let rowDeviceId
        if (msg.peer_device_id != null) {
          if (!Number.isInteger(msg.peer_device_id)) return fail('bad_request', 'bad peer_device_id')
          if (room.agent_device_id !== conn.deviceId) return fail('forbidden', 'only the room owner answers a join request')
          rowDeviceId = msg.peer_device_id
        } else {
          rowDeviceId = conn.deviceId
        }
        const row = getParticipant(db, msg.room_id, rowDeviceId)
        if (!row || row.state !== 'invited') return fail('conflict', 'no pending invite')
        if (row.initiator_device_id === conn.deviceId) return fail('forbidden', 'the initiator cannot answer its own invite')
        if (msg.op === 'agent_invite_ack') {
          if (!SESSION_ACK_STATES.has(msg.session_state)) return fail('bad_request', 'bad session_state')
          hub.sendToDevice(conn.userId, row.initiator_device_id, {
            kind: 'invite', event: 'ack', room_id: msg.room_id,
            from_device_id: conn.deviceId, session_state: msg.session_state,
          })
          break
        }
        if (typeof msg.accept !== 'boolean') return fail('bad_request', 'bad accept')
        if (msg.reason != null && (typeof msg.reason !== 'string' || msg.reason.length > INVITE_TEXT_MAX_CHARS)) return fail('bad_request', 'bad reason')
        if (!answerInvite(db, { convoId: msg.room_id, agentDeviceId: rowDeviceId, accept: msg.accept })) {
          return fail('conflict', 'no pending invite')
        }
        hub.sendToDevice(conn.userId, row.initiator_device_id, {
          kind: 'invite', event: 'answer', room_id: msg.room_id,
          peer_device_id: rowDeviceId, accept: msg.accept,
          ...(typeof msg.reason === 'string' && msg.reason ? { reason: msg.reason } : {}),
        })
        break
      }
      case 'agent_leave': {
        if (conn.kind !== 'agent') return fail('forbidden')
        const { room, err } = loadRoom(msg.room_id)
        if (err) return fail(...err)
        if (!leaveConvo(db, { convoId: msg.room_id, agentDeviceId: conn.deviceId })) {
          return fail('conflict', 'not a joined participant')
        }
        if (room.agent_device_id != null && room.agent_device_id !== conn.deviceId) {
          hub.sendToDevice(conn.userId, room.agent_device_id, {
            kind: 'invite', event: 'left', room_id: msg.room_id, from_device_id: conn.deviceId,
          })
        }
        break
      }
```

Note the TOCTOU shape in ack/answer: `getParticipant` (read) then `answerInvite` (guarded UPDATE … `AND state='invited'`) — the UPDATE is the authority; the read only supplies `initiator_device_id` for routing and direction checks. A racing expiry between the two turns the answer into `conflict`, which is correct.

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/invites.test.js` — PASS (7 tests).

- [ ] **Step 5: Full suite + commit**

Run: `npm test` — green.

```bash
git add src/ws.js test/invites.test.js
git commit -m "feat: invite/join/ack/answer/leave ops for agent chat rooms"
```

---

### Task 8: Invite expiry sweep

**Files:**
- Modify: `src/ws.js` (`attachWs` — new opt + sweep body), `src/server.js` (forward the opt)
- Test: `test/invites.test.js` (append one test)

**Interfaces:**
- Consumes: `expireInvites` (Task 1), `hub.sendToDevice` (Task 5).
- Produces: `attachWs({..., inviteTtlMs = 1800000})`; `startServer({..., inviteTtlMs})` forwards it (same optional-spread pattern as `revocationSweepMs`). Expired invites notify the initiator with `{kind:'invite', event:'answer', room_id, peer_device_id, accept:false, reason:'expired'}`.

- [ ] **Step 1: Write the failing test**

Append to `test/invites.test.js`:

```js
test('an unanswered invite expires and the initiator is told', async (t) => {
  const s = await startTestServer({ revocationSweepMs: 100, inviteTtlMs: 150 })
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'pw')
  const agA = createAgent(s.db, dan.id, 'dev-a')
  const agB = createAgent(s.db, dan.id, 'dev-b')
  const a = await makeWsClient(s.base, { token: agA.token, cursor: null })
  const b = await makeWsClient(s.base, { token: agB.token, cursor: null })
  await a.waitFor((f) => f.op === 'hello_ok')
  await b.waitFor((f) => f.op === 'hello_ok')
  t.after(() => { a.close(); b.close() })
  a.send({ op: 'convo_upsert', convo_id: 'room', session_state: 'running' })
  await a.waitFor((f) => f.kind === 'journal' && f.type === 'session_status')
  a.send({ op: 'agent_invite', room_id: 'room', target_device_id: agB.deviceId, justification: 'x' })
  await b.waitFor((f) => f.kind === 'invite' && f.event === 'request')
  // B never answers; the sweep expires it.
  const ans = await a.waitFor((f) => f.kind === 'invite' && f.event === 'answer', 3000)
  assert.equal(ans.accept, false)
  assert.equal(ans.reason, 'expired')
  assert.equal(ans.peer_device_id, agB.deviceId)
  assert.equal(getParticipant(s.db, 'room', agB.deviceId).state, 'expired')
  // A late answer from B is a clean conflict, not a resurrection.
  b.send({ op: 'agent_invite_answer', room_id: 'room', accept: true })
  const err = await b.waitFor((f) => f.op === 'error' && f.ref === 'agent_invite_answer')
  assert.equal(err.code, 'conflict')
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --test test/invites.test.js`
Expected: the new test FAILS — no `answer` frame ever arrives (sweep doesn't exist), and `startServer` ignores `inviteTtlMs`.

- [ ] **Step 3: Implement**

1. `src/ws.js` — add `inviteTtlMs = 1800000` to `attachWs`'s destructured options and `import { expireInvites } from './participants.js'` (merge into the existing participants import). Inside the existing `sweep` interval callback, after the tool-stream sweep and before the `conns.length === 0` early-return (expiry must run even with nobody connected — rows go stale regardless; only the notification needs a live socket):

```js
    // Invite expiry (spec: 30 min default, generous because busy is
    // reported honestly via the ack). Piggybacks on this sweep timer, same
    // as the tool-stream idle sweep above. The initiator (room owner for
    // invites, the joiner for join requests) hears an expiry exactly like
    // a refusal, with reason 'expired'; if it is offline right now it
    // simply misses the frame — its next roster/answer attempt tells the
    // same story (conflict / state=expired).
    for (const row of expireInvites(db, inviteTtlMs)) {
      const convo = db.prepare('SELECT owner_user_id FROM conversations WHERE id=?').get(row.convo_id)
      if (!convo) continue
      hub.sendToDevice(convo.owner_user_id, row.initiator_device_id, {
        kind: 'invite', event: 'answer', room_id: row.convo_id,
        peer_device_id: row.agent_device_id, accept: false, reason: 'expired',
      })
    }
```

2. `src/server.js` — add `inviteTtlMs` to `startServer`'s destructured options (line ~221 list) and forward it into the `attachWs({...})` call with the same conditional-spread pattern used for `revocationSweepMs`:

```js
    ...(inviteTtlMs !== undefined ? { inviteTtlMs } : {}),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/invites.test.js` — PASS (8 tests).

- [ ] **Step 5: Full suite + commit**

Run: `npm test` — green.

```bash
git add src/ws.js src/server.js test/invites.test.js
git commit -m "feat: server-side invite expiry sweep (default 30 min)"
```

---

### Task 9: `summary` column — migration, upsert path, snapshot

**Files:**
- Modify: `src/db.js` (guarded ALTER in `openDb`), `src/journal.js` (`upsertConversation`, `snapshot`), `src/ws.js` (`convo_upsert` validation + pass-through)
- Test: `test/journal.test.js` (append), `test/ws.test.js` or `test/agent.test.js` (append the oversize rejection wherever `convo_upsert` validation tests already live — grep for `bad_parent` or `parent_convo_id` tests and sit next to them)

**Interfaces:**
- Consumes: nothing new.
- Produces: `conversations.summary TEXT NOT NULL DEFAULT ''`; `convo_upsert` accepts optional `summary` (string ≤ `SUMMARY_MAX_CHARS = 1000`); `/snapshot` conversations gain `summary`; Task 10's roster reads it.

- [ ] **Step 1: Write the failing tests**

Append to `test/journal.test.js`:

```js
test('summary: set via upsert, kept when omitted, returned by snapshot', async () => {
  const db = openDb(':memory:')
  const dan = await createUser(db, 'dan', 'pw')
  const ag = createAgent(db, dan.id, 'dev-a')
  upsertConversation(db, { id: 's1', ownerUserId: dan.id, title: 't', sessionState: 'running', agentDeviceId: ag.deviceId, summary: 'debugging CI' })
  assert.equal(db.prepare('SELECT summary FROM conversations WHERE id=?').get('s1').summary, 'debugging CI')
  // Don't-clobber: an upsert without summary keeps the stored one (July
  // title-revert discipline).
  upsertConversation(db, { id: 's1', ownerUserId: dan.id, sessionState: 'running', agentDeviceId: ag.deviceId })
  assert.equal(db.prepare('SELECT summary FROM conversations WHERE id=?').get('s1').summary, 'debugging CI')
  upsertConversation(db, { id: 's1', ownerUserId: dan.id, agentDeviceId: ag.deviceId, summary: 'fixed CI, now on tests' })
  const snap = snapshot(db, dan.id)
  assert.equal(snap.conversations.find((c) => c.id === 's1').summary, 'fixed CI, now on tests')
})
```

And a WS-level rejection test. Grep for where the `parent_convo_id` `convo_upsert` validation tests live (`git grep -n "bad parent_convo_id" test/`) and append there; if the fixture there differs, prefer this self-contained form appended to `test/write-auth-ws.test.js` (which already imports the fleet helpers):

```js
test('convo_upsert rejects a non-string or oversize summary', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'pw')
  const agA = createAgent(s.db, dan.id, 'dev-a')
  const ag = await makeWsClient(s.base, { token: agA.token, cursor: null })
  await ag.waitFor((f) => f.op === 'hello_ok')
  t.after(() => ag.close())
  ag.send({ op: 'convo_upsert', convo_id: 'v1', session_state: 'running', summary: 42 })
  let err = await ag.waitFor((f) => f.op === 'error' && f.ref === 'convo_upsert')
  assert.equal(err.code, 'bad_request')
  ag.frames.length = 0
  ag.send({ op: 'convo_upsert', convo_id: 'v1', session_state: 'running', summary: 'x'.repeat(1001) })
  err = await ag.waitFor((f) => f.op === 'error' && f.ref === 'convo_upsert')
  assert.equal(err.code, 'bad_request')
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `node --test test/journal.test.js` — FAIL (`no such column: summary` or summary undefined).

- [ ] **Step 3: Implement**

1. `src/db.js`, in `openDb` next to the other conversations ALTERs (reuse the already-loaded `convoCols`):

```js
  // Rolling 2-3 sentence conversation summary, maintained by the owning
  // bridge's title pass (spec: agent chat phase 2) — roster targeting
  // metadata. Same don't-clobber discipline as title: only an upsert that
  // carries it changes it.
  if (!convoCols.some((c) => c.name === 'summary')) {
    db.exec("ALTER TABLE conversations ADD COLUMN summary TEXT NOT NULL DEFAULT ''")
  }
```

2. `src/journal.js` `upsertConversation` — accept `summary` in the destructured params; update path adds `summary=COALESCE(?, summary)` to the UPDATE (bind `summary ?? null` in position); insert path adds the column with `summary || ''`. Summary changes do NOT set `metaChanged` — `convo_meta` is chat-list-facing (title/parent); summaries are roster metadata fetched on demand, and the title pass would otherwise emit a journal event per conversation per pass.

3. `src/journal.js` `snapshot` — add `summary` to the SELECT column list. (Apps decode snapshots tolerantly — `parent_convo_id` was added the same way.)

4. `src/ws.js` — const `SUMMARY_MAX_CHARS = 1000` next to the other caps; in `case 'convo_upsert'`, after the `parent_convo_id` validation:

```js
        if (msg.summary != null && (typeof msg.summary !== 'string' || msg.summary.length > SUMMARY_MAX_CHARS)) {
          return fail('bad_request', 'bad summary')
        }
```

…and pass `summary: msg.summary ?? null` into the `upsertConversation` call.

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/journal.test.js` and the file you added the WS test to — PASS.

- [ ] **Step 5: Full suite + commit**

Run: `npm test` — green (snapshot consumers in tests assert on specific fields, not exhaustive shapes; if a conformance fixture asserts the exact conversation object shape, update the fixture to include `summary: ''` — that is a legitimate expected-output change, note it in the commit).

```bash
git add src/db.js src/journal.js src/ws.js test/journal.test.js test/write-auth-ws.test.js
git commit -m "feat: conversations.summary — upsert path + snapshot"
```

---

### Task 10: `GET /roster` — agent-accessible targeting metadata

**Files:**
- Modify: `src/http.js` (new route, directly after the `/devices` route)
- Test: `test/http.test.js` (append)

**Interfaces:**
- Consumes: `summary` column (Task 9), `hub.connsOf` (existing).
- Produces: `GET /roster` (Bearer, client OR agent kind) →

```json
{
  "agents": [{ "device_id": 3, "name": "dev-2", "created_at": 1, "last_seen_at": 2, "connected": true }],
  "conversations": [{ "id": "…", "title": "…", "session_state": "running", "last_seq": 9,
                       "summary": "…", "agent_device_id": 3, "created_at": 1, "last_ts": 2 }]
}
```

- [ ] **Step 1: Write the failing tests**

Append to `test/http.test.js` (reuse its existing server/user/token fixture style):

```js
test('GET /roster: agent token gets agent devices + top-level conversation metadata', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'pw')
  const eve = await createUser(s.db, 'eve', 'pw')
  const agA = createAgent(s.db, dan.id, 'dev-a')
  const agB = createAgent(s.db, dan.id, 'dev-b')
  createAgent(s.db, eve.id, 'dev-eve')
  await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'pw', device_name: 'mac' } })
  upsertConversation(s.db, { id: 'top', ownerUserId: dan.id, title: 'work', sessionState: 'running', agentDeviceId: agA.deviceId, summary: 'fixing CI' })
  upsertConversation(s.db, { id: 'child', ownerUserId: dan.id, title: 'sub', sessionState: 'running', agentDeviceId: agA.deviceId, parentConvoId: 'top' })
  upsertConversation(s.db, { id: 'evetop', ownerUserId: eve.id, title: 'secret', sessionState: 'running' })

  const r = await s.http('/roster', { token: agB.token })
  assert.equal(r.status, 200)
  // Agent devices only — client devices are management surface (/devices,
  // client-gated) and never enumerable by an agent.
  assert.deepEqual(r.json.agents.map((d) => d.name).sort(), ['dev-a', 'dev-b'])
  assert.ok(r.json.agents.every((d) => d.kind === undefined || d.kind === 'agent'))
  const ids = r.json.conversations.map((c) => c.id)
  assert.ok(ids.includes('top'))
  assert.ok(!ids.includes('child'), 'sub-chats are not roster targets')
  assert.ok(!ids.includes('evetop'), 'other users invisible')
  const top = r.json.conversations.find((c) => c.id === 'top')
  assert.equal(top.summary, 'fixing CI')
  assert.equal(top.agent_device_id, agA.deviceId)
})

test('GET /roster works for client tokens too and requires auth', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  await createUser(s.db, 'dan', 'pw')
  const login = await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'pw', device_name: 'mac' } })
  const ok = await s.http('/roster', { token: login.json.token })
  assert.equal(ok.status, 200)
  const anon = await s.http('/roster')
  assert.equal(anon.status, 401)
})
```

- [ ] **Step 2: Run to verify they fail**

Run: `node --test test/http.test.js` — the new tests FAIL with 404s.

- [ ] **Step 3: Implement**

In `src/http.js`, directly after the `/devices` route's closing brace:

```js
      if (req.method === 'GET' && url.pathname === '/roster') {
        // Targeting surface for agent chat (spec: phase 2 roster) — unlike
        // /devices (management, client-gated) this is deliberately open to
        // agent tokens, and deliberately NARROWER: agent devices only
        // (an agent still has no business enumerating its user's client
        // devices), no cursor/lag/push_prefs, and only top-level
        // conversations (children are silenced sub-chats, never chat
        // targets). Same owner_user_id scoping as every other read.
        const live = new Set(hub.connsOf(who.userId).filter((c) => c.ws.readyState === 1).map((c) => c.deviceId))
        const agents = db.prepare(
          "SELECT id AS device_id, name, created_at, last_seen_at FROM devices WHERE user_id=? AND kind='agent' ORDER BY id"
        ).all(who.userId).map((d) => ({ ...d, connected: live.has(d.device_id) }))
        const conversations = db.prepare(
          `SELECT id, title, session_state, last_seq, summary, agent_device_id, created_at,
                  (SELECT ts FROM events e WHERE e.convo_id = conversations.id
                   ORDER BY e.seq DESC LIMIT 1) AS last_ts
           FROM conversations WHERE owner_user_id=? AND parent_convo_id IS NULL
           ORDER BY last_seq DESC`
        ).all(who.userId)
        return json(res, 200, { agents, conversations })
      }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/http.test.js` — PASS.

- [ ] **Step 5: Full suite + commit**

Run: `npm test` — green.

```bash
git add src/http.js test/http.test.js
git commit -m "feat: GET /roster — agent-accessible targeting metadata"
```

---

### Task 11: Protocol docs + final sweep

**Files:**
- Modify: `docs/protocol.md`

- [ ] **Step 1: Document the additions**

Read `docs/protocol.md` first and match its structure/voice. Add, in the sections where their siblings live:

1. **`convo_agents` / participants** — a short concept section: what a room is (ordinary top-level conversation), the state machine `invited → joined | refused | expired`, `joined → left`, renewal rule (refused/left/expired may be re-invited), the direction rule (`initiator_device_id`; the non-initiator answers).
2. **Agent write authorization** — the rule enforced on `publish`, `finalize`, `stream`, `stream_append`, `activity`, `status`: recorded owner, joined participant, or legacy NULL owner; violation → `{op:'error', code:'forbidden'}`.
3. **Ownership no-steal** on `convo_upsert` (participants are guests; non-participants keep takeover) and the new optional `summary` field (string ≤1000 chars, don't-clobber, no `convo_meta` event).
4. **The five new ops** with request shapes, error codes (`conflict`, `offline`, `not_ready`) and the `kind:'invite'` frame family (`request`, `join_request`, `delivered`, `ack`, `answer`, `left`), including `reason:'expired'` from the sweep (default TTL 30 min, `inviteTtlMs`).
5. **Delivery** — journal fan-out and hello replay now reach owner + joined participants; invite frames are never journaled, never pushed, never sent to client devices.
6. **`GET /roster`** — auth, response shape, scoping (agent devices only, top-level conversations only).

- [ ] **Step 2: Full-suite verification**

Run: `npm test` — every test green. Then run the sanity trio explicitly and confirm counts look right (no silently-skipped files):

```bash
node --test test/participants.test.js test/agent-write-auth.test.js test/write-auth-ws.test.js \
  test/room-delivery.test.js test/invites.test.js
```

- [ ] **Step 3: Commit**

```bash
git add docs/protocol.md
git commit -m "docs: protocol — participants, write auth, invite ops, summary, /roster"
```

---

## Self-review notes (spec ↔ plan)

- Spec "participants table" → Task 1 (with `initiator_device_id` added beyond the spec's column list — required by the spec's own item 7, `agent_chat_join`, so the owner-answers-a-join direction is representable without a Phase 3 migration; `expired` added to the state enum for the same reason).
- Spec "write auth split" → Tasks 2–3. `read_marker` is deliberately NOT tightened (not in the spec's op list; bridges mark read on behalf of the user).
- Spec "fan-out + hello-replay predicate" → Tasks 5–6.
- Spec "convo_upsert must not steal ownership" → Task 4 (participant-scoped, preserving re-pair takeover and the existing `agent-scoped-delivery` test).
- Spec "invite ops + expiry" → Tasks 7–8 (`agent_join`/`agent_leave` added beyond the literal list — spec room-lifecycle items 7–8 need server support and Phase 3 is bridge-only by design).
- Spec "summary column, snapshot + roster" → Tasks 9–10.
- Spec "roster: NEW agent-accessible endpoint … filtered by owner_user_id" → Task 10; `GET /devices` untouched.
- Known same-device limitation (unchanged from spec): two sessions bridged by the SAME device can still cross-post — the gate is device-granular; the bridge's own convo mapping remains the guard there.
- Deferred to Phase 3 (bridge): everything that consumes these ops; nothing in the apps changes (invite frames never reach clients; `summary` in snapshot is additive and ignored by current apps).
