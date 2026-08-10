# Agent Box Rename — Journal Implementation Plan (1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Repo:** `matron-journal` (branch off `master`). The spec lives in the
`matron-apple` repo at `docs/superpowers/specs/2026-08-10-agent-box-rename-design.md`.

**Goal:** Let a user rename any of their devices, expose each conversation's
owning agent box to clients as data, and heal conversation titles that have a
bridge label baked into them.

**Architecture:** Four additive server changes. A `POST /devices/:id/rename`
endpoint mirroring the existing revoke route; `GET /snapshot` grows
`agent_device_id` per conversation plus a top-level `agents` id→name array;
the existing `convo_meta` event payload grows `agent_device_id`; and a new
`device_meta` WebSocket frame fans a rename out to the user's client
connections. A one-time `PRAGMA user_version` migration strips baked
`label:` prefixes from stored titles.

**Tech Stack:** Node.js ESM, `better-sqlite3`, `ws`, `node:test` +
`node:assert/strict`. No new dependencies.

## Global Constraints

- Name cap: **40 characters** after trimming. Longer is rejected with 400
  `{ error: 'bad_request' }`, never truncated.
- Every stored/returned name passes `sanitizePeerText(value, PEER_NAME_CAP)`
  from `src/peer-text.js` (`PEER_NAME_CAP = 80`; our 40-char check runs on the
  sanitised value).
- Rename is **client-gated**: `who.kind !== 'client'` → 403
  `{ error: 'forbidden' }`, exactly like `/password`, `/devices` and
  `/devices/:id/revoke`.
- Not-owned and nonexistent devices are indistinguishable: both 404
  `{ error: 'not_found' }` (repo-wide anti-enumeration stance).
- Duplicate device names are allowed — pairing only warns about them.
- Any device kind may be renamed (client or agent).
- `device_meta` frames go to **client** connections only.
- Run the full suite with `npm test` from the repo root.
- Never run tests against the live dev-2 database; `startTestServer()` uses
  `:memory:`.

---

### Task 1: Rename endpoint

**Files:**
- Modify: `src/auth.js` (add `renameOwnedDevice` next to `revokeOwnedDevice`, ~line 101)
- Modify: `src/http.js` (import it at line 3; add the route next to the revoke route, ~line 472)
- Test: `test/devices.test.js` (append)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `renameOwnedDevice(db, userId, deviceId, name) -> boolean`
  (false when no row was updated). Route `POST /devices/:id/rename`, body
  `{ name: string }`, 200 `{ ok: true, device: { device_id, name } }`.

- [ ] **Step 1: Write the failing test**

Append to `test/devices.test.js`:

```js
test('POST /devices/:id/rename: renames, sanitises, caps, owner-scoped, client-gated', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'hunter22')
  const agent = createAgent(s.db, dan.id, 'dev-9')
  await createUser(s.db, 'pat', 'password')
  const pat = await s.http('/login', { method: 'POST', body: { username: 'pat', password: 'password', device_name: 'x' } })
  const login = await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'hunter22', device_name: 'dan-mac' } })
  const token = login.json.token

  // happy path
  const ok = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token, body: { name: 'dev-y' } })
  assert.equal(ok.status, 200)
  assert.deepEqual(ok.json, { ok: true, device: { device_id: agent.deviceId, name: 'dev-y' } })
  const roster = await s.http('/devices', { token })
  assert.equal(roster.json.devices.find((d) => d.device_id === agent.deviceId).name, 'dev-y')

  // a client device (including self) may be renamed too
  const self = await s.http(`/devices/${login.json.device_id}/rename`, { method: 'POST', token, body: { name: 'Dan Mac' } })
  assert.equal(self.status, 200)
  assert.equal(self.json.device.name, 'Dan Mac')

  // control characters and newlines are flattened, surrounding space trimmed
  const dirty = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token, body: { name: '  dev\n\ty  ' } })
  assert.equal(dirty.status, 200)
  assert.equal(dirty.json.device.name, 'dev y')

  // duplicate names are allowed (pairing only warns)
  const dup = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token, body: { name: 'dan-mac' } })
  assert.equal(dup.status, 200)

  // empty / whitespace-only / non-string / >40 chars -> 400
  for (const name of ['', '   ', 42, null, undefined, 'x'.repeat(41)]) {
    const r = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token, body: { name } })
    assert.equal(r.status, 400, `expected 400 for ${JSON.stringify(name)}`)
    assert.deepEqual(r.json, { error: 'bad_request' })
  }
  // exactly 40 is accepted
  const at40 = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token, body: { name: 'y'.repeat(40) } })
  assert.equal(at40.status, 200)

  // not owned / nonexistent -> 404, indistinguishable
  const notOwned = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token: pat.json.token, body: { name: 'mine now' } })
  assert.equal(notOwned.status, 404)
  assert.deepEqual(notOwned.json, { error: 'not_found' })
  const missing = await s.http('/devices/999999/rename', { method: 'POST', token, body: { name: 'ghost' } })
  assert.equal(missing.status, 404)

  // agent bearers are gated like /password
  const asAgent = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token: agent.token, body: { name: 'self-serve' } })
  assert.equal(asAgent.status, 403)
  assert.deepEqual(asAgent.json, { error: 'forbidden' })

  // unauthenticated -> 401
  assert.equal((await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', body: { name: 'x' } })).status, 401)
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- test/devices.test.js`
Expected: FAIL — the rename path 404s (no route matches), so the first
`assert.equal(ok.status, 200)` fails.

