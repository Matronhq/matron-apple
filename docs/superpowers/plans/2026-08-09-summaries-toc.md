# Conversation Summaries TOC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every bridge summary pass becomes a persistent, seq-anchored `summary` journal event; both apps store them locally and expose a tap-the-title TOC panel whose rows navigate the transcript; the summarizer becomes provider-configurable defaulting to GPT-5.6 Luna with an incremental prompt window.

**Architecture:** Three independent phases, one repo + PR each. Journal: accept the new kind, keep it silent (no snippet/unread/push). Bridge: turn-end trigger, incremental window with prior-roster preamble, `publishSummary`, provider abstraction. Apps: GRDB `summary_entry` table fed from all apply paths, transcript exclusion, title-tap panel, new `focus(seq:)` jump machinery.

**Tech Stack:** Node 22 + vitest (journal, bridge); Swift / SwiftUI / GRDB / XCTest (apps).

**Spec:** `docs/superpowers/specs/2026-08-09-summaries-toc-design.md` (matron-apple repo).

## Global Constraints

- Deploy order: journal (dev-2) → apps installed → bridge. Bridge must not emit `summary` events until apps carry the transcript exclusion (old apps render `[unsupported event: summary]`).
- `summary` goes in journal `AGENT_PUBLISH_TYPES` (ws.js) only — NEVER in `MESSAGE_TYPES` (journal.js) and NEVER in the apps' `JournalEventType.messageTypes` (WireModels.swift:31-33). Those drive snippet/unread on server and client.
- Event payload shape (wire contract all three repos share): `{ "toc": string, "detail": string, "model": string }`. `toc` non-empty; `detail` may be `""`.
- Bridge: default OpenAI model `gpt-5.6-luna`; default Gemini model `gemini-3-flash-preview`; `SUMMARY_MODEL` overrides either. Window: since-last-successful-pass, cap 200 bubbles, min 5 new to fire. Cursor (`lastSummaryMsgCount`) advances only on success.
- Bridge repo: NEVER `git checkout` in `~/Dev/matron-bridge` (live deploy tree). Work in a sibling worktree `~/Dev/matron-bridge-summaries-wt` (NOT under /tmp — path tests fail there).
- Journal repo: `~/Dev/matron-journal` working tree is parked on a feature branch — work in a worktree `~/Dev/matron-journal-summaries-wt` off `origin/master`.
- Apps repo: work on the existing `feat/summaries-toc` branch in `~/Dev/matron-apple`. Run `xcodegen generate` before any xcodebuild.
- Test commands:
  - journal/bridge: `npm test` (vitest); bridge full gate: `npm run ci`.
  - apps SPM: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`
  - Mac target: `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests` — assert "Executed N tests" appears; grep pipelines mask failures.

---

## Phase A — matron-journal

Setup (fold into Task A1 step 1):
```bash
cd ~/Dev/matron-journal && git fetch origin
git worktree add ~/Dev/matron-journal-summaries-wt -b feat/summary-events origin/master
cd ~/Dev/matron-journal-summaries-wt && npm install
```

### Task A1: Accept `summary` publishes; keep them out of snippet/unread

**Files:**
- Modify: `src/ws.js:23-26` (`AGENT_PUBLISH_TYPES`)
- Test: `test/agent.test.js` (whitelist test at :305-332), `test/journal.test.js`

**Interfaces:**
- Consumes: nothing new.
- Produces: WS `op:publish` accepts `type:'summary'`; event rows persist, fan out, and replay; conversation row gets `last_seq` bump only (no snippet/unread). Payload is opaque to the server.

- [ ] **Step 1: Create the worktree (commands above), run the suite once to confirm green baseline**

Run: `npm test`
Expected: PASS (all existing tests).

- [ ] **Step 2: Extend the whitelist test to expect `summary` accepted**

In `test/agent.test.js`, the test `'agent publish type whitelist: rejects server-generated/unknown types, accepts exactly the allowed set'` (:305-332): add `'summary'` to the `allowed` array **after** `'edit'`, and change the completion wait to the new last kind:

```js
  const allowed = ['text', 'prompt', 'prompt_reply', 'tool_output', 'diff', 'permission_request', 'file', 'image', 'edit', 'summary'];
  for (const type of allowed) {
    agent.send({ op: 'publish', convo_id: 'sess-wl', type, payload: { body: 'ok' } });
  }
  await agent.waitFor((f) => f.kind === 'journal' && f.type === 'summary'); // the last one sent
  assert.equal(s.db.prepare("SELECT COUNT(*) n FROM events WHERE convo_id='sess-wl'").get().n, allowed.length);
```

Then add a new test in the same file, same helpers, pinning the silence contract:

```js
test('summary events append and fan out but never touch snippet or unread', async (t) => {
  const s = await startTestServer()
  t.after(() => s.close())
  const dan = await createUser(s.db, 'dan', 'pw')
  const ag = createAgent(s.db, dan.id, 'dev-2')
  const agent = await makeWsClient(s.base, { token: ag.token, cursor: null })
  await agent.waitFor((f) => f.op === 'hello_ok')
  agent.send({ op: 'convo_upsert', convo_id: 'sess-sum' })
  agent.send({ op: 'publish', convo_id: 'sess-sum', type: 'text', payload: { body: 'real message' } })
  await agent.waitFor((f) => f.kind === 'journal' && f.type === 'text')
  const before = s.db.prepare("SELECT snippet, unread_count, last_seq FROM conversations WHERE id='sess-sum'").get()

  agent.send({ op: 'publish', convo_id: 'sess-sum', type: 'summary', payload: { toc: 'Fixed the bug', detail: 'Working on X.', model: 'gpt-5.6-luna' } })
  await agent.waitFor((f) => f.kind === 'journal' && f.type === 'summary')

  const after = s.db.prepare("SELECT snippet, unread_count, last_seq FROM conversations WHERE id='sess-sum'").get()
  assert.equal(after.snippet, before.snippet)            // no snippet change
  assert.equal(after.unread_count, before.unread_count)  // no unread bump
  assert.ok(after.last_seq > before.last_seq)            // seq still advances
  agent.close()
})
```

Align helper names (`startTestServer`/`createUser`/`createAgent`/`makeWsClient`) with the existing test at :305 — copy its imports/preamble verbatim.

- [ ] **Step 3: Run both tests, verify they fail**

Run: `npx vitest run test/agent.test.js`
Expected: FAIL — the `summary` publish is rejected with `bad_request`, so the count assertion and the new test's `waitFor` time out/fail.

- [ ] **Step 4: Add `'summary'` to `AGENT_PUBLISH_TYPES`**

`src/ws.js:23-26`:

```js
const AGENT_PUBLISH_TYPES = new Set([
  'text', 'prompt', 'prompt_reply', 'tool_output', 'diff',
  'permission_request', 'file', 'image', 'edit', 'summary',
])
```

Do NOT touch `MESSAGE_TYPES` in `src/journal.js:4-6` — omission from it is what routes summary appends into the `else` branch at `src/journal.js:161-162` (`last_seq` bump only). This mirrors the accepted `edit` precedent in `docs/BACKLOG.md:72-73`.

- [ ] **Step 5: Run the suite**

Run: `npm test`
Expected: PASS, including the conformance fixture `06a_agent_publish_types.json` (if it enumerates the allowed set, update the fixture to include `summary` — treat a fixture failure here as expected and fix the fixture, not the code).

- [ ] **Step 6: Commit**

```bash
git add src/ws.js test/agent.test.js test/fixtures/conformance/06a_agent_publish_types.json
git commit -m "feat: accept 'summary' publish kind — silent in snippet/unread by MESSAGE_TYPES omission"
```

### Task A2: Push opt-out + docs

**Files:**
- Modify: `src/push.js:26-47` (`classify`), `docs/protocol.md` (message-kinds section ~:497), `docs/BACKLOG.md:72-73`
- Test: `test/push.test.js`

**Interfaces:**
- Consumes: Task A1 (kind accepted).
- Produces: no APNs traffic for `summary` events.

- [ ] **Step 1: Write the failing test**

`classify()` fails open — its catch-all returns routine `activity`. Mimic the "never push at all" case at `test/push.test.js:137` (copy that test's setup/stub helpers verbatim; it asserts the APNs stub received zero calls). New test:

```js
test('summary events never push', async (t) => {
  // same server/stub preamble as the ':137' never-push test in this file
  agent.send({ op: 'publish', convo_id: 'sess-push', type: 'summary', payload: { toc: 'x', detail: 'y', model: 'm' } })
  await agent.waitFor((f) => f.kind === 'journal' && f.type === 'summary')
  assert.equal(apnsStub.calls.length, 0)
})
```

- [ ] **Step 2: Run it, verify it fails**

Run: `npx vitest run test/push.test.js`
Expected: FAIL — the catch-all classifies `summary` as `activity` and the stub records a push.

- [ ] **Step 3: Add the opt-out**

`src/push.js` — alongside the `convo_meta` case at :43:

```js
  if (type === 'convo_meta') return null
  // TOC summary events are derived metadata, not new activity — journal-sync only.
  if (type === 'summary') return null
