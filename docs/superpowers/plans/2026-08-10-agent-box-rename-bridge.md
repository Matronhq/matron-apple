# Agent Box Rename — Bridge Implementation Plan (2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Repo:** `matron-bridge` (branch off `master`). The spec lives in the
`matron-apple` repo at `docs/superpowers/specs/2026-08-10-agent-box-rename-design.md`.

**WARNING:** `/Users/danbarker/Dev/matron-bridge` is the LIVE deploy tree —
never switch its branch. Do this work in a git worktree
(`superpowers:using-git-worktrees`), not in that directory.

**Goal:** Stop the bridge baking its `SERVER_LABEL` into conversation titles,
so the owning box is rendered from data by the apps instead of being frozen
into title text.

**Architecture:** Four sites build titles with a `SERVER_LABEL` prefix — the
workdir seed and first-user-message fallback in `lib/journal-title-seed.js`,
and the Gemini title pass and resumed-session titles in `index.js`. All four
drop the prefix. `SERVER_LABEL` itself stays (it is still used by `/help`
output and logs). The seed-clobber-protection logic must keep recognising the
OLD prefixed forms so titles written by a pre-upgrade bridge are still
treated as replaceable seeds.

**Tech Stack:** Node.js ESM, Vitest (`npx vitest run`).

## Global Constraints

- The title pipeline is shared by Matrix room names and journal conversation
  titles (`updateRoomName`). Both lose the prefix — no split.
- `SERVER_LABEL` stays defined and stays in `/help` text and log lines.
- The two-character session-id fragment goes too: `2:f0 fix the picker`
  becomes `fix the picker`. The chip plus timestamps disambiguate sessions in
  one workdir.
- 60-char title truncation with a trailing `…` is unchanged
  (`FALLBACK_TITLE_MAX = 60`).
- Run tests with `npx vitest run` from the repo root.

---

### Task 1: Unprefixed seed and fallback titles

**Files:**
- Modify: `lib/journal-title-seed.js:18-54` (`seedTitleFor`, `applyFallbackTitle`)
- Test: `test/journal-title-seed.test.js` (update existing expectations, add one)

**Interfaces:**
- Consumes: nothing.
- Produces: `seedTitleFor(workdir, serverLabel)` now returns the workdir
  basename alone (the `serverLabel` parameter is retained ONLY so the
  legacy-seed recognition in `applyFallbackTitle` can still build the old
  prefixed forms). `applyFallbackTitle` calls
  `updateRoomName(roomId, cleanedFirstUserMessage)` with no prefix.

**Note for the implementer:** the clobber-protection in `applyFallbackTitle`
compares the current title hint against "what the seed would have been". After
this change the seed is the bare basename, but titles already on disk (and on
the server) may still carry `LABEL: basename`. All three forms must count as
"still just a seed, fair game to replace", or sessions that predate this
deploy keep their seed title forever.

- [ ] **Step 1: Update the tests to the new expectations**

In `test/journal-title-seed.test.js`:

Replace the first test's expectation:

```js
  it('titles the convo from the workdir basename, with no server-label prefix', async () => {
    const session = { _journalTitleHint: undefined };
    const upsertConvo = vi.fn();
    const ok = await seedJournalTitle(session, { workdir: '/home/dan/yearbook-app', serverLabel: '2', upsertConvo, warn: () => {} });
    expect(ok).toBe(true);
    expect(upsertConvo).toHaveBeenCalledWith(session, { title: 'yearbook-app' });
  });
```

In the `applyFallbackTitle` describe block, drop the `2:f0 ` prefix from every
`updateRoomName` expectation:

- `'2:f0 fix the folder picker'` → `'fix the folder picker'`
- `'2:f0 now do the thing'` → `'now do the thing'`
- `'2:ro hi'` → `'hi'`
- `'2:f0 carry on'` → `'carry on'` (three occurrences: the labeled-seed,
  bare-basename-seed and tag-only tests)
- `'2:f0 the real prompt'` → `'the real prompt'`

Update the truncation test's assertions:

```js
    expect(title.startsWith('refactor the whole session store')).toBe(true);
    expect(title.endsWith('…')).toBe(true);
    expect(title.length).toBe(61);
```

Add a new test pinning the legacy-seed recognition:

```js
  it('still replaces a seed written by a pre-upgrade bridge (LABEL: basename)', () => {
    // Sessions that started before the prefix was dropped persisted
    // `2: proj` as their seed. That is still a seed, so the first-user-
    // message fallback must be allowed to replace it — otherwise every
    // pre-upgrade session keeps the repo name as its title forever.
    const session = {
      roomId: '!abc',
      claudeSessionId: 'f0aa',
      _journalTitleHint: '2: proj',
      chatHistory: [{ role: 'user', text: 'carry on' }],
    };
    const d = { serverLabel: '2', updateRoomName: vi.fn(), workdir: '/home/dan/proj' };
    expect(applyFallbackTitle(session, d)).toBe(true);
    expect(d.updateRoomName).toHaveBeenCalledWith('!abc', 'carry on');
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run test/journal-title-seed.test.js`
Expected: FAIL — expectations still receive prefixed titles
(`'2: yearbook-app'`, `'2:f0 fix the folder picker'`, …).

- [ ] **Step 3: Drop the prefix in `lib/journal-title-seed.js`**

Replace `seedTitleFor` (lines 18-22):