- [ ] **Step 3: Add `renameOwnedDevice` to `src/auth.js`**

Insert directly after `revokeOwnedDevice` (~line 103):

```js
// Cosmetic rename, owner-scoped like revokeOwnedDevice. Returns false when
// the device is not this user's (or does not exist) — the caller cannot
// distinguish the two, same anti-enumeration stance as revoke.
export function renameOwnedDevice(db, userId, deviceId, name) {
  return db.prepare('UPDATE devices SET name=? WHERE id=? AND user_id=?').run(name, deviceId, userId).changes > 0
}
```

- [ ] **Step 4: Add the route to `src/http.js`**

Extend the import on line 3 with `renameOwnedDevice`:

```js
import { login, authToken, changePassword, revokeOwnedDevice, renameOwnedDevice, createAgent, createClientDevice, authorizeAgentWrite } from './auth.js'
```

Add immediately after the revoke route's closing brace (~line 488):

```js
      const rn = url.pathname.match(/^\/devices\/(\d+)\/rename$/)
      if (req.method === 'POST' && rn) {
        // Client-gated like /devices and /password: an agent has no business
        // renaming its user's devices (or itself — the name is the user's
        // label for the box, not the box's self-description).
        if (who.kind !== 'client') return json(res, 403, { error: 'forbidden' })
        const { name } = await readBody(req)
        if (typeof name !== 'string') return json(res, 400, { error: 'bad_request' })
        // Sanitise BEFORE measuring: the cap is on what we store, and the
        // sieve (control chars -> space, whitespace collapsed, trimmed) is
        // the same one every peer-written name goes through.
        const clean = deviceName(name)
        if (!clean || clean.length > DEVICE_NAME_MAX) return json(res, 400, { error: 'bad_request' })
        const renamedId = Number(rn[1])
        if (!renameOwnedDevice(db, who.userId, renamedId, clean)) return json(res, 404, { error: 'not_found' })
        return json(res, 200, { ok: true, device: { device_id: renamedId, name: clean } })
      }
```

Add the cap constant next to the existing `deviceName` helper (line 18):

```js
// User-facing device-name cap. Deliberately tighter than PEER_NAME_CAP (80,
// the sanitiser's bound for peer-written text): a device name is a chip
// label in the apps, and 40 chars is already more than a chip can show.
const DEVICE_NAME_MAX = 40
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- test/devices.test.js`
Expected: PASS, including the pre-existing `/devices` and revoke tests.

- [ ] **Step 6: Commit**

```bash
git add src/auth.js src/http.js test/devices.test.js
git commit -m "feat(devices): POST /devices/:id/rename"
```

---

### Task 2: Snapshot carries box identity

**Files:**
- Modify: `src/journal.js:186-207` (`snapshot`)
- Modify: `src/http.js:251-263` (the `/snapshot` route — pass the flag through)
- Test: `test/http.test.js` (append)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `GET /snapshot` response gains `agent_device_id` on every
  conversation row and a top-level `agents: [{ device_id, name }]`.
  `snapshot(db, userId, { omitSnippet, excludePrivateOwned })` keeps its
  existing signature — the agents list is filtered by the SAME
  `excludePrivateOwned` flag.

- [ ] **Step 1: Write the failing test**

Append to `test/http.test.js` (it already imports `startTestServer`; add
`createAgent` to the `../src/auth.js` import if absent):