```

- [ ] **Step 4: Run the suite; verify pass**

Run: `npm test`
Expected: PASS.

- [ ] **Step 5: Docs**

- `docs/protocol.md` message-kinds section (~:497): document kind `summary`, payload `{toc, detail, model}`, and its contract: agent-publishable, fans out + replays, never snippet/unread/push, not FTS-indexed.
- `docs/BACKLOG.md:72-73`: extend the accepted-by-design note ("`edit` events don't update snippet/unread") to cover `summary`, and note `summary` additionally opts out of push (unlike `edit`, which pushes — known inconsistency, not replicated).

- [ ] **Step 6: Commit; push branch and open PR against master**

```bash
git add src/push.js test/push.test.js docs/protocol.md docs/BACKLOG.md
git commit -m "feat: summary events are journal-sync only — no push, docs for the new kind"
git push -u origin feat/summary-events
gh pr create --repo Matronhq/matron-journal --title "Summary TOC events: accept kind, keep silent" --body "..."
```

---

## Phase B — matron-bridge

Setup (fold into Task B1 step 1):
```bash
cd ~/Dev/matron-bridge && git fetch origin
git worktree add ~/Dev/matron-bridge-summaries-wt -b feat/summaries-toc origin/master
cd ~/Dev/matron-bridge-summaries-wt && npm install
```

### Task B1: `lib/summary-model.js` — provider-configurable generate()

**Files:**
- Create: `lib/summary-model.js`
- Modify: `package.json` (`check` script — hand-maintained `node --check` list; append the new file or it's silently unchecked), `.env.example`, `README.md` env table (~:135-159)
- Test: `test/summary-model.test.js`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `createSummaryModel({ openaiApiKey, geminiClient, modelOverride, fetchImpl, warn }) -> { model: string, generate(prompt: string): Promise<string> } | null`. Null when no provider is configured. Task B3 calls `generate` twice per pass (compaction + title pass) and stamps `model` into the event payload.

- [ ] **Step 1: Create the worktree (commands above), confirm green baseline**

Run: `npm test`
Expected: PASS.

- [ ] **Step 2: Write the failing tests**

`test/summary-model.test.js` (vitest, DI style — inject `fetchImpl`, never real network):

```js
import { describe, it, expect, vi } from 'vitest';
import { createSummaryModel } from '../lib/summary-model.js';

const okFetch = (text) => vi.fn(async () => ({
  ok: true,
  json: async () => ({ choices: [{ message: { content: text } }] }),
}));

describe('createSummaryModel', () => {
  it('returns null when no provider is configured', () => {
    expect(createSummaryModel({})).toBeNull();
  });

  it('prefers OpenAI when a key is set, defaulting to gpt-5.6-luna', async () => {
    const fetchImpl = okFetch('TITLE: t');
    const m = createSummaryModel({ openaiApiKey: 'sk-x', geminiClient: {}, fetchImpl });
    expect(m.model).toBe('gpt-5.6-luna');
    await expect(m.generate('hello')).resolves.toBe('TITLE: t');
    const [url, opts] = fetchImpl.mock.calls[0];
    expect(url).toBe('https://api.openai.com/v1/chat/completions');
    const body = JSON.parse(opts.body);
    expect(body.model).toBe('gpt-5.6-luna');
    expect(body.messages).toEqual([{ role: 'user', content: 'hello' }]);
    expect(opts.headers.Authorization).toBe('Bearer sk-x');
  });

  it('SUMMARY_MODEL override applies to whichever provider is active', () => {
    const m = createSummaryModel({ openaiApiKey: 'sk-x', modelOverride: 'gpt-5.7-terra', fetchImpl: okFetch('x') });
    expect(m.model).toBe('gpt-5.7-terra');
  });

  it('throws a descriptive error on non-2xx and on an empty completion', async () => {
    const bad = vi.fn(async () => ({ ok: false, status: 429, text: async () => 'rate limited' }));
    const m1 = createSummaryModel({ openaiApiKey: 'sk-x', fetchImpl: bad });
    await expect(m1.generate('p')).rejects.toThrow(/openai 429/);
    const empty = vi.fn(async () => ({ ok: true, json: async () => ({ choices: [] }) }));
    const m2 = createSummaryModel({ openaiApiKey: 'sk-x', fetchImpl: empty });
    await expect(m2.generate('p')).rejects.toThrow(/empty/);
  });

  it('falls back to the Gemini client, defaulting to gemini-3-flash-preview', async () => {
    const generateContent = vi.fn(async () => ({ response: { text: () => ' out ' } }));
    const getGenerativeModel = vi.fn(() => ({ generateContent }));
    const m = createSummaryModel({ geminiClient: { getGenerativeModel } });
    expect(m.model).toBe('gemini-3-flash-preview');
    await expect(m.generate('p')).resolves.toBe('out');
    expect(getGenerativeModel).toHaveBeenCalledWith({ model: 'gemini-3-flash-preview' });
  });
});
```

- [ ] **Step 3: Run, verify FAIL (module not found)**

Run: `npx vitest run test/summary-model.test.js`

- [ ] **Step 4: Implement `lib/summary-model.js`**

```js
// Provider-selectable LLM client for the title/summary pass. OpenAI (plain
// fetch, no SDK dependency) wins when a key is configured — GPT-5.6 Luna is
// ~2.5x cheaper per token than Gemini 3 Flash Preview as of 2026-08 — with
// the existing Gemini client as fallback so a Gemini-only .env keeps working.
// Returns null when neither provider is configured; callers treat that as
// "summarization off" (fallback titling still runs elsewhere).

const OPENAI_URL = 'https://api.openai.com/v1/chat/completions';
export const DEFAULT_OPENAI_MODEL = 'gpt-5.6-luna';
export const DEFAULT_GEMINI_MODEL = 'gemini-3-flash-preview';