```js
// The seed title seedJournalTitle below would give this workdir — the only
// title the fallback is allowed to replace. Anything else (a resume summary,
// media naming, an earlier fallback surviving a bridge restart) already beat
// the seed and must not be clobbered.
//
// No server-label prefix: which box owns a conversation is data
// (conversations.agent_device_id) that clients render as a chip, not text
// baked into the title. `serverLabel` is still accepted so legacySeedTitles
// can reconstruct what a pre-upgrade bridge would have written.
function seedTitleFor(workdir) {
  const base = workdir ? path.basename(path.resolve(workdir)) : '';
  return base || 'session';
}

// Every form that has ever been a seed for this workdir. A session that
// started before the label was dropped persisted `LABEL: basename`, and one
// older still persisted the bare basename; both are seeds and both stay
// replaceable by the first-user-message fallback.
function legacySeedTitles(workdir, serverLabel) {
  const base = seedTitleFor(workdir);
  return serverLabel ? [base, `${serverLabel}: ${base}`] : [base];
}
```

Replace the hint check in `applyFallbackTitle` (lines 28-31):

```js
  const hint = session._journalTitleHint;
  // Any historical seed form is still just a seed, still fair game to
  // replace — including the labeled form written before the prefix was
  // dropped.
  if (hint !== undefined && !legacySeedTitles(workdir, serverLabel).includes(hint)) return false;
```

Replace the last three lines of the loop body (lines 48-51) — the
`sessionShort` declaration goes away entirely:

```js
    session._fallbackTitleApplied = true;
    updateRoomName(session.roomId, text);
    return true;
```

Finally update the call inside `seedJournalTitle` (line 110):

```js
    upsertConvo(session, { title: seedTitleFor(workdir) });
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npx vitest run test/journal-title-seed.test.js`
Expected: PASS — all `seedJournalTitle`, `applyFallbackTitle` and
`parseTitlePassResponse` tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/journal-title-seed.js test/journal-title-seed.test.js
git commit -m "feat(titles): drop the server-label prefix from seed and fallback titles"
```

---

### Task 2: Unprefixed Gemini-pass and resumed-session titles

**Files:**
- Modify: `index.js:4990-4996` (Gemini title pass)
- Modify: `index.js:5595-5599` (resumed-session room name)
- Test: `test/journal-title-seed.test.js` (the "title-pass wiring in index.js
  (source inspection)" describe block — add two assertions)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: no new exports. `updateRoomName` receives
  `parsed.title.slice(0, 60)` and `Resumed <shortId>` / `<summary…>` with no
  prefix.

- [ ] **Step 1: Write the failing assertions**

In the `describe('title-pass wiring in index.js (source inspection)')` block
at the end of `test/journal-title-seed.test.js`, add:

```js
  it('names the room from the parsed title alone — no SERVER_LABEL prefix', () => {
    // Which box owns a conversation is data now (agent_device_id, rendered
    // as a chip by the apps). A label baked in here is frozen text that a
    // rename can never reach — and it is what made two boxes both read
    // "DEV" in the chat list.
    expect(indexSrc).toMatch(/const name = parsed\.title\.slice\(0, 60\);/);
  });

  it('names a resumed session without a SERVER_LABEL prefix', () => {
    expect(indexSrc).toMatch(/: `Resumed \$\{shortId\}`;/);
  });

  it('never rebuilds a `LABEL:` title prefix anywhere', () => {
    expect(indexSrc).not.toMatch(/\$\{SERVER_LABEL\}:/);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run test/journal-title-seed.test.js`
Expected: FAIL on all three — `index.js` still builds
`` `${SERVER_LABEL}:${sessionShort} ...` `` and `` `${SERVER_LABEL}: ...` ``.

- [ ] **Step 3: Drop the prefix in the Gemini title pass**

In `index.js`, replace the `sessionShort` line and the title block
(~lines 4990-4996):

```js
    // Update room name (Element sidebar truncates visually, full name visible on hover)
    if (parsed.title) {
      const name = parsed.title.slice(0, 60);
      updateRoomName(session.roomId, name);
    }
```

Delete the now-unused
`const sessionShort = (session.claudeSessionId || session.roomId.slice(1)).slice(0, 2);`
line above it — but first check it is not referenced further down in the same
function (`grep -n sessionShort index.js`); if it is, leave the declaration in
place.

- [ ] **Step 4: Drop the prefix on resumed-session titles**

In `index.js` (~lines 5596-5598), replace:

```js
      const roomName = summary
        ? `${summary.slice(0, 50)}${summary.length > 50 ? '…' : ''}`
        : `Resumed ${shortId}`;
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npx vitest run test/journal-title-seed.test.js`
Expected: PASS, all three new assertions included.

- [ ] **Step 6: Run the whole suite**

Run: `npx vitest run`
Expected: PASS. If another test asserts on a prefixed title, update it to the
unprefixed form — the prefix is deliberately gone, and no test should be
pinning it any more.

- [ ] **Step 7: Commit**

```bash
git add index.js test/journal-title-seed.test.js
git commit -m "feat(titles): drop the server-label prefix from Gemini and resume titles"
```

---

## Deploy note (for whoever ships this)

Deploy every bridge in the fleet **before** the journal build from plan 1 —
an old bridge's Gemini title pass would re-bake the prefix onto healed
titles. Deploy per `technique_journal_deploy_dev2` / the bridge's
`deploy.sh`, and remember `launchctl kickstart -k` must be the last action of
a turn with the PID verified afterwards.

## Self-review notes

- Spec §2 lists four sites: seed and fallback (Task 1), Gemini pass and
  resume (Task 2). The `/help` text at `index.js` ~5916/5960 is deliberately
  untouched — it documents `SERVER_LABEL`, it does not title anything.
- The `not.toMatch(/\$\{SERVER_LABEL\}:/)` assertion in Task 2 is the
  regression net: it fails if any future edit reintroduces a prefixed title
  anywhere in `index.js`.