```js
test('GET /snapshot exposes each convo agent_device_id and the agents id->name list', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'hunter22')
  const agent = createAgent(s.db, dan.id, 'dev-y')
  const login = await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'hunter22', device_name: 'mac' } })

  s.db.prepare('INSERT INTO conversations(id, owner_user_id, title, created_at, agent_device_id) VALUES(?,?,?,?,?)')
    .run('c-owned', dan.id, 'Fix the parser', Date.now(), agent.deviceId)
  s.db.prepare('INSERT INTO conversations(id, owner_user_id, title, created_at) VALUES(?,?,?,?)')
    .run('c-orphan', dan.id, 'No box yet', Date.now())

  const r = await s.http('/snapshot', { token: login.json.token })
  assert.equal(r.status, 200)
  const owned = r.json.conversations.find((c) => c.id === 'c-owned')
  const orphan = r.json.conversations.find((c) => c.id === 'c-orphan')
  assert.equal(owned.agent_device_id, agent.deviceId)
  assert.equal(orphan.agent_device_id, null)
  // agents: agent devices only — the client device is not a box
  assert.deepEqual(r.json.agents, [{ device_id: agent.deviceId, name: 'dev-y' }])
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- test/http.test.js`
Expected: FAIL — `owned.agent_device_id` is `undefined` (the column is not
selected) and `r.json.agents` is `undefined`.

- [ ] **Step 3: Extend `snapshot` in `src/journal.js`**

Replace the body of `snapshot` (lines 193-206) with:

```js
  const conversations = db.prepare(
    `SELECT id, title, session_state, session_outcome, last_seq, unread_count,
            ${omitSnippet ? 'NULL' : 'snippet'} AS snippet,
            parent_convo_id, summary, created_at, agent_device_id,
            (SELECT ts FROM events e WHERE e.convo_id = conversations.id
             ORDER BY e.seq DESC LIMIT 1) AS last_ts
     FROM conversations WHERE owner_user_id=?${excludePrivateOwned
       ? ` AND (agent_device_id IS NULL OR NOT EXISTS(
              SELECT 1 FROM devices d WHERE d.id=conversations.agent_device_id AND d.private=1))`
       : ''}
     ORDER BY last_seq DESC`
  ).all(userId)
  // id -> name for the user's agent boxes, so a client can render the
  // owning box of each conversation without a second round-trip. Same
  // privacy predicate as the conversation filter above: a filtered
  // (ordinary agent) caller must not learn private boxes exist. Client
  // devices are deliberately absent — they are not boxes.
  const agents = db.prepare(
    `SELECT id AS device_id, name FROM devices
     WHERE user_id=? AND kind='agent'${excludePrivateOwned ? ' AND private=0' : ''} ORDER BY id`
  ).all(userId)
  const head = db.prepare('SELECT seq FROM user_seq WHERE user_id=?').get(userId)
  return { conversations, agents, seq: head ? head.seq : 0 }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- test/http.test.js && npm test -- test/privacy.test.js`
Expected: PASS both — `privacy.test.js` covers the filtered-agent caller and
must stay green (the agents list inherits the same predicate).

- [ ] **Step 5: Commit**

```bash
git add src/journal.js test/http.test.js
git commit -m "feat(snapshot): carry agent_device_id per convo and an agents id->name list"
```

---

### Task 3: `convo_meta` carries `agent_device_id`

**Files:**
- Modify: `src/ws.js:1213-1222` (the `convo_meta` fan-out inside `convo_upsert`)
- Test: `test/agent.test.js` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `convo_meta` event payload gains `agent_device_id` — the id of
  the agent connection that upserted the conversation.

- [ ] **Step 1: Write the failing test**

Append to `test/agent.test.js`:

```js
test('convo_meta carries the upserting agent device id so a live client can chip a brand-new convo', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'hunter22')
  const agent = createAgent(s.db, dan.id, 'dev-y')
  const login = await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'hunter22', device_name: 'mac' } })
  const client = await makeWsClient(s.base, { token: login.json.token, cursor: 0 })
  t.after(() => client.close())
  const box = await makeWsClient(s.base, { token: agent.token, cursor: 0 })
  t.after(() => box.close())

  box.send({ op: 'convo_upsert', convo_id: 'c-new', title: 'Fix the parser' })
  const meta = await client.waitFor((f) => f.kind === 'journal' && f.type === 'convo_meta')
  assert.equal(meta.payload.title, 'Fix the parser')
  assert.equal(meta.payload.agent_device_id, agent.deviceId)
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- test/agent.test.js`
Expected: FAIL — `meta.payload.agent_device_id` is `undefined`.