export function createSummaryModel({
  openaiApiKey = '',
  geminiClient = null,
  modelOverride = '',
  fetchImpl = fetch,
} = {}) {
  if (openaiApiKey) {
    const model = modelOverride || DEFAULT_OPENAI_MODEL;
    return {
      model,
      async generate(prompt) {
        const res = await fetchImpl(OPENAI_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${openaiApiKey}` },
          body: JSON.stringify({ model, messages: [{ role: 'user', content: prompt }] }),
        });
        if (!res.ok) throw new Error(`openai ${res.status}: ${(await res.text()).slice(0, 200)}`);
        const data = await res.json();
        const text = data?.choices?.[0]?.message?.content;
        if (typeof text !== 'string' || !text.trim()) throw new Error('openai: empty completion');
        return text.trim();
      },
    };
  }
  if (geminiClient) {
    const model = modelOverride || DEFAULT_GEMINI_MODEL;
    return {
      model,
      async generate(prompt) {
        const m = geminiClient.getGenerativeModel({ model });
        const result = await m.generateContent(prompt);
        return result.response.text().trim();
      },
    };
  }
  return null;
}
```

- [ ] **Step 5: Run tests, verify PASS; append `lib/summary-model.js` to the `check` script in `package.json`**

Run: `npx vitest run test/summary-model.test.js && npm run check`

- [ ] **Step 6: Env docs**

`.env.example`, replacing the Gemini block comment:

```
# Conversation titles + rolling TOC summaries (optional). OpenAI is preferred
# when set (default model gpt-5.6-luna); Gemini is the fallback (default
# gemini-3-flash-preview). SUMMARY_MODEL overrides the active provider's model.
# All empty: sessions work fine, titles keep the first-message fallback and no
# summary events are published.
OPENAI_API_KEY=
GEMINI_API_KEY=
SUMMARY_MODEL=
```

README env table: add `OPENAI_API_KEY` and `SUMMARY_MODEL` rows; amend the `GEMINI_API_KEY` row to say "fallback summarizer when OPENAI_API_KEY is unset".

- [ ] **Step 7: Commit**

```bash
git add lib/summary-model.js test/summary-model.test.js package.json .env.example README.md
git commit -m "feat: provider-selectable summary model — OpenAI gpt-5.6-luna preferred, Gemini fallback"
```

### Task B2: `publishSummary` on the journal publisher

**Files:**
- Modify: `lib/journal-publisher.js` — real method at the `publishImage` block (~:758-760), no-op stub at :77-85
- Test: `test/journal-publisher.test.js`

**Interfaces:**
- Consumes: nothing.
- Produces: `publisher.publishSummary(convoId, {toc, detail, model})` → durable `{op:'publish', type:'summary', payload, idem_key}` frame. Task B3 calls it via `journalPublish(session, 'publishSummary', payload)`.

- [ ] **Step 1: Write the failing test**

In `test/journal-publisher.test.js`, using the existing `startFakeServer`/`waitFor` helpers (copy the preamble of the nearest `publishText` frame-shape test in that file):

```js
it('publishSummary enqueues a durable summary publish frame', async () => {
  // fake-server preamble identical to the publishText frame test
  pub.publishSummary('convo-1', { toc: 'Did the thing', detail: 'Now doing X.', model: 'gpt-5.6-luna' });
  const frame = await waitFor(() => received.find((f) => f.op === 'publish' && f.type === 'summary'));
  expect(frame.convo_id).toBe('convo-1');
  expect(frame.payload).toEqual({ toc: 'Did the thing', detail: 'Now doing X.', model: 'gpt-5.6-luna' });
  expect(frame.idem_key).toBeTruthy();
});
```

- [ ] **Step 2: Run, verify FAIL** (`pub.publishSummary is not a function`)

- [ ] **Step 3: Implement — both objects**

Real publisher (after `publishImage`):

```js
    publishSummary(convoId, payload) {
      safePublish(convoId, 'summary', payload);
    },
```

Disabled-journal stub at :77-85 — add `publishSummary() {},` (missing this throws on journal-disabled bridges).

- [ ] **Step 4: Run tests, verify PASS; commit**

```bash
npx vitest run test/journal-publisher.test.js
git add lib/journal-publisher.js test/journal-publisher.test.js
git commit -m "feat: journal publisher publishSummary (durable summary events)"
```

### Task B3: Incremental window + prompt builder (`lib/summary-pass.js`)

**Files:**
- Create: `lib/summary-pass.js`
- Modify: `package.json` `check` list
- Test: `test/summary-pass.test.js`

**Interfaces:**
- Consumes: nothing.
- Produces (Task B4 consumes exactly these):
  - `SUMMARY_MIN_NEW = 5`, `SUMMARY_WINDOW_CAP = 200`
  - `summaryWindow(chatHistory, lastCount, {cap}) -> { messages: [{role,text}], newCount: number, nextCount: number }` — `nextCount` is the value to store into `session.lastSummaryMsgCount` on success (always `chatHistory.length`, even when capped, so overflow is never re-summarized).
  - `buildSummaryPrompt({ messages, priorRoster, hasCumulative }) -> string` — `hasCumulative` selects the `NEW:` variant vs the first-pass `SUMMARY:` variant; ROSTER stays the LAST format line (parser constraint, `lib/journal-title-seed.js:57-74`).

- [ ] **Step 1: Write the failing tests**

`test/summary-pass.test.js`:

```js
import { describe, it, expect } from 'vitest';
import { summaryWindow, buildSummaryPrompt, SUMMARY_MIN_NEW, SUMMARY_WINDOW_CAP } from '../lib/summary-pass.js';

const msgs = (n, start = 0) => Array.from({ length: n }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', text: `m${start + i}` }));

describe('summaryWindow', () => {
  it('slices strictly after the last summarized message', () => {
    const h = msgs(12);
    const { messages, newCount, nextCount } = summaryWindow(h, 7);
    expect(messages.map((m) => m.text)).toEqual(['m7', 'm8', 'm9', 'm10', 'm11']);
    expect(newCount).toBe(5);
    expect(nextCount).toBe(12);
  });
  it('caps at 200 keeping the NEWEST overflow, and still advances past dropped messages', () => {
    const h = msgs(450);
    const { messages, newCount, nextCount } = summaryWindow(h, 100);
    expect(messages).toHaveLength(SUMMARY_WINDOW_CAP);
    expect(messages[0].text).toBe('m250'); // oldest overflow (m100..m249) dropped
    expect(messages.at(-1).text).toBe('m449');
    expect(newCount).toBe(350);
    expect(nextCount).toBe(450); // cursor passes the dropped region — never re-summarized
  });
  it('tolerates a cursor beyond the history (restart clamp)', () => {
    const { messages, nextCount } = summaryWindow(msgs(3), 99);
    expect(messages).toEqual([]);
    expect(nextCount).toBe(3);
  });
});

describe('buildSummaryPrompt', () => {
  it('embeds messages as role: text and keeps ROSTER as the last format key', () => {
    const p = buildSummaryPrompt({ messages: msgs(2), priorRoster: null, hasCumulative: false });
    expect(p).toContain('user: m0');
    expect(p.lastIndexOf('ROSTER:')).toBeGreaterThan(p.lastIndexOf('TITLE:'));
    expect(p.lastIndexOf('ROSTER:')).toBeGreaterThan(p.lastIndexOf('SUMMARY:'));
  });
  it('includes the prior roster inside a fenced preamble, and uses NEW: when cumulative exists', () => {
    const p = buildSummaryPrompt({ messages: msgs(2), priorRoster: 'Was fixing auth.\nTITLE: sneaky', hasCumulative: true });
    expect(p).toContain('Was fixing auth.');
    expect(p).toContain('NEW:');
    // the fenced preamble sits before the format block so a hostile roster line can't terminate it
    expect(p.indexOf('Was fixing auth.')).toBeLessThan(p.indexOf('Format:'));
  });
  it('omits the preamble when there is no prior roster', () => {
    const p = buildSummaryPrompt({ messages: msgs(2), priorRoster: null, hasCumulative: false });
    expect(p).not.toContain('previous rolling summary');
  });
});
```

- [ ] **Step 2: Run, verify FAIL (module not found)**

- [ ] **Step 3: Implement `lib/summary-pass.js`**

```js
// Incremental prompt window for the title/summary pass. The old pass sent
// chatHistory.slice(-50) every 5 messages — ~45 of the 50 were re-sends, so
// each message was billed ~10x over its lifetime and the prompt never carried
// the prior summary text at all. Now: only messages since the last SUCCESSFUL
// pass (cursor advances on success only, in index.js), capped at 200 with the
// oldest overflow dropped-but-skipped, plus the previous ROSTER paragraph as
// an explicitly fenced context preamble.

export const SUMMARY_MIN_NEW = 5;
export const SUMMARY_WINDOW_CAP = 200;

export function summaryWindow(chatHistory, lastCount, { cap = SUMMARY_WINDOW_CAP } = {}) {
  const history = Array.isArray(chatHistory) ? chatHistory : [];
  const since = Math.max(0, Math.min(lastCount || 0, history.length));
  const fresh = history.slice(since);
  return {
    messages: fresh.slice(-cap),
    newCount: fresh.length,
    nextCount: history.length,
  };
}

export function buildSummaryPrompt({ messages, priorRoster, hasCumulative }) {
  const rendered = messages.map((m) => `${m.role}: ${m.text}`).join('\n\n');
  // Triple-quote fencing: the roster is model output and could contain lines
  // like "TITLE:" — fencing keeps it visually distinct from the format block.
  const preamble = priorRoster
    ? `Context — previous rolling summary of this conversation:\n"""\n${priorRoster}\n"""\n\nThe messages below are what happened AFTER that summary.\n\n`
    : '';
  // ROSTER must stay the LAST format line in both variants:
  // parseTitlePassResponse's multi-line capture stops at the next KEY: line
  // or end-of-text, so a field placed after it would be swallowed.
  const shared = 'a 3-5 word title (max 34 chars) describing the overall topic/feature being worked on';
  const format = hasCumulative
    ? `Based on these recent messages, provide:\n1. ${shared}, e.g. "infrastructure documentation refinement" or "plan mode fix"\n2. A brief 1-sentence summary of what just happened\n3. A 2-3 sentence rolling summary of what this session is working on right now\n\nFormat:\nTITLE: <title>\nNEW: <1 sentence>\nROSTER: <2-3 sentences describing what this session is working on right now, for other agents deciding whether to contact it>\n\nNo quotes. Be specific and concise.`
    : `Based on these messages, provide:\n1. ${shared}, e.g. "bridge room name truncation" or "voice note support"\n2. A 1-2 sentence summary (what's been done, current status)\n3. A 2-3 sentence rolling summary of what this session is working on right now\n\nFormat:\nTITLE: <title>\nSUMMARY: <summary>\nROSTER: <2-3 sentences describing what this session is working on right now, for other agents deciding whether to contact it>\n\nNo quotes. Be specific.`;
  return `${preamble}${format}\n\nMessages:\n${rendered}`;
}
```

- [ ] **Step 4: Run tests, verify PASS; append to `check`; commit**

```bash
npx vitest run test/summary-pass.test.js && npm run check
git add lib/summary-pass.js test/summary-pass.test.js package.json
git commit -m "feat: incremental summary window + fenced-preamble prompt builder"
```

### Task B4: Wire it all into index.js — turn-end trigger, publish, persistence

This task is index.js surgery with no direct unit tests (index.js has none; all extracted logic was tested in B1–B3). Verification is `npm run ci` + manual smoke in the deploy task.

**Files:**
- Modify: `~/Dev/matron-bridge-summaries-wt/index.js` — sites listed per step (line numbers are pre-change reference points from the live tree)

**Interfaces:**
- Consumes: `createSummaryModel` (B1), `publishSummary` via `journalPublish(session, 'publishSummary', {toc, detail, model})` (B2), `summaryWindow`/`buildSummaryPrompt`/`SUMMARY_MIN_NEW` (B3).
- Produces: session fields `lastSummaryMsgCount` (number, persisted) and `lastRosterText` (string, persisted); in-memory `_summaryInFlight` guard.

- [ ] **Step 1: Provider init**

At index.js:220-222, after the existing `genAI` init, add:

```js
import { createSummaryModel } from './lib/summary-model.js';   // with the other lib imports at top
import { summaryWindow, buildSummaryPrompt, SUMMARY_MIN_NEW } from './lib/summary-pass.js';
```

```js
const summaryModel = createSummaryModel({
  openaiApiKey: process.env.OPENAI_API_KEY || '',
  geminiClient: genAI,
  modelOverride: process.env.SUMMARY_MODEL || '',
});
```

- [ ] **Step 2: Rework `maybeUpdatePinnedSummary` (index.js:4803-4901)**

Keep the function name, `applyFallbackTitle` head call, and try/catch shape. Changes inside:

```js
async function maybeUpdatePinnedSummary(session) {
  applyFallbackTitle(session, { serverLabel: SERVER_LABEL, updateRoomName, workdir: session.workdir });
  if (!summaryModel) return;                                   // was: if (!genAI) return

  if (!session.chatHistory) session.chatHistory = [];
  // NOTE: the every-5-messages modulo gate is GONE — the caller
  // (maybeSummarizeAtTurnEnd) gates on >=SUMMARY_MIN_NEW new messages.

  try {
    let currentSummary = session.pinnedSummaryText || '';
    const bulletCount = (currentSummary.match(/^•/gm) || []).length;

    if (bulletCount > 15 && currentSummary) {
      const compactPrompt = `Condense this session summary into exactly 3 bullet points (using • prefix) capturing the key accomplishments. Keep it concise and focused on major milestones:\n\n${currentSummary}`;
      currentSummary = (await summaryModel.generate(compactPrompt)).trim();
      session.pinnedSummaryText = currentSummary;
    }

    const { messages, nextCount } = summaryWindow(session.chatHistory, session.lastSummaryMsgCount);
    if (!messages.length) return;
    const prompt = buildSummaryPrompt({
      messages,
      priorRoster: session.lastRosterText || null,
      hasCumulative: Boolean(currentSummary),
    });

    const text = await summaryModel.generate(prompt);
    const parsed = parseTitlePassResponse(text);

    // ... title/room-name block unchanged (:4851-4857) ...
    // ... roster convo_upsert block unchanged (:4859-4870) ...

    // TOC event: one per successful pass, anchored by its own journal seq.
    const toc = (parsed.added || parsed.summary || '').trim();
    if (toc) {
      journalPublish(session, 'publishSummary', {
        toc: toc.slice(0, 300),
        detail: (parsed.roster || '').slice(0, 1000),
        model: summaryModel.model,
      });
    }

    // Cursor + roster memory advance ONLY on a successful, parseable pass —
    // a failing provider replays the same window next turn (capped at 200).
    if (toc || parsed.roster) {
      session.lastSummaryMsgCount = nextCount;
      if (parsed.roster) session.lastRosterText = parsed.roster;
    }

    // ... cumulative-summary block unchanged (:4872-4894), but extend the
    // persistSession extras at :4892 to include the new fields:
    //   { chatHistory: session.chatHistory, pinnedSummaryText: updatedSummary,
    //     lastSummaryMsgCount: session.lastSummaryMsgCount ?? 0,
    //     lastRosterText: session.lastRosterText || '' }
    // and add an else-branch persist when updatedSummary is empty but the
    // cursor advanced, so a roster-only pass still persists the cursor.
  } catch (e) {
    console.warn(`[summary] title/summary pass failed for ${session.roomId}: ${e.message}`);
  }
}
```

- [ ] **Step 3: New gate function + the three turn-end call sites**

Add near `maybeUpdatePinnedSummary`:

```js
// Turn-end gate for the summary pass. Fire-and-forget with an explicit catch
// (an un-awaited rejection would be fatal under Node 22 defaults) and a
// re-entrancy latch — turn-ends can arrive while a prior LLM call is pending.
function maybeSummarizeAtTurnEnd(session) {
  const count = session.chatHistory?.length || 0;
  if (count - (session.lastSummaryMsgCount || 0) < SUMMARY_MIN_NEW) return;
  if (session._summaryInFlight) return;
  session._summaryInFlight = true;
  maybeUpdatePinnedSummary(session)
    .catch((e) => console.warn(`[summary] turn-end pass failed for ${session.roomId}: ${e.message}`))
    .finally(() => { session._summaryInFlight = false; });
}
```

Insert `maybeSummarizeAtTurnEnd(session);` at ALL THREE turn-end seams, each directly after the `journalActivity(session, 'idle')` line:
1. Print-mode `case 'result'` — after index.js:3453, BEFORE the `dispatchDeferredRestart(session)` early-break further down.
2. iv-mode `session.onTurnEnd` — after index.js:2088.
3. Codex `finishCodexTurn` — after index.js:1722 (idempotent via `_codexTurnFinished`, already once-per-turn).

- [ ] **Step 4: Replace the flushResponse trigger with fallback titling only**

index.js:3843-3846 — the summary pass leaves the flush path, but fallback titling must stay (it's what names short convos before any 5-message threshold; gating it at turn-end would regress `lib/journal-title-seed.js:3-6`):

```js
  if (cleanText) {
    recordConversationMessage(session, 'assistant', cleanText);
    // Fallback titling stays on the flush path (names short convos); the
    // LLM summary pass moved to turn-end (maybeSummarizeAtTurnEnd).
    applyFallbackTitle(session, { serverLabel: SERVER_LABEL, updateRoomName, workdir: session.workdir });
  }
```

(`applyFallbackTitle` is already imported for `maybeUpdatePinnedSummary`; it is one-shot-guarded internally, so calling it from both places is safe.)

- [ ] **Step 5: Persistence carries — add BOTH new fields at every hand-written copy site**

`persistSession` writes are generic (extras spread, index.js:511-521) — no change needed to persist. Restores/carries are explicit key lists; add `lastSummaryMsgCount` and `lastRosterText` (defaults `0` / `''`) at each, next to the existing `pinnedSummaryText` line:

1. Resume restore — index.js:5434-5436 (`session.lastSummaryMsgCount = resumePersisted?.lastSummaryMsgCount || 0; session.lastRosterText = resumePersisted?.lastRosterText || '';`) and its persist key list at :5455-5467.
2. Print-mode restart carry — index.js:1366-1368.
3. iv-mode restart carry — index.js:2001-2003.
4. `recreateSession` — index.js:7526-7528.
5. `switchAgentSession` — index.js:8259-8261, its persist at :8272-8283, and the carry at :8438-8439.

Also add the in-memory defaults to both session literals, next to `pinnedSummaryText` (index.js:1246-1249 Claude, :1877-1881 Codex):

```js
    lastSummaryMsgCount: 0, // chatHistory index the summary pass has consumed through (persisted)
    lastRosterText: '',     // last ROSTER paragraph — preamble for the next incremental pass (persisted)
```

- [ ] **Step 6: Full gate**

Run: `npm run ci`
Expected: lint + check + vitest + audit all pass. Then `rg -n "slice\(-50\)" index.js` → no hits in the summary path.

- [ ] **Step 7: Commit; push; open PR**

```bash
git add index.js
git commit -m "feat: summary pass at turn end — incremental window, TOC event publish, provider switch"
git push -u origin feat/summaries-toc
gh pr create --repo Matronhq/matron-bridge --title "Summaries TOC: turn-end incremental pass, summary events, gpt-5.6-luna" --body "..."
```

---

## Phase C — matron-apple (branch `feat/summaries-toc`, already created)

### Task C1: Event constant + transcript exclusion

**Files:**
- Modify: `MatronShared/Sources/Journal/WireModels.swift:6-34` (`JournalEventType`), `MatronShared/Sources/Chat/JournalTimelineMapper.swift:21-24`
- Test: `MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift`

**Interfaces:**
- Produces: `JournalEventType.summary` ("summary"). Mapper returns `nil` for it. NOT added to `JournalEventType.messageTypes` (that set drives client-side snippet/unread/lastActivity).

- [ ] **Step 1: Failing test** — in `JournalTimelineMapperTests.swift`, next to the exclusion assertions at :264-265:

```swift
    func testSummaryEventsAreExcludedFromTranscript() {
        XCTAssertNil(map(event(11, type: "summary", payload: ["toc": "Fixed auth", "detail": "…", "model": "m"])))
    }
```

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalTimelineMapperTests`
Expected: FAIL — maps to `.unknown(eventType: "summary")`, non-nil.

- [ ] **Step 2: Implement** — `WireModels.swift` add `public static let summary = "summary"` to `JournalEventType` (NOT to `messageTypes`); `JournalTimelineMapper.swift:21-24` add `JournalEventType.summary` to the exclusion case:

```swift
        case JournalEventType.readMarker, JournalEventType.edit,
             JournalEventType.sessionStatus, JournalEventType.convoMeta,
             JournalEventType.summary:
            return nil
```

- [ ] **Step 3: Run the filter, verify PASS; commit**

```bash
git add MatronShared/Sources/Journal/WireModels.swift MatronShared/Sources/Chat/JournalTimelineMapper.swift MatronShared/Tests/ChatTests/JournalTimelineMapperTests.swift
git commit -m "feat: summary journal events — constant + transcript exclusion"
```

### Task C2: GRDB storage — `summary_entry` table fed from every apply path

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` — migration block (after v3 at :226-239), `applyOne` (:429+, side-write near the outbox precedent at :497-500), `insertHistory` (:538-569), `wipe()` (:737-741), streams section (mimic `eventsStream` :939-948)
- Test: `MatronShared/Tests/JournalTests/JournalStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct SummaryEntryRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable` — table `summary_entry`, fields `convoID/seq/toc/detail/createdAt`, snake_case CodingKeys, plus `init?(event: JournalEvent)` parsing the payload.
  - `JournalStore.summaryEntries(convoID:) throws -> [SummaryEntryRecord]` (seq DESC) and `summaryEntriesStream(convoID:) -> AsyncStream<[SummaryEntryRecord]>`.

- [ ] **Step 1: Failing tests** — in `JournalStoreTests.swift`, using the existing `makeStore()`/`event()` helpers (:4-25):

```swift
    private func summaryEvent(_ seq: Int64, convo: String = "c1") -> JournalEvent {
        event(seq, convo: convo, type: "summary",
              payload: ["toc": "Did thing \(seq)", "detail": "Detail \(seq)", "model": "gpt-5.6-luna"])
    }

    func testSummaryEventPopulatesSummaryEntryTable() throws {
        let store = try makeStore()
        _ = try store.applyJournal(event(1))
        _ = try store.applyJournal(summaryEvent(2))
        let entries = try store.summaryEntries(convoID: "c1")
        XCTAssertEqual(entries.map(\.seq), [2])
        XCTAssertEqual(entries[0].toc, "Did thing 2")
        XCTAssertEqual(entries[0].detail, "Detail 2")
    }

    func testSummaryLandsViaBatchAndHistoryPaths() throws {
        let store = try makeStore()
        _ = try store.applyJournalBatch([event(1), summaryEvent(2)])
        try store.insertHistory([summaryEvent(0)])                  // pagination backfill, older seq
        XCTAssertEqual(try store.summaryEntries(convoID: "c1").map(\.seq), [2, 0]) // newest first
    }

    func testSummaryDoesNotTouchSnippetOrUnread() throws {
        let store = try makeStore()
        _ = try store.applyJournal(event(1))                        // text, sets snippet
        let before = try store.conversations().first { $0.id == "c1" }
        _ = try store.applyJournal(summaryEvent(2))
        let after = try store.conversations().first { $0.id == "c1" }
        XCTAssertEqual(after?.snippet, before?.snippet)
        XCTAssertEqual(after?.unreadCount, before?.unreadCount)
    }

    func testWipeClearsSummaryEntries() throws {
        let store = try makeStore()
        _ = try store.applyJournal(summaryEvent(2))
        try store.wipe()
        XCTAssertEqual(try store.summaryEntries(convoID: "c1"), [])
    }
```

(Align `conversations()` accessor/field names with whatever the neighboring snippet/unread tests in this file actually use — copy their assertions' style.)

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreTests`
Expected: FAIL to compile (`SummaryEntryRecord`/`summaryEntries` unknown).

- [ ] **Step 2: Implement in `JournalStore.swift`**

Record (next to `OutboxRecord`, :109-147, same conformance list):

```swift
/// One TOC entry per bridge summary pass. Derived from `summary` journal
/// events; the event's own seq is the transcript anchor.
public struct SummaryEntryRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "summary_entry"
    public var convoID: String
    public var seq: Int64
    public var toc: String
    public var detail: String
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case convoID = "convo_id", seq, toc, detail, createdAt = "created_at"
    }

    public init?(event: JournalEvent) {
        guard event.type == JournalEventType.summary,
              let obj = try? JSONSerialization.jsonObject(with: event.payloadData) as? [String: Any],
              let toc = obj["toc"] as? String, !toc.isEmpty
        else { return nil }
        self.convoID = event.convoID
        self.seq = event.seq
        self.toc = toc
        self.detail = obj["detail"] as? String ?? ""
        self.createdAt = Int64(event.ts.timeIntervalSince1970)
    }
}
```

Migration, after v3:

```swift
        // v4: TOC summary entries — one row per bridge summary pass, derived
        // from `summary` journal events. seq doubles as the transcript anchor.
        migrator.registerMigration("v4") { db in
            try db.create(table: "summary_entry") { t in
                t.column("convo_id", .text).notNull().indexed()
                t.column("seq", .integer).notNull()
                t.column("toc", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.primaryKey(["convo_id", "seq"])
            }
        }
```

Side-writes — in `applyOne` after `try EventRecord(event).save(db)` (same-transaction precedent: the outbox delete at :497-500), and in `insertHistory`'s per-event loop:

```swift
            if let entry = SummaryEntryRecord(event: event) {
                try entry.insert(db, onConflict: .ignore)
            }
```

`wipe()` — add `try SummaryEntryRecord.deleteAll(db)` beside the event/conversation deletes (entries are derived from events; they must not survive a `snapshot_required` mirror wipe).

Accessors — mimic `eventsStream(convoID:)` at :939-948 and the fetch style around it:

```swift
    public func summaryEntries(convoID: String) throws -> [SummaryEntryRecord] {
        try dbQueue.read { db in
            try SummaryEntryRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq").desc)
                .fetchAll(db)
        }
    }

    public func summaryEntriesStream(convoID: String) -> AsyncStream<[SummaryEntryRecord]> {
        stream({ db in
            try SummaryEntryRecord
                .filter(Column("convo_id") == convoID)
                .order(Column("seq").desc)
                .fetchAll(db)
        }, in: dbQueue)   // match eventsStream's exact call into the self-healing stream helper
    }
```

- [ ] **Step 3: Run the filter, verify PASS; run full SPM suite; commit**

```bash
MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Tests/JournalTests/JournalStoreTests.swift
git commit -m "feat: summary_entry table fed from apply/batch/history paths, wiped with the mirror"
```

### Task C3: Service + ViewModel plumbing

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineService.swift` (protocol + default at the `sessionStatus()`/`sessionState()` precedent, :107-117), `MatronShared/Sources/Chat/JournalTimelineService.swift` (forwarding, next to `sessionState()` at :648-650), `MatronShared/Sources/ViewModels/ChatViewModel.swift` (state + observation task)
- Test: `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`

**Interfaces:**
- Produces:
  - `public struct ConversationSummaryEntry: Equatable, Sendable, Identifiable { public let seq: Int64; public let toc: String; public let detail: String; public let date: Date; public var id: Int64 { seq } }` (lives in the Chat module — Chat cannot depend on the Journal record type).
  - `TimelineService.summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]>` with a default empty implementation so every existing fake compiles unchanged.
  - `ChatViewModel.summaryEntries: [ConversationSummaryEntry]` (published state, newest-first). Tasks C4–C6 consume these names exactly.

- [ ] **Step 1: Failing test** — in `ChatViewModelTests.swift`, using the file's existing fake-timeline pattern (copy how the `sessionStatus` stream test seeds its fake):

```swift
    func testSummaryEntriesFlowFromServiceToViewModel() async {
        let fake = FakeTimelineService()
        fake.summaryEntriesToEmit = [
            ConversationSummaryEntry(seq: 40, toc: "Newer", detail: "d2", date: .init(timeIntervalSince1970: 2)),
            ConversationSummaryEntry(seq: 10, toc: "Older", detail: "d1", date: .init(timeIntervalSince1970: 1)),
        ]
        let vm = ChatViewModel(roomID: "r", timeline: fake, media: FakeMediaService())
        vm.start()
        await waitUntil { vm.summaryEntries.count == 2 }   // this suite's async-settle helper
        XCTAssertEqual(vm.summaryEntries.map(\.seq), [40, 10])
        vm.stop()
    }
```

(Extend the suite's existing `FakeTimelineService` with `var summaryEntriesToEmit: [ConversationSummaryEntry] = []` and an override yielding it once; `ConversationSummaryEntry` needs a public memberwise init for this.)

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ChatViewModelTests`
Expected: FAIL to compile.

- [ ] **Step 2: Implement**

`TimelineService.swift` — protocol requirement + default (exact precedent: `sessionStatus()`/`sessionState()` at :107-117):

```swift
    /// TOC summary entries for this conversation, newest-first. Re-yields on
    /// every change. Default: empty forever (fakes and non-journal backends).
    func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]>
```

```swift
    public func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]> {
        AsyncStream { $0.finish() }
    }
```

`JournalTimelineService.swift` — forward to the store, mapping records (next to `sessionState()` :648-650):

```swift
    public func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]> {
        let upstream = store.summaryEntriesStream(convoID: roomID)
        return AsyncStream { continuation in
            let task = Task {
                for await records in upstream {
                    continuation.yield(records.map {
                        ConversationSummaryEntry(seq: $0.seq, toc: $0.toc, detail: $0.detail,
                                                 date: Date(timeIntervalSince1970: TimeInterval($0.createdAt)))
                    })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```

(Match `roomID`/`store` property names to what `sessionState()` in this file actually uses.)

`ChatViewModel.swift` — state near `sessionStatus` (:100), task near `sessionStateTask` (:672-673), started in `start()` (:857), cancelled in the generation-guarded `stop(ifGeneration:)` (:990) — copy the `sessionStateTask` lifecycle exactly:

```swift
    public private(set) var summaryEntries: [ConversationSummaryEntry] = []
    private var summaryEntriesTask: Task<Void, Never>?
```

```swift
        summaryEntriesTask = Task { [weak self] in
            guard let stream = self?.timeline.summaryEntriesStream() else { return }
            for await entries in stream {
                guard let self, !Task.isCancelled else { return }
                self.summaryEntries = entries
            }
        }
```

- [ ] **Step 3: Run the filter + full SPM suite, verify PASS; commit**

```bash
git add MatronShared/Sources/Chat/TimelineService.swift MatronShared/Sources/Chat/JournalTimelineService.swift MatronShared/Sources/ViewModels/ChatViewModel.swift MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift
git commit -m "feat: summary entries flow timeline service -> ChatViewModel"
```

### Task C4: `focus(seq:)` — jump-to-message machinery

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ChatViewModel.swift` (near `ensureWindowContains` :553-569 and `paginateBackward()` :1038-1092)
- Test: `MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift`

**Interfaces:**
- Consumes: existing `rows`, `ensureWindowContains(_:)`, `paginateBackward()`, `reachedHistoryStart`.
- Produces (C5/C6 consume): `ChatViewModel.focus(seq: Int64) async` and `public private(set) var pendingFocusID: String?` + `public func clearPendingFocus()`. Views observe `pendingFocusID` exactly like the existing `pendingRestoreID` restore flow (ChatView.swift:516-527 / MacChatView.swift:531-535): disengage tail-follow, `ensureWindowContains(id)`, `proxy.scrollTo(id, anchor: .top)`, then `clearPendingFocus()`.

- [ ] **Step 1: Failing tests**

```swift
    func testFocusPicksNearestRowAtOrBeforeSeq() async {
        let vm = makeVMWithMessages(seqs: [10, 20, 30, 40])   // this suite's seeded-VM helper
        await vm.focus(seq: 35)
        XCTAssertEqual(vm.pendingFocusID, "30")               // nearest message with seq <= 35
    }

    func testFocusPaginatesBackwardUntilTargetLoaded() async {
        // fake timeline: pages of older messages; target seq only present after 2 paginateBackward calls
        let vm = makeVMWithPagedHistory(loaded: [300...340], olderPages: [[200...299], [100...199]])
        await vm.focus(seq: 150)
        XCTAssertEqual(vm.pendingFocusID, "150")
    }

    func testFocusLandsOnOldestWhenRegionUnavailable() async {
        let vm = makeVMWithPagedHistory(loaded: [300...340], olderPages: [])  // reachedHistoryStart latches
        await vm.focus(seq: 5)
        XCTAssertEqual(vm.pendingFocusID, "300")              // oldest available row
    }
```

Build the two helpers on this suite's existing fake-timeline scaffolding (the paginate fakes used by the `reachedHistoryStart` tests); each message row's `TimelineItem.id` is `String(seq)` (JournalTimelineMapper.swift:101-109), so seeding is just events with those seqs.

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ChatViewModelTests`
Expected: FAIL to compile (`focus` unknown).

- [ ] **Step 2: Implement in `ChatViewModel.swift`**

```swift
    /// Pending scroll anchor for a TOC jump. Views observe this like the
    /// scroll-restore flow: widen the window, scroll to it, then clear.
    public private(set) var pendingFocusID: String?

    public func clearPendingFocus() { pendingFocusID = nil }

    /// Navigate the transcript to the message nearest (at or before) `seq`.
    /// Pages history backward until the target region is loaded, giving up
    /// when the start-of-history latch fires; then lands on the oldest row.
    public func focus(seq: Int64) async {
        while nearestMessageID(atOrBefore: seq) == nil && !reachedHistoryStart {
            await paginateBackward()
        }
        let target = nearestMessageID(atOrBefore: seq) ?? oldestMessageID()
        guard let target else { return }
        ensureWindowContains(target)
        pendingFocusID = target
    }

    private func nearestMessageID(atOrBefore seq: Int64) -> String? {
        var best: String?
        for row in rows {
            guard case .message(let item) = row, let rowSeq = Int64(item.id) else { continue }
            if rowSeq <= seq { best = item.id } else { break }
        }
        return best
    }

    private func oldestMessageID() -> String? {
        for row in rows {
            if case .message(let item) = row, Int64(item.id) != nil { return item.id }
        }
        return nil
    }
```

Adapt the `case .message(let item)` row destructuring and the `paginateBackward()` call/latch names to this file's actual row enum and pagination API (both quoted in `ensureWindowContains` :553-569 and `paginateBackward` :1038-1092). If `paginateBackward()` is private, expose an internal wrapper rather than changing its access level.

- [ ] **Step 3: Run filter + full SPM suite, verify PASS; commit**

```bash
git add MatronShared/Sources/ViewModels/ChatViewModel.swift MatronShared/Tests/ViewModelTests/ChatViewModelTests.swift
git commit -m "feat: ChatViewModel.focus(seq:) — paginate-until-loaded jump anchor"
```

### Task C5: iOS UI — tappable title + summaries sheet

**Files:**
- Create: `Matron/Features/Chat/SummariesSheet.swift`
- Modify: `Matron/Features/Chat/ChatView.swift` (:640-641 title, :673-675 sheet family, :218 state; scroll glue near the `pendingRestoreID` observer :516-527)
- Test: `MatronTests/` view-binding test alongside the existing ChatView tests

**Interfaces:**
- Consumes: `viewModel.summaryEntries` (C3), `viewModel.focus(seq:)` / `pendingFocusID` / `clearPendingFocus()` (C4).

- [ ] **Step 1: Implement the sheet** — mimic `SessionStatusSheet.swift` exactly (NavigationStack + `@Environment(\.dismiss)`; read the view model INSIDE body — its :9-11 header explains a value snapshot through the sheet closure loses observation tracking):

```swift
import SwiftUI
import MatronShared

/// TOC of the conversation: one row per bridge summary pass, newest first.
/// Rows expand to the fuller rolling summary; tapping navigates the
/// transcript to where that pass happened.
struct SummariesSheet: View {
    let viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSeq: Int64?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.summaryEntries.isEmpty {
                    ContentUnavailableView(
                        "No summaries yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("They appear as the conversation grows."))
                } else {
                    List(viewModel.summaryEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.toc)
                                Spacer()
                                if !entry.detail.isEmpty {
                                    Image(systemName: expandedSeq == entry.seq ? "chevron.up" : "chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .onTapGesture { toggle(entry.seq) }
                                }
                            }
                            if expandedSeq == entry.seq, !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.date, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismiss()
                            Task { await viewModel.focus(seq: entry.seq) }
                        }
                    }
                }
            }
            .navigationTitle("Summaries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func toggle(_ seq: Int64) { expandedSeq = expandedSeq == seq ? nil : seq }
}
```

- [ ] **Step 2: Wire the title button + sheet + focus glue in `ChatView.swift`**

State (next to :218): `@State private var showSummaries = false`.

Title (:640-641) — keep `.navigationTitle(chatTitle)` for the back-button label, add a principal item:

```swift
        .navigationTitle(chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showSummaries = true } label: {
                    Text(chatTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
```

Sheet, beside :673-675: `.sheet(isPresented: $showSummaries) { SummariesSheet(viewModel: viewModel) }`.

Focus glue — a `pendingFocusID` observer next to the `pendingRestoreID` one (:516-527), inside the same `ScrollViewReader`:

```swift
        .onChange(of: viewModel.pendingFocusID) { _, target in
            guard let target else { return }
            isFollowingTail = false          // or the tail-follow engine yanks back to bottom
            viewModel.ensureWindowContains(target)
            withAnimation(nil) { proxy.scrollTo(target, anchor: .top) }
            viewModel.clearPendingFocus()
        }
```

(Adapt to how the restore observer actually reaches `proxy` and the tail-follow flag in this file.)

- [ ] **Step 3: Build iOS + view-binding test**

Run: `xcodegen generate && xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'`
Expected: build succeeds ("Executed" check n/a for plain build; confirm BUILD SUCCEEDED).

Add a `MatronTests` binding test in the style of the existing ChatView tests (assert `SummariesSheet` lists entries newest-first from a seeded VM fake), run the Matron test scheme, verify "Executed N tests" with N > 0.

- [ ] **Step 4: Commit**

```bash
git add Matron/Features/Chat/SummariesSheet.swift Matron/Features/Chat/ChatView.swift MatronTests/
git commit -m "feat(iOS): tappable title opens summaries TOC sheet with jump-to-point"
```

### Task C6: Mac UI — tappable title cluster + popover panel

**Files:**
- Create: `MatronMac/Features/Chat/MacSummariesPanel.swift`
- Modify: `MatronMac/Features/Chat/MacChatToolbar.swift` (titleCluster :154-171, init params, `clusterHeight` note :64-68), `MatronMac/Features/Chat/MacChatView.swift` (toolbar attach :662-670, focus glue near :531-535)
- Test: `MatronMacTests/MacChatToolbarTests.swift` (property test), `MatronMacTests/` snapshot test for the panel

**Interfaces:**
- Consumes: `viewModel.summaryEntries` (C3), `focus(seq:)`/`pendingFocusID` (C4).
- Produces: `MacChatToolbar` gains `showSummaries: Binding<Bool>`; `MacSummariesPanel(entries:onSelect:)` view.

- [ ] **Step 1: Property test first** — extend `MacChatToolbarTests.swift` (:32-48 pattern; file is `#if os(macOS)`-wrapped; Mac test targets need local fakes — SPM fakes aren't reachable, see MacChatViewTests.swift:10-13):

```swift
    func testToolbarCarriesSummariesBinding() {
        var shown = false
        let toolbar = MacChatToolbar(
            title: "Chat", status: status,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {},
            showSummaries: Binding(get: { shown }, set: { shown = $0 }))
        XCTAssertFalse(toolbar.showSummaries.wrappedValue)
        toolbar.showSummaries.wrappedValue = true
        XCTAssertTrue(shown)
    }
```

Run: `xcodegen generate && TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests`
Expected: FAIL to compile (no such parameter). Confirm the run line says "Executed N tests" once green later.

- [ ] **Step 2: Implement the toolbar change** — wrap `titleCluster` in a plain button + popover. Glass caveat (header :13-23): `.buttonStyle(.plain)` is mandatory or the system capsule breaks — the in-capsule Compact button (:126-133) is the precedent:

```swift
        ToolbarItem(placement: .principal) {
            cluster {
                Button { showSummaries.wrappedValue = true } label: { titleCluster }
                    .buttonStyle(.plain)
                    .popover(isPresented: showSummaries, arrowEdge: .bottom) {
                        popoverContent()
                    }
            }
        }
```

`popoverContent()` is a closure parameter of type `() -> AnyView` supplied by `MacChatView` (the toolbar is a `ToolbarContent` struct without the view model — keep it that way; it stays property-testable without rendering).

`MacSummariesPanel.swift` — same row layout as the iOS sheet (toc line, chevron-expand detail, date caption, empty state), sized `frame(width: 360, height: 420)`, `onSelect: (Int64) -> Void` callback.

`MacChatView.swift` — attach at :662-670: `@State private var showSummaries = false`, pass the binding + content closure:

```swift
            MacChatToolbar(..., showSummaries: $showSummaries,
                popoverContent: {
                    AnyView(MacSummariesPanel(entries: viewModel.summaryEntries) { seq in
                        showSummaries = false
                        Task { await viewModel.focus(seq: seq) }
                    })
                })
```

Focus glue: same `pendingFocusID` observer as iOS, next to the Mac restore observer (:531-535), including `isFollowingTail = false` first.

- [ ] **Step 3: Snapshot test for the panel** — mimic `MacSearchViewSnapshotTests.swift:30-46`:

```swift
    func testSummariesPanelPopulated() {
        let entries = [
            ConversationSummaryEntry(seq: 40, toc: "Shipped the fix", detail: "Working on release.", date: .init(timeIntervalSince1970: 1_770_000_000)),
            ConversationSummaryEntry(seq: 10, toc: "Diagnosed the bug", detail: "", date: .init(timeIntervalSince1970: 1_769_000_000)),
        ]
        let view = MacSummariesPanel(entries: entries, onSelect: { _ in })
            .frame(width: 360, height: 420)
        assertVariants(of: view, named: "MacSummariesPanel_populated")
    }
```

First run records snapshots into `MatronMacTests/__Snapshots__/` (run WITHOUT the skip env once to record, inspect the images, then re-run to verify).

- [ ] **Step 4: Full Mac test target + commit**

Run: `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests`
Expected: "Executed N tests" with 0 failures.

```bash
git add MatronMac/Features/Chat/ MatronMacTests/
git commit -m "feat(Mac): title cluster opens summaries TOC popover with jump-to-point"
```

### Task C7: Apps PR

- [ ] **Step 1:** Full verification sweep: SPM suite, iOS build, Mac test target (commands in Global Constraints), each asserting real executed counts.
- [ ] **Step 2:** `git push -u origin feat/summaries-toc && gh pr create --title "Conversation summaries TOC: local store, title-tap panel, jump-to-point" --body "..."` (PR body: spec link, the three-repo deploy order, screenshots of both panels).

---

## Phase D — Deploy (after all three PRs merge; requires Dan for app installs and the OpenAI key)

- [ ] **Step 1: Journal to dev-2** — follow the standing recipe: back up the DB first, then pull + restart the systemd service. Verify with a WS smoke: publish a `summary` event from a test agent, confirm accepted.
- [ ] **Step 2: Install both apps** from the merged apps main (Mac: verify by binary hash/mtime, not Finder date; iPhone via devicectl). Old apps would render `[unsupported event: summary]` — do not proceed to Step 3 until installs are confirmed.
- [ ] **Step 3: Bridge** — request `OPENAI_API_KEY` from Dan via the secure `request_secret` flow (never chat), add `OPENAI_API_KEY=` to the live tree's `.env`, then `deploy.sh` (pull + preflight + `launchctl kickstart -k`) with PID verification the following turn.
- [ ] **Step 4: End-to-end smoke** — hold a real conversation past 5 messages across ≥2 turns; confirm: TOC entries appear in both apps' panels, tapping navigates, no push/badge/snippet changes from summary traffic, bridge log shows the pass using `gpt-5.6-luna`.