- [ ] **Step 3: Extend the fan-out payload in `src/ws.js`**

Replace the `payload:` line inside the `if (convo.metaChanged)` block
(line 1220):

```js
            // agent_device_id rides the meta event so a live client can show
            // which box owns a conversation the moment it appears, without
            // waiting for the next /snapshot. Always this connection's
            // device — upsertConversation records the same id.
            payload: {
              title: convo.title,
              parent_convo_id: convo.parent_convo_id ?? null,
              agent_device_id: conn.deviceId,
            },
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- test/agent.test.js`
Expected: PASS, including the existing "fans out on title change, not on
same-title or state-only upserts" test (the trigger condition is unchanged).

- [ ] **Step 5: Commit**

```bash
git add src/ws.js test/agent.test.js
git commit -m "feat(convo_meta): carry agent_device_id for live box attribution"
```

---

### Task 4: `device_meta` fan-out on rename

**Files:**
- Modify: `src/http.js` (the rename route from Task 1 — add the fan-out before returning)
- Test: `test/devices.test.js` (append)

**Interfaces:**
- Consumes: the rename route from Task 1.
- Produces: WebSocket frame `{ kind: 'device_meta', device_id: <int>, name: <string> }`,
  sent to every live **client** connection of the renaming user (the renamer's
  own sockets included — the app applies it idempotently).

- [ ] **Step 1: Write the failing test**

Append to `test/devices.test.js`:

```js
test('rename fans out device_meta to client sockets only', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'hunter22')
  const agent = createAgent(s.db, dan.id, 'dev-9')
  await createUser(s.db, 'pat', 'password')
  const patLogin = await s.http('/login', { method: 'POST', body: { username: 'pat', password: 'password', device_name: 'pat-phone' } })
  const login = await s.http('/login', { method: 'POST', body: { username: 'dan', password: 'hunter22', device_name: 'mac' } })

  const client = await makeWsClient(s.base, { token: login.json.token, cursor: 0 })
  t.after(() => client.close())
  const box = await makeWsClient(s.base, { token: agent.token, cursor: 0 })
  t.after(() => box.close())
  const stranger = await makeWsClient(s.base, { token: patLogin.json.token, cursor: 0 })
  t.after(() => stranger.close())

  const r = await s.http(`/devices/${agent.deviceId}/rename`, { method: 'POST', token: login.json.token, body: { name: 'dev-y' } })
  assert.equal(r.status, 200)

  const frame = await client.waitFor((f) => f.kind === 'device_meta')
  assert.deepEqual(frame, { kind: 'device_meta', device_id: agent.deviceId, name: 'dev-y' })
  // agents never receive it (a box has no roster to update), and another
  // user's socket never sees it at all
  await new Promise((res) => setTimeout(res, 150))
  assert.equal(box.frames.filter((f) => f.kind === 'device_meta').length, 0)
  assert.equal(stranger.frames.filter((f) => f.kind === 'device_meta').length, 0)
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- test/devices.test.js`
Expected: FAIL — `waitFor timeout`, no `device_meta` frame is ever sent.

- [ ] **Step 3: Send the frame from the rename route**

In `src/http.js`, insert before the rename route's `return json(...)`:

```js
        // Live roster patch for the user's other apps. Transient (not a
        // journal event): a device name is not conversation history, and a
        // client that was offline picks the new name up from its next
        // /snapshot `agents` list. Clients only — an agent keeps no roster.
        for (const c of hub.connsOf(who.userId)) {
          if (c.kind === 'client' && c.ws.readyState === 1) {
            c.ws.send(JSON.stringify({ kind: 'device_meta', device_id: renamedId, name: clean }))
          }
        }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- test/devices.test.js`
Expected: PASS.

- [ ] **Step 5: Document the frame**

Add to `docs/protocol.md`, in the section listing server→client frame kinds
(search for `kind: 'ephemeral'` to find it):

```markdown
### `device_meta`

`{ kind: 'device_meta', device_id, name }` — sent to a user's client
sockets when `POST /devices/:id/rename` succeeds. Transient: not a journal
event, carries no seq, and is not replayed. A client that misses it learns
the new name from the `agents` list in its next `GET /snapshot`.
```

- [ ] **Step 6: Commit**

```bash
git add src/http.js test/devices.test.js docs/protocol.md
git commit -m "feat(devices): fan out device_meta to client sockets on rename"
```

---

### Task 5: One-time title-healing migration

**Files:**
- Create: `src/heal-titles.js`
- Modify: `src/db.js` (call it at the end of the migration block, before `return db`)
- Test: `test/heal-titles.test.js`

**Interfaces:**
- Consumes: nothing.
- Produces: `stripServerLabel(title) -> string` (pure, exported for tests) and
  `healBakedTitles(db, { log }) -> { scanned, healed }`, run once at open.

**Context the implementer needs:** bridges used to bake their `SERVER_LABEL`
into conversation titles in two shapes — `DEV-:a3 Fix the thing` (the
first-user-message fallback and the Gemini title pass; the two chars after
the colon are a session-id fragment) and `DEV-: matron-apple` (the workdir
seed). Bridges stop doing this in plan 2 of 3; this migration cleans up what
is already stored. Organic titles like `Fix: parser bug` must survive
untouched — hence the two tight patterns below, and why the seed form only
strips when the remainder has no spaces.

- [ ] **Step 1: Write the failing test**

Create `test/heal-titles.test.js`:

```js
import test from 'node:test'
import assert from 'node:assert/strict'
import { openDb } from '../src/db.js'
import { stripServerLabel, healBakedTitles } from '../src/heal-titles.js'

test('stripServerLabel removes baked bridge label prefixes and nothing else', () => {
  // fallback / Gemini form: label + ':' + 2-char session fragment + space
  assert.equal(stripServerLabel('DEV-:a3 Fix the thing'), 'Fix the thing')
  assert.equal(stripServerLabel('2:f0 fix the folder picker'), 'fix the folder picker')
  assert.equal(stripServerLabel('mac:A1 Ship the release'), 'Ship the release')
  // workdir-seed form: label + ': ' + a single space-free basename
  assert.equal(stripServerLabel('DEV-: matron-apple'), 'matron-apple')
  assert.equal(stripServerLabel('3: yearbook_app'), 'yearbook_app')

  // organic titles are untouched
  assert.equal(stripServerLabel('Fix: parser bug'), 'Fix: parser bug')
  assert.equal(stripServerLabel('TODO: ship the thing'), 'TODO: ship the thing')
  assert.equal(stripServerLabel('Fix the thing'), 'Fix the thing')
  assert.equal(stripServerLabel(''), '')
  // a 3-char fragment is not the fallback shape, and the remainder has
  // spaces so it is not the seed shape either
  assert.equal(stripServerLabel('dev:abc something'), 'dev:abc something')
  // a >12-char "label" is prose, not a bridge label
  assert.equal(stripServerLabel('averylonglabelx:a3 nope'), 'averylonglabelx:a3 nope')
  // idempotent: healed output re-heals to itself
  for (const t of ['DEV-:a3 Fix the thing', 'DEV-: matron-apple', 'Fix: parser bug']) {
    assert.equal(stripServerLabel(stripServerLabel(t)), stripServerLabel(t))
  }
})

test('healBakedTitles rewrites stored titles once and is gated on user_version', () => {
  const db = openDb(':memory:')
  const now = Date.now()
  db.prepare('INSERT INTO users(id, name, password_hash, created_at) VALUES(1, ?, ?, ?)').run('dan', 'x', now)
  const insert = db.prepare('INSERT INTO conversations(id, owner_user_id, title, created_at) VALUES(?,1,?,?)')
  insert.run('c1', 'DEV-:a3 Fix the thing', now)
  insert.run('c2', 'DEV-: matron-apple', now)
  insert.run('c3', 'Fix: parser bug', now)

  // openDb already ran it — user_version is claimed and titles are healed
  assert.equal(db.pragma('user_version', { simple: true }) >= 1, true)
  const titles = () => Object.fromEntries(
    db.prepare('SELECT id, title FROM conversations').all().map((r) => [r.id, r.title]))
  // rows inserted AFTER open are untouched by that first run
  assert.deepEqual(titles(), {
    c1: 'DEV-:a3 Fix the thing', c2: 'DEV-: matron-apple', c3: 'Fix: parser bug',
  })

  // a direct call still heals (this is what a real upgrade does, at open,
  // with rows already present)
  const logged = []
  const r = healBakedTitles(db, { log: (m) => logged.push(m), force: true })
  assert.deepEqual(titles(), { c1: 'Fix the thing', c2: 'matron-apple', c3: 'Fix: parser bug' })
  assert.equal(r.healed, 2)
  assert.equal(logged.length, 2)
  assert.match(logged[0], /c1/)

  // gated: a second ungated call is a no-op because user_version is set
  const again = healBakedTitles(db, { log: () => {} })
  assert.equal(again.healed, 0)
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- test/heal-titles.test.js`
Expected: FAIL — `Cannot find module '../src/heal-titles.js'`.

- [ ] **Step 3: Create `src/heal-titles.js`**

```js
// One-time cleanup of bridge-baked title prefixes.
//
// Bridges used to prefix every journal conversation title with their
// SERVER_LABEL, in two shapes:
//   `DEV-:a3 Fix the thing`  — first-user-message fallback and Gemini title
//                              pass (2-char session-id fragment after the
//                              colon)
//   `DEV-: matron-apple`     — the workdir-basename seed
// The label is now data (conversations.agent_device_id, rendered as a chip
// by the apps) rather than text, and bridges no longer bake it in. This
// heals what is already stored.
//
// Deliberately conservative: the label is capped at 12 non-space chars, the
// fallback fragment must be exactly two alphanumerics, and the seed form
// only strips when what follows is a single space-free token. `Fix: parser
// bug` and `TODO: ship the thing` must survive — they are ordinary titles
// that merely contain a colon.
const FALLBACK = /^[^\s:]{1,12}:[0-9a-zA-Z]{2}\s+/
const SEED = /^[^\s:]{1,12}:\s+(\S+)$/

export function stripServerLabel(title) {
  if (typeof title !== 'string' || !title) return ''
  if (FALLBACK.test(title)) return title.replace(FALLBACK, '')
  const seed = title.match(SEED)
  if (seed) return seed[1]
  return title
}

// Runs once per database, gated on PRAGMA user_version (unused elsewhere in
// this repo, so version 1 is ours). An ungated re-run would eventually eat
// an organic title that happens to match, so the gate is the safety
// property, not an optimisation. `force` is for tests only.
//
// Every rewrite is logged: BYOS users run this unattended on their own
// server and deserve an audit trail of what their titles used to be.
export function healBakedTitles(db, { log = () => {}, force = false } = {}) {
  if (!force && db.pragma('user_version', { simple: true }) >= 1) return { scanned: 0, healed: 0 }
  const rows = db.prepare('SELECT id, title FROM conversations').all()
  const update = db.prepare('UPDATE conversations SET title=? WHERE id=?')
  let healed = 0
  const run = db.transaction(() => {
    for (const row of rows) {
      const next = stripServerLabel(row.title)
      if (next === row.title) continue
      update.run(next, row.id)
      healed++
      log(`heal-titles: ${row.id} ${JSON.stringify(row.title)} -> ${JSON.stringify(next)}`)
    }
    db.pragma('user_version = 1')
  })
  run()
  return { scanned: rows.length, healed }
}
```

- [ ] **Step 4: Call it from `openDb`**

In `src/db.js`, add the import at the top:

```js
import { healBakedTitles } from './heal-titles.js'
```

and insert immediately before `return db` at the end of the migration block
(~line 271):

```js
  // One-time title cleanup (spec: agent box rename). Gated on user_version
  // inside, so this is a cheap pragma read on every subsequent open.
  healBakedTitles(db, { log: (m) => console.log(m) })
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- test/heal-titles.test.js`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `npm test`
Expected: PASS — every test, with the "Executed N tests" style summary showing
no failures. Existing tests that assert on titles they inserted themselves are
unaffected: `openDb` claims `user_version` before any test row exists, so the
heal never touches test fixtures.

- [ ] **Step 7: Commit**

```bash
git add src/heal-titles.js src/db.js test/heal-titles.test.js
git commit -m "feat(titles): one-time heal of bridge-baked label prefixes"
```

---

## Deploy note (for whoever ships this)

Bridges must be deployed **before** this journal build. An old bridge's
Gemini title pass re-bakes the prefix onto healed titles; if that happens,
the damage is cosmetic and re-running the heal (reset `user_version` to 0
and restart) fixes it.

## Self-review notes

- Spec §1.1 (rename endpoint) → Task 1. §1.2 (snapshot) → Task 2. §1.3
  (`convo_meta` + `device_meta`) → Tasks 3 and 4. §1.4 (healing) → Task 5.
- The spec's "log every rewrite at info level" is implemented as
  `console.log` via the injected `log` — matching how `openDb`'s other
  one-shot migration work reports.
- `PEER_NAME_CAP` (80) remains the sanitiser's bound; `DEVICE_NAME_MAX` (40)
  is the endpoint's own check, applied to the sanitised value. Both are
  referenced by the same names in Tasks 1 and 4.
